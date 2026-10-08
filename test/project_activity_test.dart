import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/cache/cache_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';

// A non-null [OpencodeClient] pointing at a discard port. The order-key logic
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

// Direct SessionModel constructor — for tests that need to drive REST-path
// code (e.g. _addSessions) without going through SSE event parsing.
// time map shape matches `_sessionEvent` (only `updated` + optional
// `archived`; `created` is irrelevant to order-key logic and omitted for
// symmetry — `SessionModel.fromJson` defaults it to 0).
SessionModel _session({
  required String id,
  required String projectID,
  required String directory,
  required int updated,
  int? archived,
}) {
  final time = <String, dynamic>{'updated': updated};
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
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('project_activity_test');
    FileCacheStore.rootBaseOverride = Directory('${tmp.path}/ob_cache');
  });
  tearDown(() async {
    FileCacheStore.rootBaseOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  // Order key = latest `time.updated` among the project's unarchived
  // sessions. When none remain it falls back to the `_lastActivityByKey`
  // watermark (includes archived sessions' history) so a freshly-emptied
  // project doesn't instantly sink to the bottom.
  test('order key follows unarchived sessions, watermark fallback (PA-1)', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/repo', updated: 1000));
    store.upsertSessionForTesting(
        _session(id: 's2', projectID: 'p1', directory: '/repo', updated: 2000));
    expect(store.projectOrderKey('p1'), 2000);
    // Archive the most-recent session: the key now mirrors the remaining
    // unarchived session (1000), NOT the higher watermark.
    store.upsertSessionForTesting(
        _session(id: 's2',
        projectID: 'p1',
        directory: '/repo',
        updated: 2000,
        archived: 9999));
    expect(store.projectOrderKey('p1'), 1000);
    // Archive the remaining session too — watermark fallback kicks in.
    store.upsertSessionForTesting(
        _session(id: 's1',
        projectID: 'p1',
        directory: '/repo',
        updated: 1000,
        archived: 9999));
    expect(store.sessions, isEmpty);
    expect(store.projectOrderKey('p1'), 2000);
    store.dispose();
  });

  // Archived history must never LIFT a project above its unarchived max —
  // the watermark is a fallback only, not a max() over both sources.
  test('archived watermark does not lift order key (PA-1b)', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1',
        projectID: 'p1',
        directory: '/repo',
        updated: 9000,
        archived: 9999));
    store.upsertSessionForTesting(
        _session(id: 's2', projectID: 'p1', directory: '/repo', updated: 1000));
    expect(store.projectOrderKey('p1'), 1000);
    store.dispose();
  });

  // PA-2: global project is expanded per-directory in the projects tab, so
  // the order key must be keyed by directory under the global project — not
  // lumped under projectID='global'. Verifies the keying scheme
  // `global\0$directory` (watermark) plus per-directory unarchived max.
  test('global project order key is keyed per-directory (PA-2)', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 'g1',
        projectID: 'global',
        directory: '/dirA',
        updated: 1500));
    store.upsertSessionForTesting(
        _session(id: 'g2',
        projectID: 'global',
        directory: '/dirB',
        updated: 3000));
    expect(store.globalDirOrderKey('/dirA'), 1500);
    expect(store.globalDirOrderKey('/dirB'), 3000);
    // Cross-talk check: archiving in /dirA must not affect /dirB.
    store.upsertSessionForTesting(
        _session(id: 'g1',
        projectID: 'global',
        directory: '/dirA',
        updated: 1500,
        archived: 9999));
    expect(store.globalDirOrderKey('/dirA'), 1500);
    expect(store.globalDirOrderKey('/dirB'), 3000);
    store.dispose();
  });

  // PA-3: the primary key mirrors the server — an out-of-order snapshot with
  // an older `updated` regresses the key (server is authoritative). The
  // watermark behind the fallback stays monotonic.
  test('order key mirrors server; watermark stays monotonic (PA-3)', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 2000));
    expect(store.projectOrderKey('p1'), 2000);
    // An older snapshot arrives (e.g. reordered SSE replay) — key follows.
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 500));
    expect(store.projectOrderKey('p1'), 500);
    // But the watermark kept 2000: archiving all sessions falls back to it,
    // not to the regressed snapshot.
    store.upsertSessionForTesting(
        _session(id: 's1',
        projectID: 'p1',
        directory: '/r',
        updated: 500,
        archived: 9999));
    expect(store.projectOrderKey('p1'), 2000);
    store.dispose();
  });

  // PA-4: archived sessions arriving via REST bulk fetch (if the API ever
  // exposes them) also count toward the watermark fallback. Today `/session`
  // filters archived server-side, so this mainly locks the `_addSessions`
  // ordering invariant: bump happens BEFORE the archived/parent filter — not
  // after. Drives the REST path directly via `addSessionsForTesting`, not the
  // SSE `_upsertSession` path (which PA-1 already covers).
  test('_addSessions bumps watermark before archived filter (PA-4)', () {
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
    // ...its activity was recorded before the filter dropped it: with no
    // unarchived sessions in the store the key falls back to the watermark.
    expect(store.projectOrderKey('p1'), 7777);
    // An unarchived session (REST path upserts it) overrides the watermark.
    store.upsertSessionForTesting(
        _session(id: 's2', projectID: 'p1', directory: '/r', updated: 1000));
    expect(store.projectOrderKey('p1'), 1000);
    // ...and archiving s2 exposes the recorded watermark (7777) again.
    store.upsertSessionForTesting(
        _session(id: 's2',
        projectID: 'p1',
        directory: '/r',
        updated: 1000,
        archived: 9999));
    expect(store.projectOrderKey('p1'), 7777);
    store.dispose();
  });

  // PA-5: hard-deleting a session (SSE session.deleted → _removeSession) must
  // NOT reset the project's order key — the watermark survives deletes, so
  // deleting the last observed session doesn't sink the project. Locks the
  // comment in `_removeSession` against a future regression that adds a
  // `_lastActivityByKey.remove(...)` line.
  test('hard delete keeps project order key (PA-5)', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 4321));
    expect(store.projectOrderKey('p1'), 4321);
    // Drive a session.deleted event → _removeSession.
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.deleted',
      properties: <String, dynamic>{'sessionID': 's1'},
    ));
    expect(store.sessions, isEmpty);
    // Order key is preserved even though the session is gone.
    expect(store.projectOrderKey('p1'), 4321);
    store.dispose();
  });

  // PA-6: desktop writes `time.archived: 0` to un-archive (truthy check
  // there), while the mobile filter used `!= null` — so a desktop-unarchived
  // session vanished from the mobile session list. `SessionModel.fromJson`
  // now normalizes falsy `archived` (missing or 0) to null, matching the
  // desktop truthy semantics at every filter site.
  test('archived: 0 parses as unarchived (PA-6)', () {
    expect(_session(id: 's1', projectID: 'p1', directory: '/r', updated: 1000,
            archived: 0)
        .archived, isNull);
    expect(_session(id: 's1', projectID: 'p1', directory: '/r', updated: 1000)
        .archived, isNull);
    expect(
        _session(
                id: 's1', projectID: 'p1', directory: '/r', updated: 1000,
                archived: 9999)
            .archived,
        9999);
  });

  test('desktop unarchive (archived: 0 event) keeps session visible (PA-6)',
      () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 1000));
    // Archive from the mobile UI (real timestamp) — session drops out.
    store.upsertSessionForTesting(
        _session(id: 's1',
        projectID: 'p1',
        directory: '/r',
        updated: 1000,
        archived: 9999));
    expect(store.sessions.where((s) => s.id == 's1'), isEmpty);
    // Desktop un-archive writes archived: 0 — session must come back.
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 2000,
        archived: 0));
    expect(store.sessions.where((s) => s.id == 's1'), isNotEmpty);
    store.dispose();
  });

  // PA-R2a: cache round-trip — an `activity` blob written to SharedPreferences
  // by `_saveCache` is restored by `_loadCache`. Locks the JSON shape (NUL-
  // escaped key encoding, int value) and the v1 schema field name `activity`.
  test('cache round-trip restores watermark (PA-R2a)', () async {
    await FileCacheStore(_profile.id).write('server', jsonEncode({
      'v': 1,
      'projects': <Map<String, dynamic>>[],
      'sessions': <Map<String, dynamic>>[],
      'status': <String, dynamic>{},
      'lastMessage': <String, dynamic>{},
      'activity': {
        'p1': 5000,
        'global\u0000/dirA': 7000,
      },
    }));
    final store = ServerStore()..client = _fakeClient();
    await store.loadCacheForTesting(_profile);
    expect(store.projectOrderKey('p1'), 5000);
    expect(store.globalDirOrderKey('/dirA'), 7000);
    store.dispose();
  });

  // PA-R2b: monotonic-max merge — a stale cached value must NOT overwrite a
  // larger in-memory value already set by SSE before `_loadCache` runs. Today
  // `connect()` clears the map before `_loadCache`, so the merge is currently
  // equivalent to a straight fill; this test guards the defensive branch for
  // future call paths that might load cache after SSE starts.
  test('cache load uses monotonic-max merge (PA-R2b)', () async {
    // In-memory watermark 9000 (fresher, set by SSE).
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(
        _session(id: 's1', projectID: 'p1', directory: '/r', updated: 9000));
    expect(store.projectOrderKey('p1'), 9000);
    // Cache has an older value 5000 — must NOT overwrite.
    await FileCacheStore(_profile.id).write('server', jsonEncode({
      'v': 1,
      'activity': {'p1': 5000},
    }));
    await store.loadCacheForTesting(_profile);
    expect(store.projectOrderKey('p1'), 9000);
    // Drop the unarchived session so the key reads the watermark: the stale
    // cached 5000 must not have overwritten the in-memory 9000.
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.deleted',
      properties: <String, dynamic>{'sessionID': 's1'},
    ));
    expect(store.projectOrderKey('p1'), 9000);
    // But for a key not yet in memory, the cached value fills in.
    expect(store.projectOrderKey('p2'), 0); // sanity: absent key
    await FileCacheStore(_profile.id).write('server', jsonEncode({
      'v': 1,
      'activity': {'p2': 3000},
    }));
    await store.loadCacheForTesting(_profile);
    expect(store.projectOrderKey('p2'), 3000);
    // p1 should still be 9000 (loading p2's cache didn't reset p1's SSE value).
    expect(store.projectOrderKey('p1'), 9000);
    store.dispose();
  });
}
