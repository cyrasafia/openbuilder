import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/notifications/notification_service.dart';
import 'package:open_builder/core/platform/keepalive_controller.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';

OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

SessionModel _session(String id) => SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
    });

SessionModel _childSession(String id, String parentID) => SessionModel(
      id: id,
      projectID: 'p1',
      directory: '/dirA',
      title: id,
      created: 1,
      updated: 1,
      parentID: parentID,
    );

OpencodeEvent _ev(String type, String sid, [Map<String, dynamic>? props]) =>
    OpencodeEvent(
      type: type,
      properties: {'sessionID': sid, ...?props},
    );

class _AckClient extends OpencodeClient {
  _AckClient()
      : super(dioFor(const ConnectionProfile(
          id: 't',
          name: 'test',
          address: 'http://127.0.0.1:9',
          username: 'opencode',
          password: '',
        )));
  final viewCalls = <MapEntry<String, int>>[];
  SessionModel? meta;

  @override
  Future<void> markSessionViewed(String sessionId, int idle) async {
    viewCalls.add(MapEntry(sessionId, idle));
  }

  @override
  Future<SessionModel> sessionMeta(String sessionId) async => meta!;
}

SessionModel _sessionWithIdle(String id, int idle) => SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000, 'idle': idle},
    });

SessionModel _sessionFull(
  String id, {
  int? idle,
  int? viewed,
  String? outcome,
  String? parentID,
}) =>
    SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't-$id',
      'outcome': outcome,
      'parentID': parentID,
      'time': {
        'updated': 1000,
        'idle': ?idle,
        'viewed': ?viewed,
      },
    });

class _CardBackfillClient extends OpencodeClient {
  final Future<List<Permission>> Function(String sessionId)? permissions;
  final Future<List<FormInfo>> Function(String sessionId)? forms;
  final Future<LatestMessageSummary> Function(String sessionId)? latestMessages;
  _CardBackfillClient({this.permissions, this.forms, this.latestMessages})
      : super(_backfillDio());

  @override
  Future<List<Permission>> sessionPermissions(String sessionId) async =>
      await (permissions?.call(sessionId) ?? Future.value(const []));

  @override
  Future<List<FormInfo>> sessionForms(String sessionId) async =>
      await (forms?.call(sessionId) ?? Future.value(const []));

  @override
  Future<LatestMessageSummary> latestMessageSummary(String sessionId) async =>
      await (latestMessages?.call(sessionId) ??
          Future.value(const LatestMessageSummary()));
}

Dio _backfillDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

class _FakeBackend extends KeepaliveBackend {
  final starts = <int>[];
  final updates = <int>[];
  int stops = 0;

  @override
  Future<void> start(int count) async {
    starts.add(count);
  }

  @override
  Future<void> updateCount(int count) async {
    updates.add(count);
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<bool> notificationsEnabled() async => true;
}

class _GateStartBackend extends _FakeBackend {
  final gate = Completer<void>();

  @override
  Future<void> start(int count) {
    super.start(count);
    return gate.future;
  }
}

class _PauseSpyStore extends ServerStore {
  int pauses = 0;

