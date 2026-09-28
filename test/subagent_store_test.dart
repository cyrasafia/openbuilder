import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// design-subagent-status §D3 的 store 层约定：
// - SSE session.created 的子会话（parentID 非空）进 `_childSessions`，
//   不进可见 `_sessions`
// - findChildSession：parentID 匹配 + title 前缀消歧 + created 最新优先
// - ensureConversation / LRU 驱逐对子会话豁免
// - DisplayPart.toolMetadata 全链路保留（SSE onPartUpdated / REST 合并）

OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

SessionModel _parent(String id) => SessionModel(
      id: id,
      projectID: 'p',
      directory: '/repo',
      title: 'main',
      created: 1,
      updated: 1,
    );

SessionModel _child(String id, String parentID,
    {required int created, required String title}) {
  return SessionModel(
    id: id,
    projectID: 'p',
    directory: '/repo',
    title: title,
    created: created,
    updated: created,
    parentID: parentID,
  );
}

void main() {
  group('child session registry (_childSessions)', () {
    test('SSE upsert keeps child sessions out of visible _sessions',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task: explore lib'));

      expect(store.sessionById('kid'), isNull,
          reason: 'child session must not appear in the visible list');
      expect(store.sessionById('par'), isNotNull);
      expect(store.findChildSession('par')?.id, 'kid');
    });

    test('session.deleted removes the child session registry entry',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      store.onEventForTesting(OpencodeEvent(
        type: 'session.deleted',
        properties: {'info': {'id': 'kid'}},
      ));
      expect(store.findChildSession('par'), isNull);
    });

    test('archived transition drops the registry entry', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      // Archive flips archived != null while parentID stays (defensive: some
      // server versions emit both).
      store.upsertSessionForTesting(SessionModel(
        id: 'kid',
        projectID: 'p',
        directory: '/repo',
        title: 'task',
        created: 5,
        updated: 5,
        parentID: 'par',
        archived: 9,
      ));
      expect(store.findChildSession('par'), isNull);
    });
  });

  group('findChildSession heuristic (§D3 degraded path)', () {
    test('prefers title-prefix match over newest-created', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('newer', 'par', created: 9, title: 'something else'));
      store.upsertSessionForTesting(
          _child('matched', 'par', created: 5, title: 'write the docs'));

      final hit =
          store.findChildSession('par', description: 'write the');
      expect(hit?.id, 'matched',
          reason: 'prefix match must beat newer non-matching sibling');
    });

    test('prefix ties fall back to newest created', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('older', 'par', created: 1, title: 'write docs'));
      store.upsertSessionForTesting(
          _child('newer', 'par', created: 2, title: 'write docs v2'));

      final hit = store.findChildSession('par', description: 'write');
      expect(hit?.id, 'newer');
    });

    test('no description match → newest child of that parent', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(_parent('other'));
      store.upsertSessionForTesting(
          _child('old', 'par', created: 1, title: 'zzz'));
      store.upsertSessionForTesting(
          _child('kid', 'other', created: 9, title: 'other task'));

      expect(store.findChildSession('par')?.id, 'old',
          reason: 'must not leak another parent\'s child');
    });

    test('unknown parent → null (no cross-parent leak)', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      expect(store.findChildSession('nobody'), isNull);
    });

    test('registry caps at 64 by arrival order', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      for (var i = 0; i < 70; i++) {
        store.upsertSessionForTesting(
            _child('kid$i', 'par', created: i + 1, title: 't${'$i'.padLeft(2, '0')}'));
      }
      expect(store.findChildSession('par')?.id, 'kid69',
          reason: 'newest kept after eviction');
      // kid0 (t00) was evicted by the 64 cap → prefix miss falls back to
      // the newest child (desktop semantics: 前缀匹配不上回退最新创建).
      expect(store.findChildSession('par', description: 't00')?.id, 'kid69');
    });
  });

  group('conversation container exemption', () {
    test('child conversations survive LRU eviction pressure', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));

      // Fill 20 non-child conversations (the cap), then create the child one.
      for (var i = 0; i < 20; i++) {
        store.ensureConversation('filler$i');
      }
      expect(store.conversationForRead('kid'), isNull);

      final kid = store.ensureConversation('kid')!;
      kid.onPartUpdated(<String, dynamic>{
        'messageID': 'm1',
        'id': 'p1',
        'type': 'text',
      }, 'accumulated');

      // One more filler over the cap — the child must NOT be the victim.
      store.ensureConversation('overflow');
      final kidAfter = store.conversationForRead('kid');
      expect(kidAfter, same(kid),
          reason: 'child conversation is exempt from LRU eviction');
      expect(kidAfter!.renderableMessages, isNotEmpty,
          reason: 'accumulated SSE content must survive eviction rounds');
    });

    test('ensureConversation resolves directory from _childSessions',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final conv = store.ensureConversation('kid')!;
      expect(conv.directory, '/repo',
          reason: 'child session directory comes from the registry');
    });
  });

  group('DisplayPart.toolMetadata plumbing', () {
    test('onPartUpdated keeps metadata from SSE tool part updates', () {
      final conv = ConversationStore('s1', _fakeClient());
      conv.onPartUpdated(<String, dynamic>{
        'messageID': 'm1',
        'id': 'tp1',
        'type': 'tool',
        'tool': 'task',
        'state': {
          'status': 'running',
          'input': {
            'subagent_type': 'explore',
            'description': 'explore lib',
          },
          'metadata': {'sessionId': 'kid_123'},
        },
      }, null);
      final dp = conv.messages.single.parts.single;
      expect(dp.tool, 'task');
      expect(dp.toolStatus, 'running');
      expect(dp.toolMetadata?['sessionId'], 'kid_123');
      expect(dp.toolInput?['subagent_type'], 'explore');
    });

    test('DisplayPart.from captures state.metadata', () {
      final p = MessagePart(<String, dynamic>{
        'id': 'tp2',
        'type': 'tool',
        'tool': 'task',
        'state': {
          'status': 'completed',
          'metadata': {'sessionId': 'kid_456'},
        },
      });
      final dp = DisplayPart.from(p);
      expect(dp.toolMetadata?['sessionId'], 'kid_456');
    });

    test('merge keeps SSE metadata when REST lacks it', () {
      // _mergeParts runs on reconcile: REST authoritative entry wins, but
      // SSE-only fields (metadata) must carry over. Route via conv.load()
      // is networked; instead drive the same merge through reconcile-free
      // surface: onPartUpdated (SSE) then verify _mergeParts preserves by
      // invoking the private path indirectly — assert the SSE dp keeps it
      // after a second part update without metadata (defensive overwrite
      // must not clear it since null skips assignment).
      final conv = ConversationStore('s1', _fakeClient());
      conv.onPartUpdated(<String, dynamic>{
        'messageID': 'm1',
        'id': 'tp1',
        'type': 'tool',
        'tool': 'task',
        'state': {
          'status': 'running',
          'metadata': {'sessionId': 'kid'},
        },
      }, null);
      // Follow-up update without metadata (server omits the field).
      conv.onPartUpdated(<String, dynamic>{
        'messageID': 'm1',
        'id': 'tp1',
        'type': 'tool',
        'tool': 'task',
        'state': {'status': 'completed'},
      }, null);
      final dp = conv.messages.single.parts.single;
      expect(dp.toolMetadata?['sessionId'], 'kid',
          reason: 'missing metadata must not clear the accumulated value');
      expect(dp.toolStatus, 'completed');
    });
  });

  // subagent 权限/问题卡上浮父会话（permission.asked/question.asked 携带
  // 子会话 id，卡片只在父会话 FooterPanel 渲染；不上浮则卡片无处显示、
  // 整个运行卡死在待授权）。
  group('subagent permission/question cards host in parent session', () {
    OpencodeEvent permAsk(String sid, String pid) => OpencodeEvent(
          type: 'permission.asked',
          properties: {
            'id': pid,
            'sessionID': sid,
            'permission': 'bash',
            'patterns': ['rm -rf'],
          },
        );

    OpencodeEvent questionAsk(String sid, String qid) => OpencodeEvent(
          type: 'question.asked',
          properties: {
            'id': qid,
            'sessionID': sid,
            'questions': [
              {
                'question': 'proceed?',
                'header': 'Confirm',
                'options': [
                  {'label': 'yes', 'value': 'yes'},
                  {'label': 'no', 'value': 'no'},
                ],
              }
            ],
          },
        );

    test('SSE permission.asked for child surfaces card in parent conv',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;

      store.onEventForTesting(permAsk('kid', 'perm-1'));

      expect(parent.permissions.single.id, 'perm-1',
          reason: 'child card must render in the parent conversation');
      expect(store.conversationForRead('kid'), isNull,
          reason: 'no child conv is created merely by a card');
      expect(store.agentIndicatorStateOf('par').state, AgentRunState.paused);
      expect(store.agentIndicatorStateOf('par').pauseReason,
          AgentPauseReason.permission);
    });

    test('SSE permission.replied for child removes the card from parent',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;

      store.onEventForTesting(permAsk('kid', 'perm-1'));
      store.onEventForTesting(const OpencodeEvent(
        type: 'permission.replied',
        properties: {'sessionID': 'kid', 'requestID': 'perm-1'},
      ));

      expect(parent.permissions, isEmpty);
      expect(store.agentIndicatorStateOf('par').pendingCount, 0);
    });

    test('SSE question.asked/replied for child route to parent conv', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;

      store.onEventForTesting(questionAsk('kid', 'q-1'));
      expect(parent.questions.single.id, 'q-1');
      expect(store.agentIndicatorStateOf('par').pauseReason,
          AgentPauseReason.choice);

      store.onEventForTesting(const OpencodeEvent(
        type: 'question.replied',
        properties: {'sessionID': 'kid', 'requestID': 'q-1'},
      ));
      expect(parent.questions, isEmpty);
    });

    test('late child registration adopts pending cards (SSE race)', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      final parent = store.ensureConversation('par')!;

      // Card arrives before the child session.updated event — no host
      // mapping exists yet, so the card is only in the pending map.
      store.onEventForTesting(permAsk('kid', 'perm-1'));
      expect(parent.permissions, isEmpty,
          reason: 'unregistered child has no parent mapping yet');

      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      expect(parent.permissions.single.id, 'perm-1',
          reason: 'registration must float the stranded card to the parent');
      expect(store.agentIndicatorStateOf('par').pauseReason,
          AgentPauseReason.permission);
    });

    test('ensureConversation on parent injects pending child cards', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      store.onEventForTesting(permAsk('kid', 'perm-1'));

      final parent = store.ensureConversation('par')!;
      expect(parent.permissions.single.id, 'perm-1',
          reason: 'conv (re)creation must re-inject hosted child cards');
    });

    test('respondPermission POSTs to the card session id, not the conv id',
        () async {
      final cap = _Capture();
      final store = ServerStore()..client = _captureClient(cap);
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;
      store.onEventForTesting(permAsk('kid', 'perm-1'));

      await parent.respondPermission(parent.permissions.single, 'once');

      expect(cap.method, 'POST');
      expect(cap.path, '/session/kid/permissions/perm-1',
          reason: 'server-side pending lives under the child session');
      expect(parent.permissions, isEmpty,
          reason: 'successful reply removes the hosted card');
    });

    test('successful backfill snapshot drops child card resolved elsewhere',
        () async {
      // 他端答复 + 本端错过 replied SSE（重连窗口）→ REST 快照（权威）不再
      // 含该卡。子会话不在 `_sessions`，restore 循环必须回退
      // `_childSessions` 取 directory，否则 dir 恒空走复活分支。
      final store = ServerStore()..client = _EmptyBackfillClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      store.ensureConversation('par');
      store.onEventForTesting(permAsk('kid', 'perm-1'));
      expect(store.hasPendingPermission('par'), isTrue);

      await store.backfillPermissionsForTesting();

      expect(store.hasPendingPermission('par'), isFalse,
          reason: 'authoritative snapshot must not be overridden by restore');
      expect(store.agentIndicatorStateOf('par').pauseReason,
          isNot(AgentPauseReason.permission));
    });

    test('successful backfill snapshot drops child question resolved elsewhere',
        () async {
      // 同上，覆盖 question 的 restore 循环（server_store 与权限对称但
      // 独立的一段代码路径）。
      final store = ServerStore()..client = _EmptyBackfillClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      store.ensureConversation('par');
      store.onEventForTesting(questionAsk('kid', 'q-1'));
      expect(store.hasPendingQuestion('par'), isTrue);

      await store.backfillPermissionsForTesting();

      expect(store.hasPendingQuestion('par'), isFalse);
      expect(store.agentIndicatorStateOf('par').pauseReason,
          isNot(AgentPauseReason.choice));
    });

    test('grandchild card (subagent_depth > 1) hosts at top-level ancestor',
        () {
      // 传递上浮：孙辈卡沿途只到中层子会话 conv 仍是不可见宿主（面板不
      // 渲染卡片），必须一路走到顶层祖先。
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('mid', 'par', created: 5, title: 'mid task'));
      store.upsertSessionForTesting(
          _child('gkid', 'mid', created: 6, title: 'leaf task'));
      final top = store.ensureConversation('par')!;

      store.onEventForTesting(permAsk('gkid', 'perm-1'));

      expect(top.permissions.single.id, 'perm-1',
          reason: 'grandchild card must reach the top-level conversation');
      expect(store.agentIndicatorStateOf('par').pauseReason,
          AgentPauseReason.permission);

      store.onEventForTesting(const OpencodeEvent(
        type: 'permission.replied',
        properties: {'sessionID': 'gkid', 'requestID': 'perm-1'},
      ));
      expect(top.permissions, isEmpty,
          reason: 'replied for grandchild must remove the card at the host');
    });

    test('archived mid-level child drops its own card from top-level host',
        () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('mid', 'par', created: 5, title: 'mid task'));
      final top = store.ensureConversation('par')!;

      store.onEventForTesting(permAsk('mid', 'perm-m'));
      expect(top.permissions.single.id, 'perm-m');

      store.upsertSessionForTesting(SessionModel(
        id: 'mid',
        projectID: 'p',
        directory: '/repo',
        title: 'mid task',
        created: 5,
        updated: 5,
        parentID: 'par',
        archived: 9,
      ));

      expect(top.permissions, isEmpty,
          reason: 'host resolution happens before registry removal');
    });

    test('pendingCount aggregates parallel subagent permission cards', () {
      // 宿主路由把多个并行子会话的卡聚合到同一父会话，计数不能封顶 1。
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid1', 'par', created: 5, title: 'a'));
      store.upsertSessionForTesting(
          _child('kid2', 'par', created: 6, title: 'b'));

      store.onEventForTesting(permAsk('kid1', 'perm-1'));
      store.onEventForTesting(permAsk('kid2', 'perm-2'));

      final state = store.agentIndicatorStateOf('par');
      expect(state.state, AgentRunState.paused);
      expect(state.pauseReason, AgentPauseReason.permission);
      expect(state.pendingCount, 2);
    });

    test('archived child drops hosted cards from parent', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;
      store.onEventForTesting(permAsk('kid', 'perm-1'));
      expect(parent.permissions.single.id, 'perm-1');

      store.upsertSessionForTesting(SessionModel(
        id: 'kid',
        projectID: 'p',
        directory: '/repo',
        title: 'task',
        created: 5,
        updated: 5,
        parentID: 'par',
        archived: 9,
      ));

      expect(parent.permissions, isEmpty,
          reason: 'host mapping is gone — the card must not strand in parent');
      expect(store.agentIndicatorStateOf('par').pauseReason,
          isNot(AgentPauseReason.permission));
    });

    test('session.deleted child drops hosted cards from parent', () {
      final store = ServerStore()..client = _fakeClient();
      store.upsertSessionForTesting(_parent('par'));
      store.upsertSessionForTesting(
          _child('kid', 'par', created: 5, title: 'task'));
      final parent = store.ensureConversation('par')!;
      store.onEventForTesting(permAsk('kid', 'perm-1'));

      store.onEventForTesting(const OpencodeEvent(
        type: 'session.deleted',
        properties: {
          'info': {'id': 'kid'}
        },
      ));

      expect(parent.permissions, isEmpty);
      expect(store.hasPendingPermission('par'), isFalse);
    });
  });
}

class _Capture {
  String? method;
  String? path;
}

class _CaptureAdapter implements HttpClientAdapter {
  final _Capture cap;
  _CaptureAdapter(this.cap);
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cap.method = options.method;
    cap.path = options.path;
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

OpencodeClient _captureClient(_Capture cap) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _CaptureAdapter(cap);
  return OpencodeClient(dio);
}

class _EmptyBackfillClient extends OpencodeClient {
  _EmptyBackfillClient() : super(_deadDio());

  @override
  Future<List<Permission>> pendingPermissions(String directory) async =>
      const [];

  @override
  Future<List<QuestionRequest>> listQuestions({String? directory}) async =>
      const [];
}

Dio _deadDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));
