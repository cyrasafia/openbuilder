import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

class _BackfillMockClient extends OpencodeClient {
  final Future<List<Permission>> Function(String directory)? permissionsHandler;
  final Future<List<QuestionRequest>> Function(String? directory)?
      questionsHandler;
  final void Function(String directory)? onPermissionFetch;
  _BackfillMockClient(
      {this.permissionsHandler, this.questionsHandler, this.onPermissionFetch})
      : super(_noopDio());

  @override
  Future<List<Permission>> pendingPermissions(String directory) async {
    onPermissionFetch?.call(directory);
    return await (permissionsHandler?.call(directory) ??
        Future.value(const <Permission>[]));
  }

  @override
  Future<List<QuestionRequest>> listQuestions({String? directory}) async =>
      await (questionsHandler?.call(directory) ??
          Future.value(const <QuestionRequest>[]));
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

SessionModel _session(String id, {String dir = '/d'}) => SessionModel(
    id: id,
    projectID: 'p',
    directory: dir,
    title: 't',
    created: 0,
    updated: 0);

void _askPermission(ServerStore store, Permission p) =>
    store.onEventForTesting(OpencodeEvent(
      type: 'permission.asked',
      properties: {'id': p.id, 'sessionID': p.sessionID, 'permission': p.type},
    ));

void _replyPermission(ServerStore store, String sid, String pid) =>
    store.onEventForTesting(OpencodeEvent(
      type: 'permission.replied',
      properties: {'sessionID': sid, 'requestID': pid},
    ));

void _askQuestion(ServerStore store, QuestionRequest q) =>
    store.onEventForTesting(OpencodeEvent(
      type: 'question.asked',
      properties: {'id': q.id, 'sessionID': q.sessionID, 'questions': const []},
    ));

void _replyQuestion(ServerStore store, String sid, String qid) =>
    store.onEventForTesting(OpencodeEvent(
      type: 'question.replied',
      properties: {'sessionID': sid, 'requestID': qid},
    ));

void main() {
  group('backfill atomic swap (no half-cleared snapshot)', () {
    // 回归：旧实现先 clear 再逐目录 REST 回填，窗口内任何 notify（如
    // refreshListAndWorkingSse 紧跟的 notifyListeners / SSE 心跳）会把
    // 空 pending 画出来 → 指示器在「需要授权」和「运行中」之间闪烁。
    test('pending permission stays visible while backfill is in flight',
        () async {
      final perm = Permission(id: 'per_1', type: 'bash', sessionID: 's1');
      late ServerStore store;
      var observedEmptyDuringWindow = false;
      final client = _BackfillMockClient(
        permissionsHandler: (_) async => [perm],
        onPermissionFetch: (_) {
          if (!store.hasPendingPermission('s1')) observedEmptyDuringWindow = true;
        },
      );
      store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      _askPermission(store, perm);
      expect(store.hasPendingPermission('s1'), isTrue);
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.paused);

      await store.backfillPermissionsForTesting();
      expect(observedEmptyDuringWindow, isFalse,
          reason: 'live map must not be cleared while REST fetches are pending');
      expect(store.hasPendingPermission('s1'), isTrue);
      expect(store.agentIndicatorStateOf('s1').state, AgentRunState.paused);
    });

    test('permission asked during backfill window survives the swap',
        () async {
      final p1 = Permission(id: 'per_1', type: 'bash', sessionID: 's1');
      final p2 = Permission(id: 'per_2', type: 'bash', sessionID: 's2');
      late ServerStore store;
      var fired = false;
      final client = _BackfillMockClient(
        permissionsHandler: (_) async => [p1],
        onPermissionFetch: (_) {
          if (fired) return;
          fired = true;
          _askPermission(store, p2);
        },
      );
      store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      store.upsertSessionForTesting(_session('s2'));
      _askPermission(store, p1);

      await store.backfillPermissionsForTesting();
      expect(store.hasPendingPermission('s1'), isTrue);
      expect(store.hasPendingPermission('s2'), isTrue,
          reason: 'SSE arrival during the window is newer than the snapshot');
    });

    test('permission replied during backfill window is not resurrected',
        () async {
      final p1 = Permission(id: 'per_1', type: 'bash', sessionID: 's1');
      late ServerStore store;
      var fired = false;
      final client = _BackfillMockClient(
        permissionsHandler: (_) async => [p1],
        onPermissionFetch: (_) {
          if (fired) return;
          fired = true;
          _replyPermission(store, 's1', p1.id);
        },
      );
      store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      _askPermission(store, p1);

      await store.backfillPermissionsForTesting();
      expect(store.hasPendingPermission('s1'), isFalse,
          reason: 'stale REST snapshot must not revive a replied permission');
    });

    // 评审 #1：窗口内到达、REST echo 先入 next、随后才 resolve 的卡，
    // prev/live 都看不到它 —— 只能靠 swap 前重查 _recentlyResolved 守卫。
    test('permission resolved after REST echo but before swap is dropped',
        () async {
      final p2 = Permission(id: 'per_2', type: 'bash', sessionID: 's2');
      late ServerStore store;
      final client = _BackfillMockClient(
        permissionsHandler: (dir) async => dir == '/d1' ? [p2] : const [],
        onPermissionFetch: (dir) {
          if (dir != '/d2') return;
          final conv = store.ensureConversation('s2')!;
          conv.onPermissionResolved!(p2.id);
        },
      );
      store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1', dir: '/d1'));
      store.upsertSessionForTesting(_session('s2', dir: '/d2'));

      await store.backfillPermissionsForTesting();
      expect(store.hasPendingPermission('s2'), isFalse,
          reason: 'asked+resolved entirely inside the window must stay gone');
    });

    // 评审 #2：跨端回复只走 SSE replied，不经过本地 ConversationStore
    // 回复路径 —— SSE handler 也必须登记 resolved 守卫，否则下一次
    // backfill 的陈旧快照会把已回复的卡复活。
    test('SSE permission.replied registers the resolved guard', () async {
      final p1 = Permission(id: 'per_1', type: 'bash', sessionID: 's1');
      final client = _BackfillMockClient(
        permissionsHandler: (_) async => [p1],
      );
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      _askPermission(store, p1);
      _replyPermission(store, 's1', p1.id);
      expect(store.hasPendingPermission('s1'), isFalse);

      await store.backfillPermissionsForTesting();
      expect(store.hasPendingPermission('s1'), isFalse,
          reason: 'cross-client reply must not be resurrected by backfill');
    });

    test('SSE question.replied registers the resolved guard', () async {
      final q1 = QuestionRequest(
          id: 'que_1', sessionID: 's1', questions: const []);
      final client = _BackfillMockClient(
        questionsHandler: (_) async => [q1],
      );
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));
      _askQuestion(store, q1);
      _replyQuestion(store, 's1', q1.id);
      expect(store.hasPendingQuestion('s1'), isFalse);

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isFalse,
          reason: 'cross-client reply must not be resurrected by backfill');
    });

    // 评审 #3：connect 与 reconcile（及两 Tab 周期刷新）可能重叠触发
    // backfill —— in-flight 守卫去重（不并发），尾随触发合并为完成后
    // 恰好一次补跑，旧的慢速快照不得覆盖新结果、迟到触发不得丢弃。
    test('overlapping backfills coalesce to one re-run', () async {
      final gate = Completer<List<Permission>>();
      var fetches = 0;
      final client = _BackfillMockClient(
        permissionsHandler: (_) {
          fetches++;
          return gate.future;
        },
      );
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(_session('s1'));

      final f1 = store.backfillPermissionsForTesting();
      final f2 = store.backfillPermissionsForTesting();
      await f2;
      expect(fetches, 1, reason: 'second run must not run concurrently');

      gate.complete(const []);
      await f1;
      await Future<void>.delayed(Duration.zero);
      expect(fetches, 2,
          reason: 'trailing trigger re-runs exactly once after completion');
    });
  });
}