  @override
  Future<void> pause() {
    pauses++;
    return super.pause();
  }
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    NotificationService.debugMarkInitialized();
    NotificationService.debugFakeShow = true;
    NotificationService.debugResetSlots();
    taskCompleteNotify.value = true;
  });

  group('streamingSessionCount', () {
    test('busy without pending card counts; card-blocked busy does not', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      expect(store.streamingSessionCount, 1);
      store.onEventForTesting(
          _ev('permission.asked', 's1', {'id': 'perm1', 'action': 'bash'}));
      expect(store.streamingSessionCount, 0);
      store.onEventForTesting(
          _ev('permission.replied', 's1', {'requestID': 'perm1'}));
      expect(store.streamingSessionCount, 1);
      store.dispose();
    });

    test('ask card on a child blocks the parent host run too', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('p1'));
      store.upsertSessionForTesting(_childSession('c1', 'p1'));
      store.onEventForTesting(_ev('session.execution.started', 'p1'));
      store.onEventForTesting(_ev('session.execution.started', 'c1'));
      expect(store.streamingSessionCount, 1,
          reason: 'a child of a running parent folds into the parent task');
      store.onEventForTesting(
          _ev('permission.asked', 'c1', {'id': 'perm2', 'action': 'bash'}));
      expect(store.streamingSessionCount, 0,
          reason: 'card floats to host p1; both runs are blocked');
      store.onEventForTesting(
          _ev('permission.replied', 'c1', {'requestID': 'perm2'}));
      expect(store.streamingSessionCount, 1);
      store.dispose();
    });

    test('children never count; only running top-level sessions do', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('p1'));
      store.upsertSessionForTesting(_session('p2'));
      store.upsertSessionForTesting(_childSession('c1', 'p1'));
      store.upsertSessionForTesting(_childSession('c2', 'p1'));
      store.upsertSessionForTesting(_childSession('c3', 'p2'));
      store.onEventForTesting(_ev('session.execution.started', 'p1'));
      expect(store.streamingSessionCount, 1);
      store.onEventForTesting(_ev('session.execution.started', 'c1'));
      store.onEventForTesting(_ev('session.execution.started', 'c2'));
      expect(store.streamingSessionCount, 1,
          reason: 'children of the running p1 fold into its task');
      store.onEventForTesting(_ev('session.execution.started', 'c3'));
      expect(store.streamingSessionCount, 1,
          reason: 'an orphan child (idle parent) never counts and never '
              'drives the FGS');
      store.onEventForTesting(_ev('session.execution.succeeded', 'p1'));
      expect(store.streamingSessionCount, 0,
          reason: 'orphan-only runs do not keep the keepalive alive');
      store.onEventForTesting(_ev('session.execution.started', 'p2'));
      expect(store.streamingSessionCount, 1);
      store.dispose();
    });
  });

  group('notification lifecycle', () {
    test('foreground active conversation suppresses run-complete notify', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(true);
      store.setActiveConversation('s1');
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('background settle seeds run slot; session.viewed clears it', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(NotificationService.hasPendingSlots, isTrue);
      store.onEventForTesting(_ev('session.viewed', 's1', {'idle': 2000}));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('background settle keeps the notification until the user returns',
        () async {
      final client = _AckClient();
      final store = ServerStore()
        ..client = client
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setActiveConversation('s1');
      store.setAppForeground(false);
      client.meta = _sessionWithIdle('s1', 2000);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(NotificationService.hasPendingSlots, isTrue);
      expect(client.viewCalls, isEmpty,
          reason: 'a backgrounded app must not ack, or its own viewed echo '
              'cancels the completion notification');
      expect(store.isSessionUnread('s1'), isTrue);

      store.setAppForeground(true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(client.viewCalls.length, 1);
      expect(client.viewCalls.single.key, 's1');
      expect(client.viewCalls.single.value, 2000);
      store.onEventForTesting(
          _ev('session.viewed', 's1', <String, dynamic>{'idle': 2000}));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('card slot is cleared when the card is replied elsewhere', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(
          _ev('permission.asked', 's1', {'id': 'perm1', 'action': 'bash'}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.hasPendingSlots, isTrue);
      store.onEventForTesting(
          _ev('permission.replied', 's1', {'requestID': 'perm1'}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('entering the conversation clears its slots', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      NotificationService.debugSeedSlot(card: 's1');
      expect(NotificationService.hasPendingSlots, isTrue);
      store.setActiveConversation('s1');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('session.deleted clears its slots', () {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      store.onEventForTesting(_ev('session.deleted', 's1'));
      expect(NotificationService.hasPendingSlots, isFalse);
      store.dispose();
    });

    test('settle replaces the host card notification (one slot per session)',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(
          _ev('permission.asked', 's1', {'id': 'perm1', 'action': 'bash'}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasCardSlot('s1'), isTrue);
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasRunSlot('s1'), isTrue);
      expect(NotificationService.debugHasCardSlot('s1'), isFalse,
          reason: 'the run-complete notification replaces the card '
              'notification of the same session');
      store.dispose();
    });

    test('card notification replaces the previous run-complete notification',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasRunSlot('s1'), isTrue);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(
          _ev('permission.asked', 's1', {'id': 'perm1', 'action': 'bash'}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasCardSlot('s1'), isTrue);
      expect(NotificationService.debugHasRunSlot('s1'), isFalse,
          reason: 'a fresh card notification replaces the unread run-complete '
              'notification of the same session');
      store.dispose();
    });

    test('late child adoption replaces the host run-complete notification',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('p1'));
      store.setAppForeground(false);
      NotificationService.debugSeedSlot(run: 'p1');
      expect(NotificationService.debugHasRunSlot('p1'), isTrue);

      // Card on an unregistered child, then the child registers (REST
      // rebuild / SSE race) — adoption floats the card and must replace the
      // host's unread run-complete notification (D24).
      store.onEventForTesting(
          _ev('permission.asked', 'c1', {'id': 'perm3', 'action': 'bash'}));
      store.upsertSessionForTesting(_childSession('c1', 'p1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasCardSlot('c1'), isTrue);
      expect(NotificationService.debugHasRunSlot('p1'), isFalse);
      store.dispose();
    });

    test('host settle replaces a child card notification', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('p1'));
      store.upsertSessionForTesting(_childSession('c1', 'p1'));
      store.setAppForeground(false);
      store.onEventForTesting(_ev('session.execution.started', 'p1'));
      store.onEventForTesting(_ev('session.execution.started', 'c1'));
      store.onEventForTesting(
          _ev('permission.asked', 'c1', {'id': 'perm2', 'action': 'bash'}));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasCardSlot('c1'), isTrue);
      store.onEventForTesting(_ev('session.execution.succeeded', 'p1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(NotificationService.debugHasRunSlot('p1'), isTrue);
      expect(NotificationService.debugHasCardSlot('c1'), isFalse,
          reason: 'cards floating to host p1 are replaced by its run-complete '
              'notification');
      store.dispose();
    });
  });

  group('S26 retro completion notify', () {
    test('blind-window settle is retro-notified on reconcile', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.statusOf('s1').type, 'idle');
      expect(NotificationService.debugHasRunSlot('s1'), isTrue,
          reason: 'the settle event was missed; the reconcile flip must '
          'post the completion notification');
      store.dispose();
    });

    test('stale finish is still notified when unread', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 2 * 60 * 60 * 1000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.statusOf('s1').type, 'idle');
      expect(NotificationService.debugHasRunSlot('s1'), isTrue,
          reason: 'user ruling 2026-10-18: the unread watermark is the only '
          'staleness bound — no time window');
      store.dispose();
    });

    test('already-read session is not notified', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final idle = now - 60000;
      final s1 = _sessionFull('s1', idle: idle, viewed: idle);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isFalse,
          reason: 'viewed >= idle means nobody needs the reminder');
      store.dispose();
    });

    test('session without idle time is skipped', () async {
      final s1 = _sessionFull('s1');
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isFalse);
      store.dispose();
    });

    test('child sessions are skipped', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final p1 = _sessionFull('p1');
      final c1 = _sessionFull('c1', idle: now - 60000, parentID: 'p1');
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(p1);
      store.upsertSessionForTesting(c1);
      store.onEventForTesting(_ev('session.execution.started', 'c1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [p1, c1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('c1'), isFalse);
      store.dispose();
    });

    test('failed outcome is retro-notified (error settle)', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000, outcome: 'failed');
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.statusOf('s1').type, 'error');
      expect(NotificationService.debugHasRunSlot('s1'), isTrue,
          reason: 'failure shares the completion slot (D24)');
      store.dispose();
    });

    test('late settle event after the retro notify stays single', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isTrue);

      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isTrue,
          reason: 'wasBusy is false after the reconcile flip — the event '
          'handler must not re-notify');
      store.dispose();
    });

    test('event-first settle then reconcile does not retro-notify', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      NotificationService.debugResetSlots();

      store.mergeStatusForTesting(fresh: {}, sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isFalse,
          reason: 'the diff only fires for sids still believed busy — the '
          'event already settled the map');
      store.dispose();
    });

    test('retry retained by the reconcile is not retro-notified', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
        'error': {'message': 'x'}
      }));

      store.mergeStatusForTesting(
          fresh: {'s1': const SessionStatusValue('retry')},
          sessions: [s1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.statusOf('s1').type, 'retry',
          reason: 'the retention branch keeps the local retry');
      expect(NotificationService.debugHasRunSlot('s1'), isFalse);
      store.dispose();
    });

    test('snapshot race: busy learned after the snapshot is not notified',
        () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', idle: now - 60000);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(s1);
      final snapBefore = DateTime.now().millisecondsSinceEpoch - 1000;
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      store.mergeStatusForTesting(
          fresh: {}, sessions: [s1], snapshotBeforeMs: snapBefore);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(store.statusOf('s1').type, 'idle');
      expect(NotificationService.debugHasRunSlot('s1'), isFalse,
          reason: 'SSE started-event processed after the activeSessions '
          'snapshot was taken — the snapshot idle predates the run');

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.mergeStatusForTesting(
          fresh: {},
          sessions: [s1],
          snapshotBeforeMs: DateTime.now().millisecondsSinceEpoch + 1000);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasRunSlot('s1'), isTrue,
          reason: 'busy learned before the snapshot was taken — a true '
          'blind window still notifies');
      store.dispose();
    });
  });

  group('S26 retro card notify', () {
    Permission makePerm(String sid, String pid) =>
        Permission(id: pid, sessionID: sid, action: 'bash');

    test('blind-window permission card is retro-notified when unseen',
        () async {
      final s1 = _sessionFull('s1');
      final store = ServerStore()
        ..client = _CardBackfillClient(
            permissions: (sid) async => [makePerm(sid, 'p1')])
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      await store.backfillPermissionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isTrue,
          reason: 'the card arrived during the blind window and nobody has '
          'ever viewed the session');
      store.dispose();
    });

    test('viewed at/after the card watermark is not notified', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', viewed: now);
      final store = ServerStore()
        ..client = _CardBackfillClient(
            permissions: (sid) async => [makePerm(sid, 'p1')],
            latestMessages: (sid) async =>
                Future.value(LatestMessageSummary(at: now - 60000)))
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      await store.backfillPermissionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isFalse,
          reason: 'a view at/after the message watermark means the card was '
          'seen');
      store.dispose();
    });

    test('viewed before the card watermark is notified', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final s1 = _sessionFull('s1', viewed: now - 120000);
      final store = ServerStore()
        ..client = _CardBackfillClient(
            permissions: (sid) async => [makePerm(sid, 'p1')],
            latestMessages: (sid) async =>
                Future.value(LatestMessageSummary(at: now - 60000)))
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      await store.backfillPermissionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isTrue,
          reason: 'the last view predates the card — it is unseen');
      store.dispose();
    });

    test('already-known card is not re-notified by the backfill', () async {
      final s1 = _sessionFull('s1');
      final store = ServerStore()
        ..client = _CardBackfillClient(
            permissions: (sid) async => [makePerm(sid, 'p1')])
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      store.onEventForTesting(_ev('permission.asked', 's1',
          {'id': 'p1', 'action': 'bash'}));
      NotificationService.debugResetSlots();

      await store.backfillPermissionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isFalse,
          reason: 'the live event already notified; prev contains p1');
      store.dispose();
    });

    test('live event inside the backfill window is not re-notified',
        () async {
      final s1 = _sessionFull('s1');
      final perm = makePerm('s1', 'p1');
      var fetched = false;
      final store = ServerStore()
        ..client = _CardBackfillClient(permissions: (sid) async {
          fetched = true;
          return [perm];
        })
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      final backfill = store.backfillPermissionsForTesting();
      while (!fetched) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      store.onEventForTesting(_ev('permission.asked', 's1',
          {'id': 'p1', 'action': 'bash'}));
      NotificationService.debugResetSlots();
      await backfill;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isFalse,
          reason: 'the live handler notified inside the fetch window; the '
          'retro loop must skip liveArrived ids (BN-R46)');
      store.dispose();
    });

    test('answered elsewhere finds no pending card', () async {
      final s1 = _sessionFull('s1');
      final store = ServerStore()
        ..client = _CardBackfillClient(permissions: (sid) async => [])
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      await store.backfillPermissionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isFalse);
      store.dispose();
    });

    test('blind-window question (form) card is retro-notified', () async {
      final s1 = _sessionFull('s1');
      final form = FormInfo(
          id: 'f1', sessionID: 's1', title: 'pick one', fields: const []);
      final store = ServerStore()
        ..client = _CardBackfillClient(forms: (sid) async => [form])
        ..connected = true;
      store.upsertSessionForTesting(s1);
      store.onEventForTesting(_ev('session.execution.started', 's1'));

      await store.backfillQuestionsForTesting();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(NotificationService.debugHasCardSlot('s1'), isTrue);
      store.dispose();
    });
  });

  group('KeepaliveController', () {
    tearDown(() {
      KeepaliveController.I.disposeForTesting();
      KeepaliveController.armTimeout = const Duration(seconds: 15);
      TestWidgetsFlutterBinding.instance
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });

    test('streaming rise starts FGS; drop to zero stops immediately', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);
      expect(KeepaliveController.I.observationActive, isTrue);

      NotificationService.debugSeedSlot(run: 's1');
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(KeepaliveController.I.observationActive, isFalse);
      expect(backend.stops, 1);
      store.dispose();
    });

    test('streaming rise after a stop re-starts the FGS', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);

      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(backend.stops, 1);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1, 1]);
      expect(backend.updates, isEmpty);
      expect(KeepaliveController.I.observationActive, isTrue);
      store.dispose();
    });

    test('toggle off by default: streaming rise never starts FGS', () async {
      taskCompleteNotify.value = false;
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, isEmpty);
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });

    test('toggling on while streaming starts the FGS', () async {
      taskCompleteNotify.value = false;
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, isEmpty);

      taskCompleteNotify.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);
      expect(KeepaliveController.I.observationActive, isTrue);
      store.dispose();
    });

    test('toggling off while watching stops the FGS', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);

      taskCompleteNotify.value = false;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.stops, 1);
      expect(KeepaliveController.I.observationActive, isFalse);

      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.stops, 1, reason: 'store changes stay inert while off');
      store.dispose();
    });

    test('toggle on without streaming does not start', () async {
      taskCompleteNotify.value = false;
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      taskCompleteNotify.value = true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, isEmpty);
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });

    test('prompt-sent starts the watcher before the busy rise (armed)',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      KeepaliveController.I.armOnUserPromptSent();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1],
          reason: 'send time is guaranteed foreground; the watcher must not '
          'wait for the busy event');
      expect(KeepaliveController.I.observationActive, isTrue);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1], reason: 'the rise must not start twice');
      expect(backend.updates, [1]);
      store.dispose();
    });

    test('armed watcher stops when no run materializes', () async {
      KeepaliveController.armTimeout = const Duration(milliseconds: 60);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      KeepaliveController.I.armOnUserPromptSent();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1]);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backend.stops, 1);
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });

    test('armed watcher follows the run lifecycle and expiry is a no-op',
        () async {
      KeepaliveController.armTimeout = const Duration(milliseconds: 60);
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      KeepaliveController.I.armOnUserPromptSent();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1]);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.updates, [1]);

      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(backend.stops, 1);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(backend.stops, 1,
          reason: 'arm expiry after the run already settled must not re-fire');
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });

    test('rise while inactive (notification shade) starts the FGS', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1],
          reason: 'inactive keeps the activity visible; a background FGS '
          'start is still allowed by the system');
      store.dispose();
    });

    test('rise while hidden (stopped) does not start the FGS', () async {
      final binding = TestWidgetsFlutterBinding.instance;
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, isEmpty,
          reason: 'onStop dispatched means a background FGS start would be '
          'rejected (D2); the trailing lifecycle reset lives in tearDown '
          '(post-dispose) so the observer cannot re-enter');
      store.dispose();
    });

    test('arm expiry racing the in-flight start still stops; background '
        'stop pauses', () async {
      KeepaliveController.armTimeout = const Duration(milliseconds: 50);
      final store = _PauseSpyStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _GateStartBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      KeepaliveController.I.armOnUserPromptSent();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1], reason: 'armed start fires before busy');
      store.setAppForeground(false);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      backend.gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.stops, 1,
          reason: 'the timer expired while start was in flight; the '
          'post-start recheck must read timer isActive (not a captured '
          'flag) and stop');
      expect(KeepaliveController.I.observationActive, isFalse);
      expect(store.pauses, 1, reason: 'a background stop also pauses SSE');
      store.dispose();
    });
  });
}
