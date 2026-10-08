import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

import 'v2_test_fixtures.dart';

/// design-subagent-background（2026-10-08 升格）：
/// - 认领分层：前台认领（插入/撤回）/ 运行认领（任务卡排除）/ 转换检测。
/// - ② `background:true` 派发是合法后台任务：启动提示不撤、任务卡纳入。
/// - ③ 前台转后台：part completed ∧ 子会话在跑 → 合成 bg-convert（幂等）。
/// - 撤回经 REST 对账触发（SSE 缺口兜底）；启动提示 REST 重建窗口有界、幂等。
/// - 无 source 的③转换 synthetic（英文原文）不渲染（SSE 与 REST 两入口）。
/// - `created` 并列按 kind 秩稳定排序：消息 < 系统提示 < 乐观消息。
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

SessionModel _child(String id, String parentID,
        {int created = 5, String? outcome}) =>
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

void _dispatchForegroundSubagent(ConversationStore s,
    {String childId = 'kid', bool background = false}) {
  s.onToolInputStarted('m1', 'c1', 'task');
  s.onToolCalled('m1', 'c1', {
    'subagent_type': 'explore',
    'description': '调研仓库结构',
    if (background) 'background': true,
  }, null);
  s.onToolProgress('m1', 'c1', {'sessionID': childId});
}

