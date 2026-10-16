import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/notifications/notification_service.dart';
import 'package:open_builder/core/platform/keepalive_controller.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
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
  Future<bool?> requestPermission() async => true;

  @override
  Future<bool> notificationsEnabled() async => true;
}

class _GatePermBackend extends KeepaliveBackend {
  final starts = <int>[];
  final grant = Completer<bool?>();
  int permRequests = 0;

  @override
  Future<void> start(int count) async {
    starts.add(count);
  }

  @override
  Future<void> updateCount(int count) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool?> requestPermission() {
    permRequests++;
    return grant.future;
  }

  @override
  Future<bool> notificationsEnabled() async =>
      grant.isCompleted && await grant.future == true;
}

class _MutablePermBackend extends _FakeBackend {
  bool? perm = true;

  @override
  Future<bool?> requestPermission() async => perm;

  @override
  Future<bool> notificationsEnabled() async => perm == true;
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    NotificationService.debugMarkInitialized();
    NotificationService.debugFakeShow = true;
    NotificationService.debugResetSlots();
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
      expect(store.streamingSessionCount, 2);
      store.onEventForTesting(
          _ev('permission.asked', 'c1', {'id': 'perm2', 'action': 'bash'}));
      expect(store.streamingSessionCount, 0,
          reason: 'card floats to host p1; both runs are blocked');
      store.onEventForTesting(
          _ev('permission.replied', 'c1', {'requestID': 'perm2'}));
      expect(store.streamingSessionCount, 2);
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
  });

  group('KeepaliveController', () {
    tearDown(() {
      KeepaliveController.I.disposeForTesting();
      KeepaliveController.lingerWindow = const Duration(minutes: 3);
      KeepaliveController.lingerTickInterval = const Duration(seconds: 15);
    });

    test('streaming rise starts FGS; drop to zero lingers then stops', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);
      KeepaliveController.lingerWindow = const Duration(milliseconds: 80);
      KeepaliveController.lingerTickInterval = const Duration(milliseconds: 10);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);
      expect(KeepaliveController.I.observationActive, isTrue);

      NotificationService.debugSeedSlot(run: 's1');
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(KeepaliveController.I.lingering, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(KeepaliveController.I.lingering, isFalse);
      expect(backend.stops, 1);
      store.dispose();
    });

    test('streaming rise during linger cancels the stop', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);
      KeepaliveController.lingerWindow = const Duration(milliseconds: 80);
      KeepaliveController.lingerTickInterval = const Duration(milliseconds: 10);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(backend.starts, [1]);

      NotificationService.debugSeedSlot(run: 's1');
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      expect(KeepaliveController.I.lingering, isTrue);
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      expect(KeepaliveController.I.lingering, isFalse);
      expect(backend.updates, [1]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(backend.stops, 0);
      store.dispose();
    });

    test('empty slots stop lingering early', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      store.setActiveConversation('s1');
      final backend = _FakeBackend();
      KeepaliveController.I.init(store: store, backend: backend);
      KeepaliveController.lingerWindow = const Duration(milliseconds: 80);
      KeepaliveController.lingerTickInterval = const Duration(milliseconds: 10);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(KeepaliveController.I.lingering, isFalse);
      expect(backend.stops, 1);
      store.dispose();
    });

    test('onUserPromptSent is a no-op when unsupported', () async {
      await KeepaliveController.I.onUserPromptSent();
    });

    test('prompt-sent grant starts FGS once even if rise raced the dialog',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _GatePermBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      final sent = KeepaliveController.I.onUserPromptSent();
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, isEmpty);

      backend.grant.complete(true);
      await sent;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1]);
      expect(KeepaliveController.I.observationActive, isTrue);
      store.dispose();
    });

    test('prompt-sent deny disables observation', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _GatePermBackend();
      backend.grant.complete(false);
      KeepaliveController.I.init(store: store, backend: backend);

      await KeepaliveController.I.onUserPromptSent();
      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, isEmpty);
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });

    test('manual re-enable then prompt-sent restores observation', () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _MutablePermBackend()..perm = false;
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(KeepaliveController.I.observationActive, isFalse);

      backend.perm = true;
      await KeepaliveController.I.onUserPromptSent();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.starts, [1]);
      expect(KeepaliveController.I.observationActive, isTrue);
      store.dispose();
    });

    test('never-granted install: rise never requests permission (no dialog)',
        () async {
      final store = ServerStore()
        ..client = _fakeClient()
        ..connected = true;
      store.upsertSessionForTesting(_session('s1'));
      final backend = _GatePermBackend();
      KeepaliveController.I.init(store: store, backend: backend);

      store.onEventForTesting(_ev('session.execution.started', 's1'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(backend.permRequests, 0);
      expect(backend.starts, isEmpty);
      expect(KeepaliveController.I.observationActive, isFalse);
      store.dispose();
    });
  });
}
