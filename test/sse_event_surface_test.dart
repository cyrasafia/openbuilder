import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// design/v2/design-sse-event-surface.md GAP-1..4 回归：
//  GAP-1 `session.inbox.cancelled` 按 inboxID 精确移除物化的排队消息；
//  GAP-2 `session.revert.committed` 按 `to` 边界确定性清除（乐观/synthetic/
//        非 msg_ id/新轮次时间戳排除）；
//  GAP-3 `config.updated` / `models-dev.refreshed` 触发命令缓存失效；
//  GAP-4 `vcs.branch.updated` 触发对账（reconcile）。

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

void _enqueueUser(ConversationStore conv, String id, int created) {
  conv.onInboxEnqueued(id,
      {'type': 'user', 'payload': {'text': 'queued $id'}},
      created: created);
}

class _EvtCmdClient extends OpencodeClient {
  _EvtCmdClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  int calls = 0;
  @override
  Future<List<CommandInfo>> getMergedCommands({String? directory}) async {
    calls++;
    return const [CommandInfo(name: 'review', description: 'code review')];
  }
}

/// 模拟 projector 批删未落地：reload 响应仍带回边界后的旧消息。
class _GhostReloadClient extends OpencodeClient {
  _GhostReloadClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    return MessagesPage([
      UserMessage(
          id: 'msg_5',
          raw: const {},
          created: 200,
          text: 'ghost that projector has not deleted yet'),
      UserMessage(
          id: 'msg_6', raw: const {}, created: 300, text: 'ghost tail'),
    ], null, null);
  }
}

