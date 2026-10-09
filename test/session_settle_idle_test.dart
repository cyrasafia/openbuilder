import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

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

OpencodeEvent _ev(String type, String sid) => OpencodeEvent(
      type: type,
      properties: {'sessionID': sid},
    );

void main() {
  test('execution.succeeded clears a busy conversation status', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    store.onEventForTesting(_ev('session.execution.started', 's1'));
    conv.setStatus('busy');
    store.onEventForTesting(_ev('session.execution.succeeded', 's1'));
    expect(store.statusOf('s1').type, 'idle');
    expect(conv.status, 'idle');
    conv.dispose();
    store.dispose();
  });

  test('execution.failed settles a retry conversation status to error', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    conv.setStatus('retry', retryMessage: 'boom');
    store.onEventForTesting(_ev('session.retry.scheduled', 's1'));
    store.onEventForTesting(_ev('session.execution.failed', 's1'));
    expect(store.statusOf('s1').type, 'error');
    expect(conv.status, 'error');
    expect(conv.retryMessage, isNull);
    conv.dispose();
    store.dispose();
  });

  test('execution.failed settles without a conversation as error', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    store.onEventForTesting(_ev('session.execution.started', 's1'));
    expect(store.statusOf('s1').type, 'busy');
    store.onEventForTesting(_ev('session.execution.failed', 's1'));
    expect(store.statusOf('s1').type, 'error');
    store.dispose();
  });

  test('settle without a conversation still resets the status map', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    store.onEventForTesting(_ev('session.execution.started', 's1'));
    expect(store.statusOf('s1').type, 'busy');
    store.onEventForTesting(_ev('session.execution.interrupted', 's1'));
    expect(store.statusOf('s1').type, 'idle');
    store.dispose();
  });
}
