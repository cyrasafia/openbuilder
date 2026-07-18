import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

const _profile = ConnectionProfile(
  id: 't',
  name: 'test',
  address: 'http://127.0.0.1:9',
  username: 'opencode',
  password: '',
);

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

// Direct SessionModel constructor — for tests that need to drive REST-path
// code (e.g. _addSessions) without going through SSE event parsing.
SessionModel _session({
  required String id,
  required String projectID,
  required String directory,
  required int updated,
  int? archived,
}) {
  final time = <String, dynamic>{'created': 1, 'updated': updated};
  if (archived != null) time['archived'] = archived;
  return SessionModel.fromJson({
    'id': id,
    'projectID': projectID,
    'directory': directory,
    'title': 't',
    'time': time,
  });
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
  // exposes them) also count toward the project's activity. Today `/session`
  // filters archived server-side, so this mainly locks the `_addSessions`
  // ordering invariant: bump happens BEFORE the archived/parent filter — not
  // after. Drives the REST path directly via `addSessionsForTesting`, not the
  // SSE `_upsertSession` path (which PA-1 already covers).
  test('_addSessions bumps activity before archived filter (PA-4)', () {
    final store = ServerStore()..client = _fakeClient();
    final out = <String, SessionModel>{};
    store.addSessionsForTesting(out, [
      _session(
          id: 's1',
          projectID: 'p1',
          directory: '/r',
          updated: 7777,
          archived: 9999),
      _session(id: 's2', projectID: 'p1', directory: '/r', updated: 1000),
    ]);
    // Archived session is filtered out of the visible map...
    expect(out.length, 1);
    expect(out['s1'], isNull);
    expect(out['s2'], isNotNull);
    // ...but its activity was recorded before the filter dropped it.
    expect(store.lastActivityForProject('p1'), 7777);
    store.dispose();
  });

  // PA-5: hard-deleting a session (SSE session.deleted → _removeSession) must
  // NOT reset the project's activity. `_removeSession` intentionally keeps
  // `_lastActivityByKey` — monotonicity holds across deletes too, so deleting
  // the last observed session in a project doesn't sink the project. Locks
  // the comment in `_removeSession` against a future regression that adds a
  // `_lastActivityByKey.remove(...)` line.
  test('hard delete keeps project activity (PA-5)', () {
    final store = ServerStore()..client = _fakeClient();
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/r', updated: 4321));
    expect(store.lastActivityForProject('p1'), 4321);
    // Drive a session.deleted event → _removeSession.
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.deleted',
      properties: <String, dynamic>{
        'info': <String, dynamic>{'id': 's1'},
      },
    ));
    expect(store.sessions, isEmpty);
    // Activity is preserved even though the session is gone.
    expect(store.lastActivityForProject('p1'), 4321);
    store.dispose();
  });

  // PA-R2a: cache round-trip — an `activity` blob written to SharedPreferences
  // by `_saveCache` is restored by `_loadCache`. Locks the JSON shape (NUL-
  // escaped key encoding, int value) and the v1 schema field name `activity`.
  test('cache round-trip restores activity map (PA-R2a)', () async {
    SharedPreferences.setMockInitialValues({
      'server_${_profile.id}': jsonEncode({
        'v': 1,
        'projects': <Map<String, dynamic>>[],
        'sessions': <Map<String, dynamic>>[],
        'status': <String, dynamic>{},
        'lastMessage': <String, dynamic>{},
        'activity': {
          'p1': 5000,
          'global\u0000/dirA': 7000,
        },
      }),
    });
    final store = ServerStore()..client = _fakeClient();
    await store.loadCacheForTesting(_profile);
    expect(store.lastActivityForProject('p1'), 5000);
    expect(store.lastActivityForGlobalDir('/dirA'), 7000);
    store.dispose();
  });

  // PA-R2b: monotonic-max merge — a stale cached value must NOT overwrite a
  // larger in-memory value already set by SSE before `_loadCache` runs. Today
  // `connect()` clears the map before `_loadCache`, so the merge is currently
  // equivalent to a straight fill; this test guards the defensive branch for
  // future call paths that might load cache after SSE starts.
  test('cache load uses monotonic-max merge (PA-R2b)', () async {
    // In-memory value 9000 (fresher, set by SSE).
    final store = ServerStore()..client = _fakeClient();
    store.onEventForTesting(_sessionEvent(
        id: 's1', projectID: 'p1', directory: '/r', updated: 9000));
    expect(store.lastActivityForProject('p1'), 9000);
    // Cache has an older value 5000 — must NOT overwrite.
    SharedPreferences.setMockInitialValues({
      'server_${_profile.id}': jsonEncode({
        'v': 1,
        'activity': {'p1': 5000},
      }),
    });
    await store.loadCacheForTesting(_profile);
    expect(store.lastActivityForProject('p1'), 9000);
    // But for a key not yet in memory, the cached value fills in.
    expect(store.lastActivityForProject('p2'), 0); // sanity: absent key
    SharedPreferences.setMockInitialValues({
      'server_${_profile.id}': jsonEncode({
        'v': 1,
        'activity': {'p2': 3000},
      }),
    });
    await store.loadCacheForTesting(_profile);
    expect(store.lastActivityForProject('p2'), 3000);
    // p1 should still be 9000 (loading p2's cache didn't reset p1's SSE value).
    expect(store.lastActivityForProject('p1'), 9000);
    store.dispose();
  });
}
