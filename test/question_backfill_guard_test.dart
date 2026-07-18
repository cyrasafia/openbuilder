import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

class _QuestionsMockClient extends OpencodeClient {
  List<QuestionRequest> questions;
  _QuestionsMockClient({this.questions = const []}) : super(_noopDio());

  @override
  Future<List<QuestionRequest>> listQuestions({String? directory}) async =>
      questions;
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

void main() {
  // I-1 覆盖：_recentlyResolvedQuestions 守卫让 backfill 跳过近期已解决的卡，
  // 防止服务端列表清理延迟窗口内的「提交后又弹回」。
  group('question backfill guard (_recentlyResolved)', () {
    test('resolved question is skipped on subsequent backfill', () async {
      final q1 = QuestionRequest(
          id: 'que_g1', sessionID: 's1', questions: const []);
      final client = _QuestionsMockClient(questions: [q1]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(const SessionModel(
        id: 's1',
        projectID: 'p',
        directory: '/d',
        title: 't',
        created: 0,
        updated: 0,
      ));

      // 首次 backfill：q1 注入 pending。
      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isTrue);

      // 模拟 reply 成功：ConversationStore 会调 onQuestionResolved 回调，
      // 触发 ServerStore._markQuestionResolved 登记 _recentlyResolvedQuestions
      // 并从 _pendingQuestions 移除。
      final conv = store.ensureConversation('s1')!;
      expect(conv.onQuestionResolved, isNotNull);
      conv.onQuestionResolved!('que_g1');
      expect(store.hasPendingQuestion('s1'), isFalse);

      // 再次 backfill：mock 仍返回 [q1]（模拟服务端列表尚未清理），但守卫
      // 跳过 → 不重新注入。无守卫时这里会变 true（即原 bug 的「弹回」）。
      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isFalse);
    });

    test('guard expires after TTL, re-surfaces if still pending server-side',
        () async {
      final q1 = QuestionRequest(
          id: 'que_g2', sessionID: 's2', questions: const []);
      final client = _QuestionsMockClient(questions: [q1]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(const SessionModel(
        id: 's2',
        projectID: 'p',
        directory: '/d',
        title: 't',
        created: 0,
        updated: 0,
      ));

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s2'), isTrue);

      final conv = store.ensureConversation('s2')!;
      conv.onQuestionResolved!('que_g2');
      expect(store.hasPendingQuestion('s2'), isFalse);

      // 模拟 TTL 过期：守卫清空后，若服务端仍返回该卡（说明真没解决），
      // backfill 会重新放出（关键设计决策 4）。
      store.expireRecentlyResolvedForTesting();
      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s2'), isTrue);
    });
  });
}
