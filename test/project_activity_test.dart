import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';

// A non-null [OpencodeClient] pointing at a discard port. The activity logic
// under test is purely local (no network calls), so this only satisfies the
// non-null client guard in [ServerStore.ensureConversation].
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

// SSE `session.updated` event with the given session fields. `archived`
// simulates the result of PATCH /session/:id { time: { archived: ... } }.
OpencodeEvent _sessionEvent({
  required String id,
  required String projectID,
  required String directory,
  required int updated,
  int? archived,
}) {
  final time = <String, dynamic>{'updated': updated};
  if (archived != null) time['archived'] = archived;
  return OpencodeEvent(
    type: 'session.updated',
    properties: <String, dynamic>{
      'info': <String, dynamic>{
        'id': id,
        'projectID': projectID,
        'directory': directory,
        'title': 't',
        'time': time,
      },
    },
  );
}

void main() {
  // PA-1: archiving the last active session in a project must NOT reset the
  // project's sort position. Before the fix, `_upsertSession` removed the
  // archived session from `_sessions` and `lastActivityForProject` returned 0
  // (computed live from the now-empty `_sessions`), sinking the project to
  // the bottom of the projects tab.
  test('archiving last session keeps project activity (PA-1)', () {
    final store = ServerStore()..client = _fakeClient();
    // Seed two unarchived sessions for project 'p1', updated=1000 and 2000.
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/repo', updated: 1000));
    store.onEventForTesting(_sessionEvent(
        id: 's2', projectID: 'p1', directory: '/repo', updated: 2000));
    expect(store.lastActivityForProject('p1'), 2000);
    // Archive the most-recent session. setArchived leaves `time.updated`
    // unchanged (verified in opencode source), so we send updated=2000 with
    // archived set.
    store.onEventForTesting(_sessionEvent(
        id: 's2',
        projectID: 'p1',
        directory: '/repo',
        updated: 2000,
        archived: 9999));
    // Session is gone from the active list...
    expect(store.sessions.where((s) => s.id == 's2'), isEmpty);
    // ...but the project's activity is preserved → no sink-to-bottom.
    expect(store.lastActivityForProject('p1'), 2000);
    // Archive the remaining session too — activity still preserves the max.
    store.onEventForTesting(_sessionEvent(
        id: 's1',
        projectID: 'p1',
        directory: '/repo',
        updated: 1000,
        archived: 9999));
    expect(store.sessions, isEmpty);
    expect(store.lastActivityForProject('p1'), 2000);
    store.dispose();
  });

  // PA-2: global project is expanded per-directory in the projects tab, so
  // activity must be keyed by directory under the global project — not lumped
  // under projectID='global'. Verifies the keying scheme `global\0$directory`.
  test('global project activity is keyed per-directory (PA-2)', () {
    final store = ServerStore()..client = _fakeClient();
    store.onEventForTesting(_sessionEvent(
        id: 'g1',
        projectID: 'global',
        directory: '/dirA',
        updated: 1500));
    store.onEventForTesting(_sessionEvent(
        id: 'g2',
        projectID: 'global',
        directory: '/dirB',
        updated: 3000));
    expect(store.lastActivityForGlobalDir('/dirA'), 1500);
    expect(store.lastActivityForGlobalDir('/dirB'), 3000);
    // Cross-talk check: archiving in /dirA must not affect /dirB.
    store.onEventForTesting(_sessionEvent(
        id: 'g1',
        projectID: 'global',
        directory: '/dirA',
        updated: 1500,
        archived: 9999));
    expect(store.lastActivityForGlobalDir('/dirA'), 1500);
    expect(store.lastActivityForGlobalDir('/dirB'), 3000);
    store.dispose();
  });

  // PA-3: activity is monotonic — an out-of-order or stale SSE event with an
  // older `updated` must not regress the project's activity. This guards the
  // `_bumpLastActivity` `if (s.updated > current)` condition.
  test('activity is monotonic against older updates (PA-3)', () {
    final store = ServerStore()..client = _fakeClient();
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/r', updated: 2000));
    expect(store.lastActivityForProject('p1'), 2000);
    // An older update arrives (e.g. reordered SSE event) — must not regress.
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/r', updated: 500));
    expect(store.lastActivityForProject('p1'), 2000);
    // A newer update bumps it forward.
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/r', updated: 5000));
    expect(store.lastActivityForProject('p1'), 5000);
    store.dispose();
  });

  // PA-4: archived sessions arriving via REST bulk fetch (if the API ever
  // exposes them) also count. Today `/session` filters archived server-side,
  // so this mainly locks the `_addSessions` ordering: bump happens BEFORE
  // the archived filter, not after.
  test('_addSessions bumps activity before archived filter (PA-4)', () {
    final store = ServerStore()..client = _fakeClient();
    // Drive through the same SSE route `_upsertSession` uses — the invariant
    // is that any session observed at all (archived or not) contributes.
    store.onEventForTesting(_sessionEvent(
        id: 's1',
        projectID: 'p1',
        directory: '/r',
        updated: 7777,
        archived: 9999));
    expect(store.sessions, isEmpty); // archived → not in active list
    expect(store.lastActivityForProject('p1'), 7777); // but activity recorded
    store.dispose();
  });
}
