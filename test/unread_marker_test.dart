import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// design/v2/design-unread-marker.md 场景回归：
//  §2.1 判定表 / §4.2 点开即清 / §4.1 max 合并纪律 / §4.3 终态补拉 /
//  §4.4 去重与退避 / §2.4 session.viewed 事件 / §4.5 状态机插档。

SessionModel _session(String id, {int? idle, int? viewed}) =>
    SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {
        'updated': 1000,
        'idle': ?idle,
        'viewed': ?viewed,
      },
    });

OpencodeEvent _ev(String type, String sid, [Map<String, dynamic>? extra]) =>
    OpencodeEvent(
      type: type,
      properties: {'sessionID': sid, ...?extra},
    );

class _ViewClient extends OpencodeClient {
  _ViewClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  final viewCalls = <MapEntry<String, int>>[];
  final metaCalls = <String>[];
  bool failViews = false;
  Map<String, SessionModel> metaResponses = {};

  @override
  Future<void> markSessionViewed(String sessionId, int idle) async {
    viewCalls.add(MapEntry(sessionId, idle));
    if (failViews) {
      throw DioException(
          requestOptions: RequestOptions(path: '/view'), error: 'net down');
    }
  }

  @override
  Future<SessionModel> sessionMeta(String sessionId) async {
    metaCalls.add(sessionId);
    final s = metaResponses[sessionId];
    if (s == null) {
      throw DioException(
          requestOptions: RequestOptions(path: '/session'),
          error: 'not found');
    }
    return s;
  }
}

class _ReconcileClient extends OpencodeClient {
  _ReconcileClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  final viewCalls = <MapEntry<String, int>>[];
  List<SessionModel> snapshot = const [];

  @override
  Future<List<SessionModel>> sessions(
      {String? directory,
      String? project,
      String? subpath,
      int limit = 1000,
      String? search,
      String? parentID}) async {
    return snapshot;
  }

  @override
  Future<List<ProjectModel>> projects() async => const [];

  @override
  Future<Map<String, SessionStatusValue>> activeSessions() async =>
      const {};

  @override
  Future<void> markSessionViewed(String sessionId, int idle) async {
    viewCalls.add(MapEntry(sessionId, idle));
  }
}

Matcher _viewCall(String sid, int idle) => predicate<MapEntry<String, int>>(
    (e) => e.key == sid && e.value == idle, 'view($sid, $idle)');

