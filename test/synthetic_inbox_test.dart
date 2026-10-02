import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// design-subagent-background §D4：v2.0.18 上子会话完成通知经
/// `session.inbox.enqueued`（item.type == 'synthetic'，inboxID 即消息 id，
/// payload 带 metadata）落地，需物化为带 metadata 的 synthetic 消息，
/// 供渲染层就地按系统提示呈现。
/// metadata 键名（权威来源：`packages/core/src/session/subagent-completion.ts`
/// 的 `SubagentCompletion.deliver`）：`source=='subagent'`、`childID`、
/// `agent`、`state∈{completed,error,cancelled}`。
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

void main() {
  test('synthetic inbox item materializes with metadata', () {
    final store = ConversationStore('s', _fakeClient());
    store.onInboxEnqueued(
      'msg_1',
      {
        'type': 'synthetic',
        'payload': {
          'text':
              '<subagent sessionID="c" state="completed" description="d">hi there</subagent>',
          'description': 'd',
          'metadata': {
            'source': 'subagent',
            'childID': 'c',
            'agent': 'reviewer',
            'state': 'completed',
          },
        },
      },
      created: 1,
    );

    final msgs = store.renderableMessages;
    expect(msgs, hasLength(1));
    expect(msgs.first.type, 'synthetic');
    expect(msgs.first.id, 'msg_1');
    expect(msgs.first.metadata?['source'], 'subagent');
    expect(msgs.first.metadata?['childID'], 'c');
    expect(msgs.first.text, contains('hi there'));
  });

  test('non-synthetic, non-user inbox items are ignored', () {
    final store = ConversationStore('s', _fakeClient());
    store.onInboxEnqueued(
      'msg_2',
      {'type': 'compaction', 'payload': const {}},
      created: 1,
    );
    expect(store.renderableMessages, isEmpty);
  });
}
