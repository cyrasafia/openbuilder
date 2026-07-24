import 'dart:convert';

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
// directory whose status fetch failed must NOT wipe a known busy/retry
// indicator to idle (the regression behind cdb0872 / SS-1).

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
      'directory': directory,
      'title': 't',
      'time': {'updated': 1000},
    });

OpencodeEvent _statusEvent(String sid, String type) => OpencodeEvent(
      type: 'session.status',
      properties: {
        'sessionID': sid,
        'status': {'type': type},
      },
    );

void main() {
  test('resume keeps cached status when a directory fetch fails', () {
    // Pre-leave state: both sessions busy (seeded live via SSE).
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.upsertSessionForTesting(_session(id: 's2', directory: '/dirB'));
    store.onEventForTesting(_statusEvent('s1', 'busy'));
    store.onEventForTesting(_statusEvent('s2', 'busy'));
    expect(store.statusOf('s1').type, 'busy');
    expect(store.statusOf('s2').type, 'busy');

    // Resume refresh: /dirA fetched ok (s1 → idle), /dirB fetch FAILED.
    store.mergeStatusForTesting(
      fresh: const {'s1': SessionStatusValue('idle')},
      sessions: [
        _session(id: 's1', directory: '/dirA'),
        _session(id: 's2', directory: '/dirB'),
      ],
      fetchedDirs: {'/dirA'},
    );
    expect(store.statusOf('s1').type, 'idle', reason: 'fresh value wins');
    expect(store.statusOf('s2').type, 'busy',
        reason: 'cached pre-leave status retained for failed dir');
    store.dispose();
  });

  test('resume applies fresh status for every successfully fetched dir', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.upsertSessionForTesting(_session(id: 's2', directory: '/dirB'));
    store.onEventForTesting(_statusEvent('s1', 'busy'));
    store.onEventForTesting(_statusEvent('s2', 'busy'));

    store.mergeStatusForTesting(
      fresh: const {
        's1': SessionStatusValue('idle'),
        's2': SessionStatusValue('retry'),
      },
      sessions: [
        _session(id: 's1', directory: '/dirA'),
        _session(id: 's2', directory: '/dirB'),
      ],
      fetchedDirs: {'/dirA', '/dirB'},
    );
    expect(store.statusOf('s1').type, 'idle');
    expect(store.statusOf('s2').type, 'retry');
    store.dispose();
  });

  test('covered session absent from fresh response is idle (no stuck busy)',
      () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session(id: 's1', directory: '/dirA'));
    store.onEventForTesting(_statusEvent('s1', 'busy'));

    // Dir fetched ok but server returned no entry for s1 ⇒ it is idle now.
    store.mergeStatusForTesting(
      fresh: const {},
      sessions: [_session(id: 's1', directory: '/dirA')],
      fetchedDirs: {'/dirA'},
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
