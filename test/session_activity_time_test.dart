import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

/// Tests for session activity-time handling (design-session-activity-time.md):
/// server `time.updated` freezes at prompt-submit during a run, so the store
/// overlays SSE event times, folds `time.idle`, and never regresses on
/// reconcile/meta upserts.

const _t0 = 1790000000000;
const _t1 = _t0 + 60000;
const _t2 = _t0 + 300000;
const _t4 = _t0 + 600000;

SessionModel _session(String id,
        {int updated = _t1, int? idle, String title = 's'}) =>
    SessionModel(
      id: id,
      projectID: 'p1',
      directory: '/tmp/p1',
      title: title,
      created: _t0,
      updated: updated,
      idle: idle,
    );

OpencodeEvent _ev(String type, String sid, int? created) => OpencodeEvent(
      type: type,
      created: created,
      properties: {'sessionID': sid},
    );

void main() {
  group('activity overlay', () {
    test('usage.updated bumps and older server copy cannot regress it', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.usage.updated', 's1', _t2));
      expect(store.sessionById('s1')?.updated, _t2);
      store.upsertSessionForTesting(
          _session('s1', updated: _t0, title: 'fresh'));
      final s = store.sessionById('s1');
      expect(s?.updated, _t2);
      expect(s?.title, 'fresh');
      store.dispose();
    });

    test('time.idle folds into effective updated', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1', updated: _t1, idle: _t4));
      expect(store.sessionById('s1')?.updated, _t4);
      store.dispose();
    });

    test('mergeFetchedSessions keeps newer local and folds idle', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.usage.updated', 's1', _t2));
      store.upsertSessionForTesting(_session('s2', updated: _t0));
      final merged = store.mergeFetchedSessionsForTesting([
        _session('s1', updated: _t0, idle: _t4),
        _session('s2', updated: _t0),
      ]);
      final byId = {for (final s in merged) s.id: s};
      expect(byId['s1']?.updated, _t4);
      expect(byId['s2']?.updated, _t0);
      store.dispose();
    });

    test('mergeFetchedSessions prefers local bump over stale idle', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.usage.updated', 's1', _t2));
      final merged = store.mergeFetchedSessionsForTesting(
          [_session('s1', updated: _t0, idle: _t1)]);
      expect(merged.single.updated, _t2);
      store.dispose();
    });

    test('step lifecycle events touch activity monotonically', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.step.started', 's1', _t1));
      expect(store.sessionById('s1')?.updated, _t1);
      store.onEventForTesting(_ev('session.step.streamed', 's1', _t0));
      expect(store.sessionById('s1')?.updated, _t1);
      store.onEventForTesting(
          _ev('session.step.ended', 's1', _t2));
      expect(store.sessionById('s1')?.updated, _t2);
      store.onEventForTesting(_ev('session.execution.succeeded', 's1', _t4));
      expect(store.sessionById('s1')?.updated, _t4);
      store.dispose();
    });

    test('text delta touch is throttled by interval since last value', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.text.delta', 's1', _t1));
      expect(store.sessionById('s1')?.updated, _t0 + 60000);
      store.onEventForTesting(
          _ev('session.text.delta', 's1', _t1 + 100));
      expect(store.sessionById('s1')?.updated, _t1);
      store.onEventForTesting(
          _ev('session.text.delta', 's1', _t1 + 5000));
      expect(store.sessionById('s1')?.updated, _t1 + 5000);
      store.dispose();
    });

    test('events without created never regress activity', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(_ev('session.usage.updated', 's1', _t2));
      store.onEventForTesting(_ev('session.step.started', 's1', null));
      store.onEventForTesting(_ev('session.text.delta', 's1', null));
      expect(store.sessionById('s1')?.updated, _t2);
      store.dispose();
    });

    test('busy probe corrects from newest message time', () async {
      final client = _ProbeClient(latestAt: {'s1': _t4});
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      store.upsertSessionForTesting(_session('s2'));
      store.onEventForTesting(_ev('session.execution.started', 's1', _t1));
      await store.probeBusyMessageTimesForTesting();
      expect(store.sessionById('s1')?.updated, _t4);
      expect(store.sessionById('s2')?.updated, _t1);
      expect(client.probed, ['s1']);
      store.dispose();
    });

    test('inbox.enqueued touches activity', () {
      final store = ServerStore()..client = _ProbeClient();
      store.upsertSessionForTesting(_session('s1'));
      store.onEventForTesting(OpencodeEvent(
        type: 'session.inbox.enqueued',
        created: _t2,
        properties: {
          'sessionID': 's1',
          'inboxID': 'i1',
          'item': {'type': 'user', 'payload': {'text': 'hi'}},
        },
      ));
      expect(store.sessionById('s1')?.updated, _t2);
      store.dispose();
    });
  });
}

class _ProbeClient extends OpencodeClient {
  final Map<String, int> latestAt;
  final List<String> probed = [];

  _ProbeClient({this.latestAt = const {}})
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<int?> latestMessageAt(String sessionId) async {
    probed.add(sessionId);
    return latestAt[sessionId];
  }

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    return const MessagesPage([], null, null);
  }
}
