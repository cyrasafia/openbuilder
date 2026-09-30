import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

import 'v2_test_fixtures.dart';

OpencodeClient _gateFakeClient() => OpencodeClient(Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    )));

SessionModel _session(String id,
    {int updated = 1000, int? idle, String dir = '/w'}) {
  return SessionModel(
    id: id,
    projectID: 'p1',
    directory: dir,
    title: 't-$id',
    created: 900,
    updated: updated,
    idle: idle,
  );
}

void main() {
  group('diffStage', () {
    test('max(updated, idle) > watermark marks stale; equal clears', () {
      final store = ServerStore();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: true);
      store.diffStaleForTesting([_session('s1', updated: 1000)],
          full: true);
      expect(store.isSessionStale('s1'), isFalse);
      store.diffStaleForTesting([
        _session('s1', updated: 1000, idle: 1200)
      ], full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.diffStaleForTesting([_session('s1', updated: 1300)], full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.dispose();
    });

    test('run-completed detection via idle jump (v2 core regression)', () {
      final store = ServerStore();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: true);
      store.diffStaleForTesting([
        _session('s1', updated: 1000, idle: 1100)
      ], full: true);
      expect(store.isSessionStale('s1'), isTrue,
          reason: 'idle 跳变 = run 完成，updated 不动也必须检出');
      store.dispose();
    });

    test('marking a new stale episode drops live preview marker (SG-R1)',
        () {
      final store = ServerStore();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: true);
      store.diffStaleForTesting([_session('s1', updated: 1200)],
          full: true);
      expect(store.hasLivePreview('s1'), isFalse);
      store.dispose();
    });

    test('busy-no-clear: busy session stale is not cleared by diff (GL-3)',
        () {
      final store = ServerStore();
      store.onContentSyncedForTesting('s1', 1500, fromReconcile: true);
      store.mergeStatusForTesting(
        fresh: {'s1': const SessionStatusValue('busy')},
        sessions: [_session('s1', updated: 1000)],
      );
      store.consumeEpochForTesting();
      store.bumpSseEpochForTesting(); // epoch 翻转标 busy → stale
      expect(store.isSessionStale('s1'), isTrue);
      // 断连期周期 diff：fresh(1000) <= wm(1500)，但 busy → 不清
      store.diffStaleForTesting([_session('s1', updated: 1000)],
          full: true, busySids: {'s1'});
      expect(store.isSessionStale('s1'), isTrue,
          reason: 'busy 的 stale 只能由 reconcile 成功清（窄元数据冻结不足以证明无内容变化）');
      // 对照：非 busy → 清
      store.diffStaleForTesting([_session('s1', updated: 1000)],
          full: true);
      expect(store.isSessionStale('s1'), isFalse);
      store.dispose();
    });

    test('non-busy session stale is cleared by diff when fresh <= wm', () {
      final store = ServerStore();
      store.diffStaleForTesting([_session('s1', updated: 1500)],
          full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.onContentSyncedForTesting('s1', 1600, fromReconcile: true);
      store.diffStaleForTesting([_session('s1', updated: 1500)],
          full: true);
      expect(store.isSessionStale('s1'), isFalse);
      store.dispose();
    });

    test('full diff removes stale of vanished sessions (V11)', () {
      final store = ServerStore();
      store.diffStaleForTesting([_session('s1', updated: 2000)],
          full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.diffStaleForTesting([_session('s2', updated: 100)], full: true);
      expect(store.isSessionStale('s1'), isFalse);
      store.dispose();
    });

    test('full diff drops watermark/live markers of vanished sessions (RV-3)',
        () {
      final store = ServerStore();
      store.onContentSyncedForTesting('s1', 1500, fromReconcile: true);
      store.diffStaleForTesting([_session('s1', updated: 1500)], full: true);
      expect(store.watermarkOf('s1'), 1500);
      // s1 消失（归档/删除/超上限）→ full diff 兜底清理
      store.diffStaleForTesting([_session('s2', updated: 100)], full: true);
      expect(store.watermarkOf('s1'), isNull);
      expect(store.hasLivePreview('s1'), isFalse);
      store.dispose();
    });

    test('full diff keeps watermarks of active child sessions (RV-3)', () {
      final store = ServerStore();
      store.diffStaleForTesting([_session('s1', updated: 1500)], full: true);
      store.upsertSessionForTesting(SessionModel(
        id: 'child1',
        projectID: 'p1',
        directory: '/w',
        title: 'child',
        created: 900,
        updated: 950,
        parentID: 's1',
      ));
      store.onContentSyncedForTesting('child1', 900, fromReconcile: true);
      store.diffStaleForTesting([_session('s1', updated: 1500)], full: true);
      expect(store.watermarkOf('child1'), 900,
          reason: '活跃 child 不在 fresh 列表但不应被清理');
      store.dispose();
    });

    test('single-query diff (full:false) keeps other sessions stale (TR-1)',
        () {
      final store = ServerStore();
      store.diffStaleForTesting([
        _session('a', updated: 2000, dir: '/d1'),
        _session('b', updated: 2000, dir: '/d2'),
      ], full: true);
      expect(store.isSessionStale('a'), isTrue);
      expect(store.isSessionStale('b'), isTrue);
      store.diffStaleForTesting([_session('a', updated: 900, dir: '/d1')]);
      expect(store.isSessionStale('b'), isTrue,
          reason: '单查不清其他 directory 的 stale 位');
      store.dispose();
    });
  });

  group('watermark advancement guards', () {
    test('SSE entry advances wm only when epoch consumed and not stale (SG-R1)',
        () {
      final store = ServerStore();
      // epoch not consumed: frozen
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: false);
      expect(store.watermarkOf('s1'), isNull);
      store.consumeEpochForTesting();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: false);
      expect(store.watermarkOf('s1'), 1000);
      // stale session: frozen
      store.diffStaleForTesting([_session('s1', updated: 2000)],
          full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.onContentSyncedForTesting('s1', 3000, fromReconcile: false);
      expect(store.watermarkOf('s1'), 1000,
          reason: 'stale（缺口）期间 SSE 推进被冻结');
      // reconcile clears and advances
      store.onContentSyncedForTesting('s1', 3000, fromReconcile: true);
      expect(store.watermarkOf('s1'), 3000);
      expect(store.isSessionStale('s1'), isFalse);
      store.dispose();
    });

    test('pause-gap: epoch bump freezes SSE advancement (六轮 #1)', () {
      final store = ServerStore();
      store.consumeEpochForTesting();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: false);
      expect(store.watermarkOf('s1'), 1000);
      store.bumpSseEpochForTesting(); // _stopSse / reconnecting
      store.onContentSyncedForTesting('s1', 1100, fromReconcile: false);
      expect(store.watermarkOf('s1'), 1000,
          reason: 'pause 拆流无 reconnecting 事件，靠 _stopSse 翻纪元');
      store.dispose();
    });

    test('reconcile clears stale unconditionally; advances only >cur (DG-3)',
        () {
      final store = ServerStore();
      store.diffStaleForTesting([_session('s1', updated: 2000)],
          full: true);
      expect(store.isSessionStale('s1'), isTrue);
      store.onContentSyncedForTesting('s1', 0, fromReconcile: true);
      expect(store.isSessionStale('s1'), isFalse,
          reason: '目标不可得也清 stale（拉取本身即内容证据）');
      expect(store.watermarkOf('s1'), isNull);
      store.dispose();
    });
  });

  group('event-entry choke point (v2)', () {
    test('session.* events with created advance wm through _onGlobalEvent',
        () {
      final store = ServerStore();
      store.upsertSessionForTesting(_session('s1'));
      store.consumeEpochForTesting();
      store.onGlobalEventForTesting(
        '/w',
        const OpencodeEvent(
          type: 'session.text.delta',
          created: 1234,
          properties: {'sessionID': 's1'},
        ),
      );
      expect(store.watermarkOf('s1'), 1234);
      store.dispose();
    });
  });

  group('epoch busy marking (GL-2b)', () {
    test('epoch bump marks busy/retry sessions stale', () {
      final store = ServerStore();
      store.upsertSessionForTesting(_session('s1'));
      store.mergeStatusForTesting(
        fresh: {'s1': const SessionStatusValue('busy')},
        sessions: [_session('s1')],
      );
      store.consumeEpochForTesting();
      store.onContentSyncedForTesting('s1', 1000, fromReconcile: true);
      store.bumpSseEpochForTesting();
      expect(store.isSessionStale('s1'), isTrue,
          reason: 'run 进行中断连：busy 会话保守标 stale（run 中缺口主信号）');
      store.dispose();
    });
  });

  group('gate (GL-1)', () {
    test('reveal watermark filter hides gap content, keeps live tail + cache',
        () {
      final conv = ConversationStore('s1', fakeClientForGate());
      conv.isSessionStaleSession = (_) => true;
      _seedMsg(conv, 'cache1', created: 100, text: 'old');
      conv.beginGateForTest();
      expect(conv.gated, isTrue);
      expect(conv.revealWatermarkForTest, 100);
      // live tail arrival is revealed immediately (GL-1)
      _seedMsg(conv, 'live1', created: 500, text: 'tail');
      expect(conv.renderableMessages.map((m) => m.id), contains('live1'));
      // REST 竞态窗内容（created > 展示水位）保持隐藏到 endGate 同帧揭示——
      // 真实路径中它只经 reconcile._upsertEntries 进入，随后 _endGate 先于
      // notify 同步执行，无中间帧；此处用直插模拟该隐藏面。
      _seedMsgHidden(conv, 'race1', created: 600, text: 'race');
      expect(conv.renderableMessages.map((m) => m.id),
          isNot(contains('race1')),
          reason: '对账竞态窗内容（未被 SSE 交付）保持隐藏');
      conv.endGateForTest();
      expect(conv.renderableMessages.map((m) => m.id), contains('race1'));
      conv.dispose();
    });

    test('optimistic messages are exempt from the reveal filter (V10)', () {
      final conv = ConversationStore('s1', fakeClientForGate());
      conv.isSessionStaleSession = (_) => true;
      _seedMsg(conv, 'cache1', created: 100, text: 'old');
      conv.beginGateForTest();
      conv.addOptimisticUserMessage('hello');
      expect(conv.renderableMessages.any((m) => m.optimistic), isTrue);
      conv.dispose();
    });

    test('_lastKnownCreated skips optimistic timestamps (SG-R2)', () {
      final conv = ConversationStore('s1', fakeClientForGate());
      conv.isSessionStaleSession = (_) => true;
      _seedMsg(conv, 'cache1', created: 100, text: 'old');
      conv.addOptimisticUserMessage('huge client clock');
      conv.beginGateForTest();
      expect(conv.revealWatermarkForTest, 100,
          reason: 'optimistic 的客户端时钟不抬揭示水位');
      conv.dispose();
    });
  });

  group('merge loader (SG-5/TR-4/SG-R3)', () {
    test('gate merge load keeps SSE accumulation and does not set loaded',
        () async {
      final conv = ConversationStore('s1', fakeClientForGate());
      conv.isSessionStaleSession = (_) => true;
      _seedMsg(conv, 'sse1', created: 500, text: 'tail');
      conv.beginGateForTest();
      await conv.loadCacheForGateForTest();
      expect(conv.messages.isEmpty, isFalse);
      expect(conv.renderableMessages.any((m) => m.id == 'sse1'), isTrue);
      conv.dispose();
    });
  });

  group('terminal reconcile failure (RV-1)', () {
    test('page-too-large ends the gate and clears session stale', () async {
      final store = ServerStore();
      final conv = ConversationStore('s1', _ThrowingClient());
      store.injectConversationForTesting('s1', conv);
      store.diffStaleForTesting([_session('s1', updated: 2000)],
          full: true);
      expect(store.isSessionStale('s1'), isTrue);
      conv.isSessionStaleSession = (_) => true;
      conv.onContentSynced = store.onContentSyncedForTesting;
      conv.seedSyncedUpdated(0);
      conv.beginGateForTest();
      expect(conv.gated, isTrue);
      await conv.reconcile();
      expect(conv.gated, isFalse,
          reason: '页面超限是终态，门控必须结束（否则「获取新消息中」永久驻留）');
      expect(store.isSessionStale('s1'), isFalse,
          reason: '终态失败清会话级 stale，防 listener 反复重触发');
      expect(store.watermarkOf('s1'), isNull,
          reason: '拉取未成功，不得推进水位');
      conv.dispose();
      store.dispose();
    });
  });
}

class _ThrowingClient extends OpencodeClient {
  _ThrowingClient()
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPageCompute(String sessionId,
          {required int limit, String? cursor}) async =>
      throw const MessagePageTooLargeException(
          size: 1, limit: 0, sessionId: 's1');

  @override
  Future<MessagesPage> messagesPage(String sessionId,
          {required int limit, String? cursor}) async =>
      throw const MessagePageTooLargeException(
          size: 1, limit: 0, sessionId: 's1');
}

OpencodeClient fakeClientForGate() => _gateFakeClient();

void _seedMsg(ConversationStore conv, String id,
    {required int created, required String text}) {
  final sm = userMsg(id: id, text: text, created: created);
  conv.onUserMessageArrived(sm);
}

void _seedMsgHidden(ConversationStore conv, String id,
    {required int created, required String text}) {
  final sm = userMsg(id: id, text: text, created: created);
  // Direct insertion without going through the reveal hook: simulates gap
  // content arriving from a source that does not trigger revealLiveMessage.
  conv.debugInsertForTest(sm);
}