void main() {
  late _ViewClient client;
  late ServerStore store;

  setUp(() {
    client = _ViewClient();
    store = ServerStore()..client = client;
    ServerStore.ackRetryBaseDelay = const Duration(milliseconds: 1);
    ServerStore.ackRetryMaxDelay = const Duration(milliseconds: 5);
  });

  tearDown(() {
    store.dispose();
    ServerStore.ackRetryBaseDelay = const Duration(milliseconds: 250);
    ServerStore.ackRetryMaxDelay = const Duration(seconds: 5);
  });

  group('unread predicate', () {
    test('idle undefined → not unread', () {
      store.upsertSessionForTesting(_session('s1'));
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('viewed undefined → unread', () {
      store.upsertSessionForTesting(_session('s1', idle: 100));
      expect(store.isSessionUnread('s1'), isTrue);
    });

    test('idle > viewed → unread', () {
      store.upsertSessionForTesting(_session('s1', idle: 200, viewed: 100));
      expect(store.isSessionUnread('s1'), isTrue);
    });

    test('idle <= viewed → not unread', () {
      store.upsertSessionForTesting(_session('s1', idle: 100, viewed: 100));
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('unknown session → not unread', () {
      expect(store.isSessionUnread('nope'), isFalse);
    });
  });

  group('state machine', () {
    test('idle session with unread → unread state', () {
      store.upsertSessionForTesting(_session('s1', idle: 200, viewed: 100));
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.unread);
    });

    test('busy outranks unread', () {
      store.upsertSessionForTesting(_session('s1', idle: 200, viewed: 100));
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.working);
    });

    test('failed outranks unread', () {
      store.upsertSessionForTesting(_session('s1', idle: 200, viewed: 100));
      store.onEventForTesting(_ev('session.execution.failed', 's1'));
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.failed);
    });
  });

  group('ack on open', () {
    test('opening a session acks the observed idle', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('inactive session is not acked', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, isEmpty);
      expect(store.isSessionUnread('s1'), isTrue);
    });

    test('an ack already in flight completes after leaving (opened = read)',
        () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      store.setActiveConversation(null);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('re-entering the same idle does not re-ack', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls.length, 1);
    });

    test('idle advancing while the session is open acks the new idle',
        () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.upsertSessionForTesting(_session('s1', idle: 400));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls,
          [_viewCall('s1', 300), _viewCall('s1', 400)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('idle advancing after leaving keeps the session unread', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.setActiveConversation(null);
      store.upsertSessionForTesting(_session('s1', idle: 500));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)]);
      expect(store.isSessionUnread('s1'), isTrue);
    });

    test('a failed session still acks while showing failed', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.onEventForTesting(_ev('session.execution.failed', 's1'));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)]);
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.failed);
    });
  });

  group('ack gate (current route + foreground)', () {
    test('backgrounding does not ack; returning to the foreground acks',
        () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)]);

      store.setAppForeground(false);
      store.upsertSessionForTesting(_session('s1', idle: 400));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)],
          reason: 'a backgrounded app must not ack');
      expect(store.isSessionUnread('s1'), isTrue);

      store.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300), _viewCall('s1', 400)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('a covered conversation does not ack until it is visible again',
        () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.clearActiveConversationIf('s1');

      store.upsertSessionForTesting(_session('s1', idle: 500));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300)],
          reason: 'another page on top must not ack');
      expect(store.isSessionUnread('s1'), isTrue);

      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.viewCalls, [_viewCall('s1', 300), _viewCall('s1', 500)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('leaving a covered page only clears its own activation', () {
      store.setActiveConversation('s2');
      store.clearActiveConversationIf('s1');
      expect(store.activeConversationId, 's2');
    });

    test('a token-guarded clear never clobbers a newer holder', () {
      final oldPage = Object();
      final newPage = Object();
      store.setActiveConversation('s1', token: oldPage);
      store.clearActiveConversationIf('s1', token: oldPage);
      expect(store.activeConversationId, isNull);

      store.setActiveConversation('s1', token: newPage);
      store.clearActiveConversationIf('s1', token: oldPage);
      expect(store.activeConversationId, 's1',
          reason: 'a replaced page must not clear the new page activation');
      store.clearActiveConversationIf('s1', token: newPage);
      expect(store.activeConversationId, isNull);
    });
  });

  group('merge discipline', () {
    test('a stale snapshot does not regress an optimistic viewed', () {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.setActiveConversation('s1');
      store.upsertSessionForTesting(
          _session('s1', idle: 300, viewed: 300));
      store.upsertSessionForTesting(_session('s1', viewed: 100));
      expect(store.sessionById('s1')!.viewed, 300);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('a stale snapshot does not regress a known idle', () {
      store.upsertSessionForTesting(_session('s1', idle: 500));
      store.upsertSessionForTesting(_session('s1', idle: 200));
      expect(store.sessionById('s1')!.idle, 500);
    });

    test('session.viewed event advances the watermark without a local ack',
        () {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      store.onEventForTesting(_ev('session.viewed', 's1', {'idle': 300}));
      expect(store.sessionById('s1')!.viewed, 300);
      expect(store.isSessionUnread('s1'), isFalse);
      expect(client.viewCalls, isEmpty);
    });

    test('session.viewed event with a smaller idle does not regress',
        () async {
      store.upsertSessionForTesting(_session('s1', idle: 400, viewed: 400));
      store.onEventForTesting(_ev('session.viewed', 's1', {'idle': 100}));
      expect(store.sessionById('s1')!.viewed, 400);
    });
  });

  group('terminal refresh', () {
    test('execution.succeeded backfills authoritative idle via REST',
        () async {
      store.upsertSessionForTesting(_session('s1'));
      client.metaResponses['s1'] = _session('s1', idle: 700);
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.metaCalls, ['s1']);
      expect(store.sessionById('s1')!.idle, 700);
      expect(store.isSessionUnread('s1'), isTrue);
    });

    test('backfilled idle acks an open session', () async {
      store.upsertSessionForTesting(_session('s1'));
      client.metaResponses['s1'] = _session('s1', idle: 700);
      store.setActiveConversation('s1');
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(client.viewCalls, [_viewCall('s1', 700)]);
      expect(store.isSessionUnread('s1'), isFalse);
    });

    test('shutdown interrupt skips the backfill', () async {
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.execution.interrupted', 's1',
          {'reason': 'shutdown'}));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(client.metaCalls, isEmpty);
    });

    test('terminal refresh failure is silent', () async {
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.sessionById('s1')!.idle, isNull);
    });
  });

  group('ack retry', () {
    test('a failed ack keeps the session unread and retries', () async {
      store.upsertSessionForTesting(_session('s1', idle: 300));
      client.failViews = true;
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.isSessionUnread('s1'), isTrue);
      client.failViews = false;
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(client.viewCalls.length, greaterThanOrEqualTo(2));
      expect(store.isSessionUnread('s1'), isFalse);
    });
  });

  group('reconcile path (production refreshListAndWorkingSse)', () {
    late _ReconcileClient rClient;
    late ServerStore rStore;

    setUp(() {
      rClient = _ReconcileClient();
      rStore = ServerStore()..client = rClient;
      rStore.installSseForTesting(
          SseClient(baseUrl: 'http://127.0.0.1:9'));
    });

    tearDown(() {
      rStore.dispose();
    });

    test('a stale list snapshot does not regress optimistic watermarks',
        () async {
      rStore.upsertSessionForTesting(
          _session('s1', idle: 300, viewed: 300));
      rClient.snapshot = [_session('s1', idle: 300)];
      await rStore.refreshListAndWorkingSse(force: false);
      expect(rStore.sessionById('s1')!.viewed, 300,
          reason: 'list snapshot without viewed must not clear the watermark');
      expect(rStore.isSessionUnread('s1'), isFalse);
    });

    test('a stale list snapshot does not regress a backfilled idle',
        () async {
      rStore.upsertSessionForTesting(_session('s1', idle: 700));
      rClient.snapshot = [_session('s1')];
      await rStore.refreshListAndWorkingSse(force: false);
      expect(rStore.sessionById('s1')!.idle, 700,
          reason: 'list snapshot without idle must not clear the watermark');
      expect(rStore.isSessionUnread('s1'), isTrue);
    });

    test('refresh acks the active session after the snapshot lands',
        () async {
      rStore.upsertSessionForTesting(_session('s1', idle: 300));
      rClient.snapshot = [_session('s1', idle: 300)];
      rStore.setActiveConversation('s1');
      await rStore.refreshListAndWorkingSse(force: false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rClient.viewCalls, [_viewCall('s1', 300)]);
      expect(rStore.isSessionUnread('s1'), isFalse);
    });
  });
}