void main() {
  group('GAP-1 inbox.cancelled', () {
    test('removes the materialized inbox message by inboxID', () {
      final conv = ConversationStore('s', _fakeClient());
      _enqueueUser(conv, 'msg_1', 10);
      expect(conv.renderableMessages, hasLength(1));
      expect(conv.removeInboxMessage('msg_1'), isTrue);
      expect(conv.renderableMessages, isEmpty);
      expect(conv.removeInboxMessage('msg_1'), isFalse,
          reason: 'second cancel is a no-op');
      conv.dispose();
    });

    test('dispatch removes the queued bubble and leaves optimistic alone', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_session('s1'));
      final conv = ConversationStore('s1', _fakeClient());
      store.injectConversationForTesting('s1', conv);
      _enqueueUser(conv, 'msg_9', 10);
      conv.addOptimisticUserMessage('draft');
      expect(conv.renderableMessages, hasLength(2));

      store.onEventForTesting(const OpencodeEvent(
        type: 'session.inbox.cancelled',
        properties: {'sessionID': 's1', 'inboxID': 'msg_9'},
      ));

      final left = conv.renderableMessages;
      expect(left, hasLength(1));
      expect(left.single.optimistic, isTrue,
          reason: 'optimistic bubble is not an inbox item');
      conv.dispose();
      store.dispose();
    });

    test('dispatch for an unknown inboxID is a no-op', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_session('s1'));
      final conv = ConversationStore('s1', _fakeClient());
      store.injectConversationForTesting('s1', conv);
      _enqueueUser(conv, 'msg_1', 10);

      store.onEventForTesting(const OpencodeEvent(
        type: 'session.inbox.cancelled',
        properties: {'sessionID': 's1', 'inboxID': 'msg_404'},
      ));
      expect(conv.renderableMessages, hasLength(1));
      conv.dispose();
      store.dispose();
    });
  });

  group('GAP-2 revert.committed deterministic clear', () {
    test('clears id >= to with created < eventTime; keeps the rest', () {
      final conv = ConversationStore('s', _fakeClient());
      _enqueueUser(conv, 'msg_3', 100);
      _enqueueUser(conv, 'msg_5', 200);
      _enqueueUser(conv, 'msg_6', 300);
      _enqueueUser(conv, 'msg_8', 2000);
      conv.onSynthetic(SyntheticMessage(
        id: 'msg_7',
        raw: const {'id': 'msg_7', 'type': 'synthetic'},
        created: 250,
        text: 'subagent done',
      ));
      conv.addOptimisticUserMessage('draft');

      final removed = conv.onRevertCommitted('msg_5', 1500);
      expect(removed, 2, reason: 'msg_5 (inclusive boundary) and msg_6');

      final ids = conv.renderableMessages.map((m) => m.id).toSet();
      expect(ids.contains('msg_3'), isTrue, reason: 'older than the boundary');
      expect(ids.contains('msg_5'), isFalse);
      expect(ids.contains('msg_6'), isFalse);
      expect(ids.contains('msg_7'), isTrue,
          reason: 'synthetic forged ids are outside the comparable space');
      expect(ids.contains('msg_8'), isTrue,
          reason: 'new round arrived after the commit event');
      expect(ids.any((id) => id.startsWith('optimistic_')), isTrue);
      conv.dispose();
    });

    test('optimistic_ ids sort after msg_ and must survive a late eventTime',
        () {
      final conv = ConversationStore('s', _fakeClient());
      _enqueueUser(conv, 'msg_5', 200);
      conv.addOptimisticUserMessage('draft');
      final removed = conv.onRevertCommitted('msg_5', 99999999999999);
      expect(removed, 1);
      final left = conv.renderableMessages;
      expect(left, hasLength(1));
      expect(left.single.optimistic, isTrue,
          reason: "lexicographically 'optimistic_' > 'msg_' — the clear must "
              'not rely on id comparison alone');
      conv.dispose();
    });

    test('skips the clear when to or eventTime is missing or malformed', () {
      final conv = ConversationStore('s', _fakeClient());
      _enqueueUser(conv, 'msg_5', 200);
      expect(conv.onRevertCommitted(null, 1000), 0);
      expect(conv.onRevertCommitted('msg_5', null), 0);
      expect(conv.onRevertCommitted('', 1000), 0);
      expect(conv.onRevertCommitted('boundary_x', 1000), 0,
          reason: 'non-msg_ boundary is not comparable');
      expect(conv.renderableMessages, hasLength(1));
      conv.dispose();
    });

    test('dispatch clears locally before the reload converges', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_session('s1'));
      final conv = ConversationStore('s1', _fakeClient());
      store.injectConversationForTesting('s1', conv);
      _enqueueUser(conv, 'msg_5', 200);
      _enqueueUser(conv, 'msg_6', 300);

      store.onEventForTesting(OpencodeEvent(
        type: 'session.revert.committed',
        properties: {'sessionID': 's1', 'to': 'msg_5'},
        created: 99999999999999,
      ));

      expect(conv.renderableMessages, isEmpty,
          reason: 'clear is synchronous; reload is the follow-up');
      conv.dispose();
      store.dispose();
    });

    test('a lagging reload that re-adds ghosts is re-cleared afterwards',
        () async {
      final store = ServerStore()..client = _GhostReloadClient();
      store.upsertSessionForTesting(_session('s1'));
      final conv = ConversationStore('s1', _GhostReloadClient());
      store.injectConversationForTesting('s1', conv);
      _enqueueUser(conv, 'msg_5', 200);
      _enqueueUser(conv, 'msg_6', 300);

      store.onEventForTesting(OpencodeEvent(
        type: 'session.revert.committed',
        properties: {'sessionID': 's1', 'to': 'msg_5'},
        created: 99999999999999,
      ));

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      bool reAdded = false, settled = false;
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 5));
        final ids = conv.renderableMessages.map((m) => m.id).toSet();
        if (ids.contains('msg_5')) reAdded = true;
        if (!ids.contains('msg_5') && !ids.contains('msg_6')) {
          settled = true;
          break;
        }
      }
      expect(reAdded || settled, isTrue,
          reason: 'reload must have completed (ghosts re-added or absent)');
      expect(conv.renderableMessages.map((m) => m.id), isEmpty,
          reason: 'idempotent second clear must close the projector-lag window');
      conv.dispose();
      store.dispose();
    });
  });

  group('GAP-3 command cache invalidation triggers', () {
    test('config.updated and models-dev.refreshed refresh commands', () async {
      final client = _EvtCmdClient();
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      store.setActiveConversation('s1');

      Future<void> until(int calls) async {
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (client.calls < calls && DateTime.now().isBefore(deadline)) {
          await Future.delayed(const Duration(milliseconds: 5));
        }
      }

      store.onEventForTesting(
          const OpencodeEvent(type: 'config.updated', properties: {}));
      await until(1);
      expect(client.calls, 1, reason: 'config.updated must refresh commands');

      store.onEventForTesting(
          const OpencodeEvent(type: 'models-dev.refreshed', properties: {}));
      await until(2);
      expect(client.calls, 2,
          reason: 'models-dev.refreshed must refresh commands too '
              '(sequenced: the in-flight dedup coalesces simultaneous hits)');
      store.dispose();
    });
  });

  group('GAP-4 vcs.branch.updated', () {
    test('schedules a reconcile instead of silent drop', () {
      final store = ServerStore()..client = _fakeClient();
      expect(store.reconcileScheduleCountForTesting, 0);
      store.onEventForTesting(
          const OpencodeEvent(type: 'vcs.branch.updated', properties: {}));
      expect(store.reconcileScheduleCountForTesting, 1);
      store.dispose();
    });
  });
}
