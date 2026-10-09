import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Session status lives only in the in-memory `_statusMap` cache. On background
// resume it must show the pre-leave status first, then update from REST — and a
// failed active-sessions fetch must NOT wipe a known busy/retry indicator to
// idle (the regression behind cdb0872 / SS-1; v2 uses one server-wide
// GET /api/session/active call instead of v1's per-directory fan-out).

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

SessionModel _session({required String id, required String directory}) =>
    SessionModel.fromJson({
      'id': id,
      'projectID': 'p1',
      'location': {'directory': directory},
      'title': 't',
      'time': {'updated': 1000},
    });

OpencodeEvent _busyEvent(String sid) => OpencodeEvent(
      type: 'session.execution.started',
      properties: {'sessionID': sid},
    );

void main() {
  test('resume keeps cached status when the active-sessions fetch fails', () {
    // Pre-leave state: both sessions busy (seeded live via execution events).
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.upsertSessionForTesting(_session(id: 's2', directory: '/dirB'));
    store.onEventForTesting(_busyEvent('s1'));
    store.onEventForTesting(_busyEvent('s2'));
    expect(store.statusOf('s1').type, 'busy');
    expect(store.statusOf('s2').type, 'busy');

    // Resume refresh: the single active-sessions call FAILED — cached values
    // survive (fetch failure must not wipe known busy indicators).
    store.mergeStatusForTesting(
      fresh: const {},
      sessions: [
        _session(id: 's1', directory: '/dirA'),
        _session(id: 's2', directory: '/dirB'),
      ],
      fetched: false,
    );
    expect(store.statusOf('s1').type, 'busy',
        reason: 'cached pre-leave status retained on fetch failure');
    expect(store.statusOf('s2').type, 'busy',
        reason: 'cached pre-leave status retained on fetch failure');
    store.dispose();
  });

  test('failed activeSessions REST call skips the merge (production path)',
      () async {
    final store = ServerStore()..client = _FailingActiveClient();
    store.installSseForTesting(SseClient(baseUrl: 'http://127.0.0.1:9'));
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(_busyEvent('s1'));
    expect(store.statusOf('s1').type, 'busy');

    final ok = await store.refreshListAndWorkingSse(force: false);
    expect(ok, isTrue,
        reason: 'projects/sessions succeeded; only the active fetch failed');
    expect(store.statusOf('s1').type, 'busy',
        reason: 'a failed active-sessions fetch must not reset statuses');
    store.dispose();
  });

  test('retry indicator survives a refresh while the session still runs', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(OpencodeEvent(
      type: 'session.retry.scheduled',
      properties: {
        'sessionID': 's1',
        'assistantMessageID': 'm1',
        'attempt': 1,
        'error': {'message': 'provider 502'},
      },
    ));
    expect(store.statusOf('s1').type, 'retry');

    // Refresh succeeds; the retrying session is still running → present in
    // the active map as busy. The retry detail must survive the merge.
    store.mergeStatusForTesting(
      fresh: const {'s1': SessionStatusValue('busy')},
      sessions: [_session(id: 's1', directory: '/dirA')],
    );
    expect(store.statusOf('s1').type, 'retry',
        reason: 'still-running retry keeps its retry state over fresh busy');
    store.dispose();
  });

  test('stale retry is cleared once the session stops running', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(OpencodeEvent(
      type: 'session.retry.scheduled',
      properties: {
        'sessionID': 's1',
        'assistantMessageID': 'm1',
        'attempt': 1,
        'error': {'message': 'provider 502'},
      },
    ));
    expect(store.statusOf('s1').type, 'retry');

    // The session settled while SSE was missed: absent from the active map
    // on a SUCCESSFUL fetch → idle (previously stuck as retry forever).
    store.mergeStatusForTesting(
      fresh: const {},
      sessions: [_session(id: 's1', directory: '/dirA')],
    );
    expect(store.statusOf('s1').type, 'idle',
        reason: 'absence from a successful active fetch means idle');
    store.dispose();
  });

  test('error status survives a refresh while the session is inactive', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(_busyEvent('s1'));
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.execution.failed',
      properties: {'sessionID': 's1'},
    ));
    expect(store.statusOf('s1').type, 'error');

    // A terminal error is not an active state: the session is absent from
    // the active map, and that absence must NOT wash the error back to idle.
    store.mergeStatusForTesting(
      fresh: const {},
      sessions: [_session(id: 's1', directory: '/dirA')],
    );
    expect(store.statusOf('s1').type, 'error',
        reason: 'terminal error survives reconcile while nothing is running');
    store.dispose();
  });

  test('error status is cleared once the session runs again', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(_busyEvent('s1'));
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.execution.failed',
      properties: {'sessionID': 's1'},
    ));
    expect(store.statusOf('s1').type, 'error');

    // A fresh run reported by the active map replaces the stale error.
    store.mergeStatusForTesting(
      fresh: const {'s1': SessionStatusValue('busy')},
      sessions: [_session(id: 's1', directory: '/dirA')],
    );
    expect(store.statusOf('s1').type, 'busy',
        reason: 'a new run overrides a previous terminal error');
    store.dispose();
  });

  test('reconciled idle clears a stale error from the status map', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    final conv = store.ensureConversation('s1');
    store.onEventForTesting(_busyEvent('s1'));
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.execution.failed',
      properties: {'sessionID': 's1'},
    ));
    expect(store.statusOf('s1').type, 'error');

    // The session re-ran to success while we were offline: the reconciled
    // message page (finish=stop) is authoritative evidence of idle.
    conv!.applyReconciledStatus('idle');
    expect(store.statusOf('s1').type, 'idle',
        reason: 'reconcile evidence clears the sticky error');
    expect(conv.status, 'idle');
    store.dispose();
  });

  test('reconciled terminal error propagates to an idle status map', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    final conv = store.ensureConversation('s1');

    conv!.applyReconciledStatus('error');
    expect(store.statusOf('s1').type, 'error',
        reason: 'finish=error evidence marks the list status too');
    expect(conv.status, 'error');
    store.dispose();
  });

  test('reconciled error does not clobber a running status map', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    final conv = store.ensureConversation('s1');
    store.onEventForTesting(_busyEvent('s1'));
    expect(store.statusOf('s1').type, 'busy');

    conv!.applyReconciledStatus('error');
    expect(store.statusOf('s1').type, 'busy',
        reason: 'a live run outranks page-tail error evidence');
    store.dispose();
  });

  test('resume applies fresh status for every successfully fetched session',
      () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.upsertSessionForTesting(_session(id: 's2', directory: '/dirB'));
    store.onEventForTesting(_busyEvent('s1'));
    store.onEventForTesting(_busyEvent('s2'));

    store.mergeStatusForTesting(
      fresh: const {
        's1': SessionStatusValue('idle'),
        's2': SessionStatusValue('busy'),
      },
      sessions: [
        _session(id: 's1', directory: '/dirA'),
        _session(id: 's2', directory: '/dirB'),
      ],
    );
    expect(store.statusOf('s1').type, 'idle');
    expect(store.statusOf('s2').type, 'busy');
    store.dispose();
  });

  test('covered session absent from fresh response is idle (no stuck busy)',
      () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(_busyEvent('s1'));

    // Fetch succeeded but the server returned no entry for s1 ⇒ idle now.
    store.mergeStatusForTesting(
      fresh: const {},
      sessions: [_session(id: 's1', directory: '/dirA')],
    );
    expect(store.statusOf('s1').type, 'idle');
    store.dispose();
  });

  test('status is not restored from disk cache (in-memory only)', () async {
    SharedPreferences.setMockInitialValues({
      'server_${_profile.id}': jsonEncode({
        'v': 1,
        'projects': <Map<String, dynamic>>[],
        'sessions': <Map<String, dynamic>>[],
        // A stale on-disk status must be ignored, not painted as busy.
        'status': {'s1': {'type': 'busy'}},
        'lastMessage': <String, dynamic>{},
        'activity': <String, dynamic>{},
        'workspaceEnabled': <String, dynamic>{},
      }),
    });
    final store = ServerStore()..client = _fakeClient();
    await store.loadCacheForTesting(_profile);
    expect(store.statusOf('s1').type, 'idle',
        reason: 'status must not be persisted/restored from disk');
    store.dispose();
  });
}

class _FailingActiveClient extends OpencodeClient {
  _FailingActiveClient()
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<List<ProjectModel>> projects() async => [
        const ProjectModel(id: 'p1', canonical: '/dirA'),
      ];

  @override
  Future<List<SessionModel>> sessions({
    String? directory,
    String? project,
    String? subpath,
    int limit = 1000,
    String? search,
    String? parentID,
  }) async =>
      [];

  @override
  Future<Map<String, SessionStatusValue>> activeSessions() async {
    throw Exception('active fetch failed');
  }
}
