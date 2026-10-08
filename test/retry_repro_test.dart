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

OpencodeEvent _ev(String type, String sid, [Map<String, dynamic>? props]) =>
    OpencodeEvent(type: type, properties: {
      'sessionID': sid,
      ...?props,
    });

void main() {
  test('retry backoff shows bubble only; restart falls back to busy', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    const mid = 'msg_retry_1';
    final model = {'id': 'm1', 'providerID': 'p'};

    store.onEventForTesting(_ev('session.execution.started', 's1'));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
      'assistantMessageID': mid,
      'attempt': 2,
      'error': {'message': 'ECONNRESET: socket closed.'},
    }));

    final msg = conv.messages.firstWhere((m) => m.id == mid);
    expect(store.statusOf('s1').type, 'retry');
    expect(conv.retryMessage, 'ECONNRESET: socket closed.');
    expect(msg.error, isNull,
        reason: 'retry errors render in the bubble, not the message banner');

    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));

    expect(store.statusOf('s1').type, 'busy',
        reason: 'retry restart returns to running');
    expect(conv.status, 'busy');
    expect(conv.retryMessage, isNull, reason: 'retry bubble removed');
    conv.dispose();
    store.dispose();
  });

  test('replay live retry-success sequence settles fully', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    const mid = 'msg_retry_1';
    final model = {'id': 'm1', 'providerID': 'p'};

    store.onEventForTesting(_ev('session.execution.started', 's1'));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
      'assistantMessageID': mid,
      'attempt': 2,
      'error': {'message': 'ECONNRESET: socket closed.'},
    }));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    store.onEventForTesting(_ev(
        'session.text.started', 's1', {'assistantMessageID': mid, 'ordinal': 0}));
    store.onEventForTesting(_ev('session.text.delta', 's1',
        {'assistantMessageID': mid, 'ordinal': 0, 'delta': 'retry ok'}));
    store.onEventForTesting(_ev('session.text.ended', 's1',
        {'assistantMessageID': mid, 'ordinal': 0, 'text': 'retry ok'}));
    store.onEventForTesting(_ev('session.step.ended', 's1',
        {'assistantMessageID': mid, 'finish': 'stop'}));
    store.onEventForTesting(_ev('session.execution.succeeded', 's1'));

    final msg = conv.messages.firstWhere((m) => m.id == mid);
    expect(store.statusOf('s1').type, 'idle');
    expect(conv.status, 'idle');
    expect(conv.retryMessage, isNull);
    expect(msg.finish, 'stop');
    expect(msg.error, isNull,
        reason: 'no residue after a successful retry');
    conv.dispose();
    store.dispose();
  });

  test('consecutive retry attempts keep the latest bubble message', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    const mid = 'msg_retry_2';
    final model = {'id': 'm1', 'providerID': 'p'};

    store.onEventForTesting(_ev('session.execution.started', 's1'));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
      'assistantMessageID': mid,
      'attempt': 2,
      'error': {'message': 'first failure'},
    }));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
      'assistantMessageID': mid,
      'attempt': 3,
      'error': {'message': 'second failure'},
    }));

    expect(conv.retryMessage, 'second failure');
    expect(conv.messages.firstWhere((m) => m.id == mid).error, isNull);
    conv.dispose();
    store.dispose();
  });

  test('replay retry-exhausted sequence ends idle with terminal error', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('s1'));
    final conv = ConversationStore('s1', _fakeClient());
    store.injectConversationForTesting('s1', conv);
    const mid = 'msg_retry_3';
    final model = {'id': 'm1', 'providerID': 'p'};

    store.onEventForTesting(_ev('session.execution.started', 's1'));
    store.onEventForTesting(_ev('session.step.started', 's1',
        {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    for (var attempt = 2; attempt <= 10; attempt++) {
      store.onEventForTesting(_ev('session.retry.scheduled', 's1', {
        'assistantMessageID': mid,
        'attempt': attempt,
        'error': {'message': 'Upstream request failed (503).'},
      }));
      store.onEventForTesting(_ev('session.step.started', 's1',
          {'assistantMessageID': mid, 'model': model, 'agent': 'build'}));
    }
    store.onEventForTesting(_ev('session.step.failed', 's1', {
      'assistantMessageID': mid,
      'error': {'message': 'Upstream request failed (503), attempts exhausted.'},
    }));
    store.onEventForTesting(_ev('session.execution.failed', 's1'));

    final msg = conv.messages.firstWhere((m) => m.id == mid);
    expect(store.statusOf('s1').type, 'idle');
    expect(conv.status, 'idle');
    expect(conv.retryMessage, isNull);
    expect(msg.error?['message'],
        'Upstream request failed (503), attempts exhausted.',
        reason: 'terminal failure legitimately keeps the error banner');
    conv.dispose();
    store.dispose();
  });
}
