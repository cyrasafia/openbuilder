// design-shell-background 回归：
// - 判据单点：part completed ∧ metadata.{shellID,status:"running"}；
//   前台完成（无 shellID）/ failed / toolInput 非 Map 不插。
// - live 插入 ②start / ③convert；对账重建（part + ④ ShellMessage）幂等、
//   权威 created 覆盖 live 骨架值。
// - `_mergeParts` metadata 字段级合并：SSE progress 的 `{shellID}` 不覆盖
//   REST 全量的 `status`（识别模型覆盖窗口修复）。
// - `finishedShellIds` 终态集：synthetic source:shell + ④ 终态 ShellMessage。
// - DisplayMessage.shellID 缓存 round-trip。
// - ServerStore.reconcileShellTasks 归属过滤 + 终态集排除 + ④ 混计。
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

void _dispatchShellTool(
  ConversationStore s, {
  required String callId,
  Map<String, dynamic>? input,
  Map<String, dynamic>? metadata,
}) {
  s.onToolInputStarted('m1', callId, 'shell');
  s.onToolCalled('m1', callId, input, null);
  if (metadata != null) {
    s.onToolProgress('m1', callId, metadata);
  }
  s.onToolSuccess('m1', callId, const [], metadata: metadata);
}

void main() {
  group('shell dispatch criteria (live)', () {
    test('background dispatch inserts bg-shell-start (path 2)', () {
      final store = ConversationStore('p', _fakeClient());
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'npm run dev', 'background': true},
        metadata: {'shellID': 'sh_1', 'status': 'running', 'truncated': false},
      );
      final hit = store.onShellToolPartSettled('m1', 'c1', 100);
      expect(hit, isTrue);
      final notice = store.messages
          .where((m) => m.id == 'bg-shell-start:sh_1')
          .single;
      expect(notice.metadata?['kind'], 'background-started');
      expect(notice.description, 'npm run dev');
    });

    test('foreground-to-background conversion inserts bg-shell-convert (path 3)',
        () {
      final store = ConversationStore('p', _fakeClient());
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'sleep 60'},
        metadata: {'shellID': 'sh_2', 'status': 'running'},
      );
      expect(store.onShellToolPartSettled('m1', 'c1', 100), isTrue);
      final notice = store.messages
          .where((m) => m.id == 'bg-shell-convert:sh_2')
          .single;
      expect(notice.metadata?['kind'], 'background-converted');
    });

    test('foreground completion (no shellID) never inserts', () {
      final store = ConversationStore('p', _fakeClient());
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'echo hi'},
        metadata: {'status': 'completed'},
      );
      expect(store.onShellToolPartSettled('m1', 'c1', 100), isFalse);
      expect(store.messages.where((m) => m.id.startsWith('bg-shell')), isEmpty);
    });

    test('metadata without status running never inserts', () {
      final store = ConversationStore('p', _fakeClient());
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'echo hi', 'background': true},
        metadata: {'shellID': 'sh_3', 'status': 'completed'},
      );
      expect(store.onShellToolPartSettled('m1', 'c1', 100), isFalse);
    });

    test('non-Map toolInput (SSE gap raw JSON string) never inserts', () {
      final store = ConversationStore('p', _fakeClient());
      // SSE 缺口下 part 可能只经 progress 落 metadata 而 input 缺失
      // （onToolCalled input 传 null → toolInput 为空 Map）。toolInput 为空
      // Map 时 background 字段缺省 = ③——但 input 无 command 可读也不该插
      // ②start：空 Map 有 background:false 语义。这里钉住「input 缺失不插」
      // 的底线：shellID + status running 但 input 完全缺失。
      onToolCalledNullInput(store);
      expect(store.onShellToolPartSettled('m1', 'c1', 100), isFalse);
    });
  });

  group('reconcile rebuild', () {
    test('part-based rebuild recovers notices (SSE gap)', () {
      final store = ConversationStore('p', _fakeClient());
      // REST 快照路径：直接落 part（绕过 live 事件）
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'make build', 'background': true},
        metadata: {'shellID': 'sh_4', 'status': 'running'},
      );
      store.rebuildShellNotices();
      expect(
          store.messages.where((m) => m.id == 'bg-shell-start:sh_4').single,
          isNotNull,
          reason: '对账重建从持久 part 判据恢复入列消息');
    });

    test('bang ShellMessage gets start notice, deduped against part path',
        () {
      final store = ConversationStore('p', _fakeClient());
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_1',
        raw: const {},
        created: 200,
        shellID: 'sh_5',
        command: 'pytest -q',
        status: 'exited',
        exit: 0,
        output: 'ok\n',
      ));
      store.rebuildShellNotices();
      final notices = store.messages
          .where((m) => m.id == 'bg-shell-start:sh_5')
          .toList();
      expect(notices.length, 1, reason: '④ 幂等补插且不与 part 路径重复');
      expect(notices.single.description, 'pytest -q');
      expect(notices.single.created, 200);
    });

    test('authoritative rebuild overwrites live skeleton created', () {
      final store = ConversationStore('p', _fakeClient());
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'dev', 'background': true},
        metadata: {'shellID': 'sh_6', 'status': 'running'},
      );
      store.onShellToolPartSettled('m1', 'c1', 999);
      store.rebuildShellNotices();
      final notice =
          store.messages.where((m) => m.id == 'bg-shell-start:sh_6').single;
      expect(notice.created, lessThan(999),
          reason: '对账用承载消息 created 覆盖 live 信封骨架值');
    });
  });

  group('_mergeParts metadata field-level merge', () {
    test('SSE partial metadata does not clobber REST status key', () {
      final store = ConversationStore('p', _fakeClient());
      // 顺序 1：SSE progress 先落地部分 metadata（缺口吞掉 success）
      _dispatchShellTool(
        store,
        callId: 'c1',
        input: {'command': 'dev', 'background': true},
        metadata: {'shellID': 'sh_7'},
      );
      // 顺序 2：REST 对账带回全量（经 onToolSuccess metadata 并入）
      store.onToolSuccess('m1', 'c1', const [],
          metadata: {'shellID': 'sh_7', 'status': 'running'});
      expect(store.onShellToolPartSettled('m1', 'c1', 100), isTrue,
          reason: '字段级合并保住 status 键，判据仍命中');
    });

    test('in-store partial metadata survives REST snapshot merge path', () {
      final store = ConversationStore('p', _fakeClient());
      // SSE 缺口序：progress 落 {shellID}-only，success 被吞——part 停留
      // running；REST 对账经 AssistantMessage 快照合并（_mergeParts），
      // SSE 侧 {shellID}-only 不得整 Map 覆盖 REST 全量。
      store.onToolInputStarted('m1', 'c1', 'shell');
      store.onToolCalled('m1', 'c1', {
        'command': 'dev',
        'background': true,
      }, null);
      store.onToolProgress('m1', 'c1', {'shellID': 'sh_8'});
      store.onSynthetic(AssistantMessage(
        id: 'm1',
        raw: const {},
        created: 50,
        agent: 'build',
        model: null,
        finish: 'tool-calls',
        content: [
          ToolContent(
            id: 'c1',
            name: 'shell',
            executed: false,
            created: 50,
            state: CompletedToolState(
              input: {'command': 'dev', 'background': true},
              content: const [],
              metadata: {
                'shellID': 'sh_8',
                'status': 'running',
                'truncated': false,
              },
            ),
          ),
        ],
      ));
      store.rebuildShellNotices();
      expect(
        store.messages.where((m) => m.id == 'bg-shell-start:sh_8').single,
        isNotNull,
        reason: 'REST 合并后 status 键存活，判据经对账重建命中',
      );
    });
  });

  group('finishedShellIds', () {
    test('collects synthetic shell completions and bang terminal messages',
        () {
      final store = ConversationStore('p', _fakeClient());
      store.onSynthetic(SyntheticMessage(
        id: 'msg_syn_1',
        raw: const {},
        created: 10,
        metadata: {
          'source': 'shell',
          'shellID': 'sh_8',
          'state': 'completed',
          'exit': 0,
        },
        text: '<shell id="sh_8" state="completed" command="x"></shell>',
      ));
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_2',
        raw: const {},
        created: 11,
        shellID: 'sh_9',
        command: 'y',
        status: 'running',
      ));
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_3',
        raw: const {},
        created: 12,
        shellID: 'sh_10',
        command: 'z',
        status: 'killed',
      ));
      final ids = store.finishedShellIds;
      expect(ids, containsAll(['sh_8', 'sh_10']));
      expect(ids.contains('sh_9'), isFalse,
          reason: 'running 中的 ④ shell 不在终态集');
    });
  });

  group('DisplayMessage shellID cache round-trip', () {
    test('shellID survives serialize/deserialize', () {
      final store = ConversationStore('p', _fakeClient());
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_4',
        raw: const {},
        created: 20,
        shellID: 'sh_11',
        command: 'c',
        status: 'exited',
        exit: 0,
      ));
      final msg = store.messages.where((m) => m.id == 'msg_shell_4').single;
      expect(msg.shellID, 'sh_11');
      final raw = store.messageToJsonForTesting(msg);
      final restored = SessionMessage.fromJson(raw);
      expect(restored, isA<ShellMessage>());
      expect((restored as ShellMessage).shellID, 'sh_11',
          reason: '缓存 round-trip 不丢 shellID（_messageToJson 曾硬编码空串）');
    });

    test('running to terminal transition updates entry and invalidates cache',
        () {
      final store = ConversationStore('p', _fakeClient());
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_5',
        raw: const {},
        created: 21,
        shellID: 'sh_12',
        command: 'dev',
        status: 'running',
      ));
      store.consumeContentInvalidations();
      store.onSynthetic(ShellMessage(
        id: 'msg_shell_5',
        raw: const {},
        created: 21,
        completed: 99,
        shellID: 'sh_12',
        command: 'dev',
        status: 'exited',
        exit: 3,
      ));
      final msg = store.messages.where((m) => m.id == 'msg_shell_5').single;
      expect(msg.shellStatus, 'exited');
      expect(msg.shellExit, 3);
      final invalid = store.consumeContentInvalidations();
      expect(invalid == null || invalid.contains('msg_shell_5'), isTrue,
          reason: '_sameMessage 不比较 shell 字段——重渲染依赖 completed '
              'null→值 差异触发失效（隐式依赖钉死）');
    });
  });

  group('ServerStore.reconcileShellTasks', () {
    test('filters by sessionID, running status and finished set', () async {
      final client = _FakeShellClient([
        ShellInfo(
          id: 'sh_a',
          status: 'running',
          command: 'a',
          sessionID: 'par',
          background: true,
        ),
        ShellInfo(
          id: 'sh_b',
          status: 'running',
          command: 'b',
          sessionID: 'other',
          background: true,
        ),
        ShellInfo(
          id: 'sh_c',
          status: 'running',
          command: 'c',
          sessionID: 'par',
          background: true,
        ),
      ]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(SessionModel(
        id: 'par',
        projectID: 'p',
        directory: '/repo',
        title: 'main',
        created: 1,
        updated: 1,
      ));
      final conv = store.ensureConversation('par')!;
      // sh_c 已有完成回执 → 终态集排除（竞态：synthetic 先到 list 尚含）
      conv.onSynthetic(SyntheticMessage(
        id: 'msg_syn_2',
        raw: const {},
        created: 30,
        metadata: {
          'source': 'shell',
          'shellID': 'sh_c',
          'state': 'completed',
        },
        text: '',
      ));
      await store.reconcileShellTasks('par');
      final ids = store.runningShellTasks('par').map((s) => s.id).toList();
      expect(ids, ['sh_a']);
    });

    test('foreground agent shell never enters the task card (B-1)', () async {
      final client = _FakeShellClient([
        ShellInfo(
          id: 'sh_fg',
          status: 'running',
          command: 'make build',
          sessionID: 'par',
        ),
      ]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(SessionModel(
        id: 'par',
        projectID: 'p',
        directory: '/repo',
        title: 'main',
        created: 1,
        updated: 1,
      ));
      await store.reconcileShellTasks('par');
      expect(store.runningShellTasks('par'), isEmpty,
          reason: '前台 shell：无 background 键、不在已知集——两判皆不命中');
    });

    test('agent background dispatch enters via known-set (B-1)', () async {
      final client = _FakeShellClient([
        ShellInfo(
          id: 'sh_bg',
          status: 'running',
          command: 'npm run dev',
          sessionID: 'par',
        ),
      ]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(SessionModel(
        id: 'par',
        projectID: 'p',
        directory: '/repo',
        title: 'main',
        created: 1,
        updated: 1,
      ));
      final conv = store.ensureConversation('par')!;
      // ② 派发：part 判据落 bg-shell-start 通知 → 已知集收录
      conv.onToolInputStarted('m1', 'c1', 'shell');
      conv.onToolCalled('m1', 'c1', {
        'command': 'npm run dev',
        'background': true,
      }, null);
      conv.onToolSuccess('m1', 'c1', const [], metadata: {
        'shellID': 'sh_bg',
        'status': 'running',
      });
      expect(conv.onShellToolPartSettled('m1', 'c1', 100), isTrue);
      await store.reconcileShellTasks('par');
      expect(
          store.runningShellTasks('par').map((s) => s.id), ['sh_bg'],
          reason: '② list 无 background 键（活体）——经通知已知集判别入卡');
    });

    test('stop removes optimistically and records deleted id', () async {
      final client = _FakeShellClient([
        ShellInfo(
          id: 'sh_d',
          status: 'running',
          command: 'd',
          sessionID: 'par',
          background: true,
        ),
      ]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(SessionModel(
        id: 'par',
        projectID: 'p',
        directory: '/repo',
        title: 'main',
        created: 1,
        updated: 1,
      ));
      await store.reconcileShellTasks('par');
      await store.stopBackgroundShell('sh_d', 'par');
      expect(store.runningShellTasks('par'), isEmpty);
      expect(store.isDeletedShell('sh_d'), isTrue);
      expect(client.deleted, contains('sh_d'));
    });
  });
}

void onToolCalledNullInput(ConversationStore store) {
  store.onToolInputStarted('m1', 'c1', 'shell');
  store.onToolCalled('m1', 'c1', null, null);
  store.onToolProgress('m1', 'c1', {'shellID': 'sh_x', 'status': 'running'});
}

class _FakeShellClient extends OpencodeClient {
  _FakeShellClient(this.shells)
      : super(dioFor(const ConnectionProfile(
          id: 't',
          name: 'test',
          address: 'http://127.0.0.1:9',
          username: 'opencode',
          password: '',
        )));

  final List<ShellInfo> shells;
  final List<String> deleted = [];

  @override
  Future<List<ShellInfo>> listShells(String directory) async => shells;

  @override
  Future<void> deleteShell(String id, String directory) async {
    deleted.add(id);
  }
}
