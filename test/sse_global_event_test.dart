import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';

// Unit tests for the /api/event single-stream layer: envelope parsing in
// `parseGlobalEvent` and the ServerStore directory gate in `_onGlobalEvent`.

OpencodeEvent _sessionCreated({required String id, required String directory}) =>
    OpencodeEvent(
      type: 'session.created',
      properties: <String, dynamic>{
        'sessionID': id,
        'projectID': 'p1',
        'location': {'directory': directory},
        'title': 't',
      },
    );

SessionModel _session({required String id, required String directory}) =>
    SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': directory},
      'title': 't',
      'time': {'created': 1, 'updated': 1},
    });

ProjectModel _project(String canonical, {List<String> sandboxes = const []}) =>
    ProjectModel(id: 'p1', canonical: canonical, sandboxes: sandboxes);

void main() {
  group('parseGlobalEvent', () {
    test('envelope with location parses', () {
      final gev = parseGlobalEvent(
          '{"id":"evt_1","created":1790000000000,"type":"session.text.delta","location":{"directory":"/repo"},"data":{"sessionID":"s1","delta":"x"}}');
      expect(gev, isNotNull);
      expect(gev!.directory, '/repo');
      expect(gev.event.type, 'session.text.delta');
      expect(gev.event.id, 'evt_1');
      expect(gev.event.properties['sessionID'], 's1');
    });

    test('missing location defaults to global', () {
      final gev = parseGlobalEvent(
          '{"id":"evt_2","type":"server.heartbeat","data":{}}');
      expect(gev, isNotNull);
      expect(gev!.directory, 'global');
      expect(gev.event.type, 'server.heartbeat');
    });

    test('malformed JSON is dropped', () {
      expect(parseGlobalEvent('not json'), isNull);
      expect(parseGlobalEvent(''), isNull);
    });

    test('frames without a type are dropped', () {
      expect(parseGlobalEvent('{"id":"evt_1","data":{}}'), isNull);
      expect(parseGlobalEvent('{"data":"scalar"}'), isNull);
      expect(parseGlobalEvent('{"id":"evt_1","type":""}'), isNull);
    });
  });

  group('ServerStore directory gate', () {
    test('events from unknown directories are dropped', () {
      final store = ServerStore();
      store.setProjectsForTesting([_project('/repo')]);
      store.onGlobalEventForTesting('/other-project', _sessionCreated(id: 's1', directory: '/other-project'));
      expect(store.sessions, isEmpty,
          reason: 'single stream carries every project\'s events; '
              'non-gated directories must not pollute the store');
      store.dispose();
    });

    test('events from a project canonical pass the gate', () {
      final store = ServerStore();
      store.setProjectsForTesting([_project('/repo')]);
      store.onGlobalEventForTesting('/repo', _sessionCreated(id: 's1', directory: '/repo'));
      expect(store.sessions.map((s) => s.id), contains('s1'));
      store.dispose();
    });

    test('events from a sandbox directory pass the gate', () {
      final store = ServerStore();
      store.setProjectsForTesting(
          [_project('/repo', sandboxes: const ['/repo/.sandboxes/a1'])]);
      store.onGlobalEventForTesting(
          '/repo/.sandboxes/a1',
          _sessionCreated(id: 's1', directory: '/repo/.sandboxes/a1'));
      expect(store.sessions.map((s) => s.id), contains('s1'));
      store.dispose();
    });

    test('session-scoped events without location route by sessionID', () {
      final store = ServerStore();
      store.upsertSessionForTesting(_session(id: 's1', directory: '/known'));
      store.onGlobalEventForTesting(
          'global',
          const OpencodeEvent(
              type: 'session.execution.started',
              properties: {
                'sessionID': 's1',
              }));
      expect(store.statusOf('s1').type, 'busy',
          reason: 'location-less session events route by the session table');
      store.dispose();
    });

    test('session-scoped events for unknown sessions are dropped', () {
      final store = ServerStore();
      store.onGlobalEventForTesting(
          'global',
          const OpencodeEvent(
              type: 'session.execution.started',
              properties: {
                'sessionID': 's-unknown',
              }));
      expect(store.statusOf('s-unknown').type, 'idle');
      store.dispose();
    });

    test('directory-less global frames bypass the gate', () {
      final store = ServerStore();
      final before = store.reconcileScheduleCountForTesting;
      store.onGlobalEventForTesting(
          'global',
          const OpencodeEvent(
              type: 'worktree.resolved',
              properties: {
                'projectID': 'p9',
                'directory': '/newly-adopted',
                'previous': 'global',
              }));
      expect(store.reconcileScheduleCountForTesting, greaterThan(before),
          reason: "'global' frames bypass the directory gate");
      store.dispose();
    });

    test('isGatedDirectoryForTesting covers canonical/sandbox/session dirs', () {
      final store = ServerStore();
      store.setProjectsForTesting(
          [_project('/repo', sandboxes: const ['/repo/.sandboxes/a1'])]);
      store.upsertSessionForTesting(_session(id: 's1', directory: '/known'));
      expect(store.isGatedDirectoryForTesting('/repo'), isTrue);
      expect(store.isGatedDirectoryForTesting('/repo/.sandboxes/a1'), isTrue);
      expect(store.isGatedDirectoryForTesting('/known'), isTrue);
      expect(store.isGatedDirectoryForTesting('/elsewhere'), isFalse);
      expect(store.isGatedDirectoryForTesting(''), isFalse,
          reason: 'empty-string directories stay out of the gate, matching '
              'the isNotEmpty guards in _eventDirectories');
      store.dispose();
    });
  });

  group('reconcile scheduling on state transitions', () {
    test('per-frame connected emissions schedule reconcile only once', () {
      final store = ServerStore();
      store.onSseStateForTesting(const SseState(connected: true));
      store.onSseStateForTesting(const SseState(connected: true));
      store.onSseStateForTesting(const SseState(connected: true));
      expect(store.reconcileScheduleCountForTesting, 1,
          reason: 'repeated connected frames (stream traffic) must not '
              're-schedule reconcile');
      store.dispose();
    });

    test('reconnect transition schedules reconcile again', () {
      final store = ServerStore();
      store.onSseStateForTesting(const SseState(connected: true));
      store.onSseStateForTesting(const SseState(reconnecting: true, attempt: 1));
      store.onSseStateForTesting(const SseState(connected: true));
      expect(store.reconcileScheduleCountForTesting, 2,
          reason: 'the not-live → live transition after a drop must heal the '
              'disconnect window via reconcile');
      store.dispose();
    });
  });
}
