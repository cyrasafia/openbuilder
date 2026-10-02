import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

import 'v2_test_fixtures.dart';

/// design-subagent-background：
/// - 后台任务启动提示在「子会话注册先于工具型 tool part 入流」的竞态下会被
///   误插；tool part 一旦带 `metadata.sessionID` 命中，须撤回。
/// - synthetic（`<subagent …>` 原始标记）不得作为列表预览文本。
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

SessionModel _child(String id, String parentID, {int created = 5, String? outcome}) =>
    SessionModel(
      id: id,
      projectID: 'p',
      directory: '/repo',
      title: '调研仓库结构',
      created: created,
      updated: created,
      parentID: parentID,
      agent: 'explore',
      outcome: outcome,
    );

bool _hasStartNotice(ConversationStore s) =>
    s.messages.any((m) => m.metadata?['kind'] == 'background-started');

void main() {
  test('tool-form child retracts a prematurely inserted start notice', () {
    final store = ConversationStore('p', _fakeClient());
    final child = _child('kid', 'p');

    // 子会话注册时 tool part 尚未入流 → 误判为后台任务，插入启动提示。
    store.onChildSessionRegistered(child);
    expect(_hasStartNotice(store), isTrue);

    // tool part 入流并带上 sessionID → 撤回启动提示，判定为工具型。
    store.onToolInputStarted('m1', 'c1', 'task');
    store.onToolCalled(
        'm1',
        'c1',
        {
          'subagent_type': 'explore',
          'description': '调研仓库结构',
        },
        null);
    store.onToolProgress('m1', 'c1', {'sessionID': 'kid'});

    expect(_hasStartNotice(store), isFalse);
    expect(store.isToolFormChild(child), isTrue);
  });

  test('command-form child keeps its start notice', () {
    final store = ConversationStore('p', _fakeClient());
    store.onChildSessionRegistered(_child('kid', 'p'));
    expect(_hasStartNotice(store), isTrue);
  });

  test('start notice survives a reconcile window deletion', () async {
    final entries = [
      userMsg(id: 'msg_u1', text: 'hi', created: 100),
      assistantMsg(
          id: 'msg_a1',
          created: 1000,
          content: [textPart('ok')],
          finish: 'stop'),
    ];
    final store = ConversationStore('p', PageMockClient(entries));
    // child.created（500）落在对账窗口 [100, 1000] 内：窗口删除不得移除本地
    // 合成的启动提示，否则提示会在对账后消失（design-subagent-background D3）。
    store.onChildSessionRegistered(_child('kid', 'p', created: 500));
    expect(_hasStartNotice(store), isTrue);

    await store.reconcile();

    expect(_hasStartNotice(store), isTrue,
        reason: 'locally synthesized start notice must survive reconcile');
  });

  test('running background child is not evicted by the child-session LRU', () {
    final store = ServerStore();
    final running = _child('run', 'par', created: 1);
    store.upsertSessionForTesting(running);
    store.onEventForTesting(OpencodeEvent(
      type: 'session.execution.started',
      properties: {'sessionID': 'run'},
    ));
    expect(store.runningChildSessionsOf('par').map((e) => e.id), contains('run'));

    // Far more historical children than the LRU cap. Settled children are the
    // eviction candidates; the running one must stay indexed.
    for (var i = 0; i < 80; i++) {
      store.upsertSessionForTesting(
          _child('old$i', 'par', created: 1000 + i, outcome: 'succeeded'));
    }

    expect(store.runningChildSessionsOf('par').map((e) => e.id), contains('run'),
        reason: 'a running background task must never be evicted');
    store.dispose();
  });

  test('synthetic completion does not leak into the list preview', () {
    final store = ConversationStore('p', _fakeClient());
    store.onInboxEnqueued(
      'msg_1',
      {
        'type': 'synthetic',
        'payload': {
          'text':
              '<subagent sessionID="c" state="completed" description="d">hi</subagent>',
          'description': 'd',
          'metadata': {
            'source': 'subagent',
            'childID': 'c',
            'state': 'completed',
          },
        },
      },
      created: 1,
    );
    expect(store.lastMessagePreview(), isNull,
        reason: 'raw <subagent …> markup must not become the preview');
  });
}
