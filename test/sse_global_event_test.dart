import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';

// Unit tests for the /global/event single-stream layer (see
// design-sse-global-event.md): envelope parsing in `parseGlobalEvent` and the
// ServerStore directory gate in `_onGlobalEvent`.

OpencodeEvent _sessionCreated({required String id, required String directory}) =>
    OpencodeEvent(
      type: 'session.created',
      properties: <String, dynamic>{
        'info': <String, dynamic>{
          'id': id,
          'projectID': 'p1',
          'directory': directory,
          'title': 't',
          'time': <String, dynamic>{'created': 1, 'updated': 1},
        },
      },
    );

SessionModel _session({required String id, required String directory}) =>
    SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'directory': directory,
      'title': 't',
      'time': {'created': 1, 'updated': 1},
    });

ProjectModel _project(String worktree, {List<String> sandboxes = const []}) =>
    ProjectModel(id: 'p1', worktree: worktree, sandboxes: sandboxes);

void main() {
  group('parseGlobalEvent', () {
    test('envelope with directory parses', () {
      final gev = parseGlobalEvent(
          '{"directory":"/repo","project":"p1","payload":{"id":"evt_1","type":"session.status","properties":{"sessionID":"s1"}}}');
      expect(gev, isNotNull);
      expect(gev!.directory, '/repo');
      expect(gev.event.type, 'session.status');
      expect(gev.event.id, 'evt_1');
      expect(gev.event.properties['sessionID'], 's1');
    });

    test('missing directory defaults to global', () {
      final gev = parseGlobalEvent(
          '{"payload":{"type":"server.heartbeat","properties":{}}}');
      expect(gev, isNotNull);
      expect(gev!.directory, 'global');
      expect(gev.event.type, 'server.heartbeat');
    });

    test('sync double-emit wrapper is dropped', () {
      final gev = parseGlobalEvent(
          '{"directory":"/repo","payload":{"type":"sync","syncEvent":{"id":"evt_1","type":"message.part.updated.1","seq":1,"aggregateID":"s1","data":{}}}}');
      expect(gev, isNull);
    });

    test('malformed JSON is dropped', () {
      expect(parseGlobalEvent('not json'), isNull);
      expect(parseGlobalEvent(''), isNull);
    });

    test('non-envelope payloads are dropped', () {
      // Bare legacy-style event (no envelope): the /event frame shape must
      // NOT be parsed as a global envelope.
      expect(
          parseGlobalEvent('{"id":"evt_1","type":"session.status","properties":{}}'),
          isNull);
      expect(parseGlobalEvent('{"payload":"scalar"}'), isNull);
      expect(parseGlobalEvent('{"payload":{"properties":{}}}'), isNull);
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

    test('events from a project worktree pass the gate', () {
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

    test('events from a known session directory pass the gate', () {
      final store = ServerStore();
      // No projects — the session's own directory keeps it covered.
      store.upsertSessionForTesting(_session(id: 's1', directory: '/known'));
      store.onGlobalEventForTesting(
          '/known',
          const OpencodeEvent(
              type: 'session.status',
              properties: {
                'sessionID': 's1',
                'status': {'type': 'busy'},
              }));
      expect(store.statusOf('s1').type, 'busy',
          reason: 'known session directories are part of the gate universe');
      store.dispose();
    });

    test('directory-less global frames bypass the gate', () {
      final store = ServerStore();
      // server.connected arrives with directory 'global' — must never be
      // dropped by the gate (it drives reconcile).
      store.onGlobalEventForTesting(
          'global', _sessionCreated(id: 's1', directory: '/repo'));
      expect(store.sessions.map((s) => s.id), contains('s1'),
          reason: "'global' frames bypass the directory gate");
      store.dispose();
    });

    test('isGatedDirectoryForTesting covers worktree/sandbox/session dirs', () {
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
    // The SseClient emits connected state on EVERY data frame. Scheduling
    // reconcile per emission would reset the 800ms debounce on every token of
    // an active stream, deferring the post-disconnect reconcile indefinitely
    // while the server is busy. Reconcile must be scheduled exactly once per
    // not-live → live transition.
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