void main() {
  test('foreground-claimed child retracts a prematurely inserted start notice',
      () {
    final store = ConversationStore('p', _fakeClient());
    final child = _child('kid', 'p');

    store.onChildSessionRegistered(child);
    expect(_hasStartNotice(store), isTrue);

    _dispatchForegroundSubagent(store);

    expect(_hasStartNotice(store), isFalse);
    expect(
        store.isForegroundClaimedChild(child.id, childTitle: child.title),
        isTrue);
    expect(store.isActiveClaimedChild(child.id, childTitle: child.title),
        isTrue);
  });

  test('command-form child keeps its start notice', () {
    final store = ConversationStore('p', _fakeClient());
    store.onChildSessionRegistered(_child('kid', 'p'));
    expect(_hasStartNotice(store), isTrue);
  });

  test('background:true dispatch keeps its notice and joins the task card', () {
    final store = ConversationStore('p', _fakeClient());
    final child = _child('kid', 'p');

    store.onChildSessionRegistered(child);
    expect(_hasStartNotice(store), isTrue);

    _dispatchForegroundSubagent(store, background: true);
    store.onToolSuccess('m1', 'c1', const []);

    expect(_hasStartNotice(store), isTrue,
        reason: 'background dispatch is a legit background task');
    expect(
        store.isForegroundClaimedChild(child.id, childTitle: child.title),
        isFalse);
    expect(store.isActiveClaimedChild(child.id, childTitle: child.title),
        isFalse,
        reason: 'completed dispatch part must not exclude the task card');
    expect(
        store.isConvertedClaimedChild(child.id, childTitle: child.title),
        isFalse,
        reason: 'explicit background:true is not a conversion');
  });

  test('foreground part completed while child runs synthesizes bg-convert', () {
    final store = ConversationStore('p', _fakeClient());
    final child = _child('kid', 'p');

    _dispatchForegroundSubagent(store);
    store.onToolSuccess('m1', 'c1', const []);

    store.reconcileConvertedNotices([child]);
    expect(
      store.messages.any((m) => m.metadata?['kind'] == 'background-converted'),
      isTrue,
    );

    store.reconcileConvertedNotices([child]);
    expect(
      store.messages
          .where((m) => m.metadata?['kind'] == 'background-converted')
          .length,
      1,
      reason: 'bg-convert:<childID> is idempotent',
    );
  });

  test('resume claim via input.sessionID is authoritative', () {
    final store = ConversationStore('p', _fakeClient());
    store.onToolInputStarted('m1', 'c1', 'subagent');
    store.onToolCalled('m1', 'c1', {
      'description': '续跑一个标题不同的子会话',
      'sessionID': 'kid',
    }, null);

    final resumed = SessionModel(
      id: 'kid',
      projectID: 'p',
      directory: '/repo',
      title: '与 description 不同的标题',
      created: 5,
      updated: 5,
      parentID: 'p',
    );
    expect(store.isForegroundClaimedChild(resumed.id, childTitle: resumed.title),
        isTrue);
  });

  test('REST-only claimed part retracts the start notice on reconcile',
      () async {
    final entries = [
      userMsg(id: 'msg_u1', text: 'hi', created: 100),
      assistantMsg(
        id: 'msg_a1',
        created: 200,
        content: [
          toolPart(
            id: 'c1',
            name: 'task',
            status: 'completed',
            input: {'description': '调研仓库结构'},
            metadata: {'sessionID': 'kid'},
          ),
        ],
        finish: 'stop',
      ),
    ];
    final store = ConversationStore('p', PageMockClient(entries));
    final child = _child('kid', 'p', created: 150);
    store.onChildSessionRegistered(child);
    expect(_hasStartNotice(store), isTrue);

    store.backgroundChildrenSource = (sid) => (
          children: [child],
          runningChildren: const <SessionModel>[],
        );
    await store.reconcile();

    expect(_hasStartNotice(store), isFalse,
        reason: 'REST merge surfaces the foreground claim');
  });

  test('tool.failed event metadata maintains the claim', () {
    final store = ConversationStore('p', _fakeClient());
    final child = _child('kid', 'p');

    store.onToolInputStarted('m1', 'c1', 'task');
    store.onToolCalled('m1', 'c1', {
      'subagent_type': 'explore',
      'description': '调研仓库结构',
    }, null);
    store.onToolFailed(
      'm1',
      'c1',
      const {'message': 'interrupted'},
      metadata: {'sessionID': 'kid'},
    );

    expect(
        store.isForegroundClaimedChild(child.id, childTitle: child.title),
        isTrue,
        reason: 'failed part keeps its claim via event metadata');
    expect(store.isActiveClaimedChild(child.id, childTitle: child.title),
        isFalse);
  });

  test('rebuildStartNotices is window-bounded and idempotent', () async {
    final entries = [
      userMsg(id: 'msg_u1', text: 'hi', created: 100),
      userMsg(id: 'msg_u2', text: 'again', created: 300),
    ];
    final store = ConversationStore('p', PageMockClient(entries));
    await store.reconcile();

    store.rebuildStartNotices([
      _child('in', 'p', created: 200),
      _child('out', 'p', created: 50),
    ]);
    expect(store.messages.any((m) => m.id == 'bg-start:in'), isTrue);
    expect(store.messages.any((m) => m.id == 'bg-start:out'), isFalse,
        reason: 'earlier-than-window children are not rebuilt');

    final before = store.messages.firstWhere((m) => m.id == 'bg-start:in');
    store.rebuildStartNotices([_child('in', 'p', created: 200)]);
    final after = store.messages.firstWhere((m) => m.id == 'bg-start:in');
    expect(after, same(before));
    expect(store.messages.where((m) => m.id == 'bg-start:in').length, 1);
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
    store.onChildSessionRegistered(_child('kid', 'p', created: 500));
    expect(_hasStartNotice(store), isTrue);

    await store.reconcile();

    expect(_hasStartNotice(store), isTrue,
        reason: 'locally synthesized start notice must survive reconcile');
  });

  test('created ties sort message < notice, then by id', () async {
    final entries = [
      userMsg(id: 'msg_u1', text: 'hi', created: 100),
    ];
    final store = ConversationStore('p', PageMockClient(entries));
    await store.reconcile();

    store.rebuildStartNotices([
      _child('b_kid', 'p', created: 100),
      _child('a_kid', 'p', created: 100),
    ]);

    expect(store.messages.map((m) => m.id).toList(),
        ['msg_u1', 'bg-start:a_kid', 'bg-start:b_kid']);
  });

  test('source-less conversion synthetic is not rendered', () {
    final store = ConversationStore('p', _fakeClient());
    store.onInboxEnqueued(
      'msg_bg1',
      {
        'type': 'synthetic',
        'payload': {
          'text':
              'User requested that active blocking work be moved to the background',
        },
      },
      created: 1,
    );
    expect(store.messages.any((m) => m.id == 'msg_bg1'), isFalse,
        reason: 'conversion synthetic must not enter the stream via inbox');

    final viaRest = store.toDisplayForTest(syntheticMsg(
      id: 'msg_bg2',
      text:
          'User requested that active blocking work be moved to the background',
    ));
    expect(viaRest, isNull,
        reason: 'conversion synthetic must not enter the stream via REST');

    final completion = store.toDisplayForTest(syntheticMsg(
      id: 'msg_bg3',
      text: '<subagent sessionID="c" state="completed" description="d">hi</subagent>',
    ));
    expect(completion, isNotNull,
        reason: 'sourced synthetic completion is unaffected');
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
