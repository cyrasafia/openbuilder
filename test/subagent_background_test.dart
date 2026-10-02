import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

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

SessionModel _child(String id, String parentID) => SessionModel(
      id: id,
      projectID: 'p',
      directory: '/repo',
      title: '调研仓库结构',
      created: 5,
      updated: 5,
      parentID: parentID,
      agent: 'explore',
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
