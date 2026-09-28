import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

import 'v2_test_fixtures.dart';

final _zhLoc = lookupAppLocalizations(const Locale('zh'));

OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

void main() {
  test('lastMessagePreview tracks accumulating text during onTextDelta', () {
    final conv = ConversationStore('s1', _fakeClient());
    const mid = 'm1';
    conv.onStepStarted(mid);
    conv.onTextStarted(mid, 0);
    conv.onTextDelta(mid, 0, 'Hello');
    expect(conv.lastMessagePreview(), 'Hello');
    conv.onTextDelta(mid, 0, ', world');
    expect(conv.lastMessagePreview(), 'Hello, world');
    conv.onTextDelta(mid, 0, '!');
    expect(conv.lastMessagePreview(), 'Hello, world!');
  });

  test('reflectPreviewFrom shows optimistic preview and reverts on remove', () {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onStepStarted('real');
    conv.onTextDelta('real', 0, 'prior reply');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'prior reply');
    conv.addOptimisticUserMessage('hello there');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: hello there');
    conv.removeOptimisticMessages();
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'prior reply');
    store.dispose();
  });

  test('reflectPreviewFrom coalesces rapid notifications via 120ms throttle', () {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    store.ensureConversation(sid)!.addOptimisticUserMessage('hi');
    var count = 0;
    store.previewVersion.addListener(() => count++);
    for (var i = 0; i < 20; i++) {
      store.reflectPreviewFrom(sid);
    }
    expect(count, 1);
    expect(count, lessThan(20));
    store.dispose();
  });

  test('text.delta events coalesce via throttle through _onEvent (locks LPS-1 return)', () {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    store.ensureConversation(sid)!.addOptimisticUserMessage('seed');
    var count = 0;
    var globalCount = 0;
    store.previewVersion.addListener(() => count++);
    store.addListener(() => globalCount++);
    for (var i = 0; i < 20; i++) {
      store.onEventForTesting(OpencodeEvent(
        type: 'session.text.delta',
        properties: <String, dynamic>{
          'sessionID': sid,
          'assistantMessageID': 'm1',
          'ordinal': 0,
          'delta': 'x',
        },
      ));
    }
    expect(count, 1);
    expect(globalCount, 0);
    store.dispose();
  });

  testWidgets('text.delta trailing timer emits final state', (tester) async {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    var count = 0;
    store.previewVersion.addListener(() => count++);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      store.onEventForTesting(OpencodeEvent(
        type: 'session.text.delta',
        properties: <String, dynamic>{
          'sessionID': sid,
          'assistantMessageID': 'm1',
          'ordinal': 0,
          'delta': 'seg$i',
        },
      ));
    }
    expect(count, 1);
    expect(store.lastMessageOf(sid), contains('seg4'));
    await tester.pump(const Duration(milliseconds: 121));
    expect(count, 2);
    store.dispose();
  });

  test('streaming assistant stays last against server-stamped user (D path)', () {
    final conv = ConversationStore('s1', _fakeClient());
    final futureMs = DateTime.now().millisecondsSinceEpoch + 60000;
    conv.onUserMessageArrived(userMsg(id: 'msg_u1', text: 'hi', created: futureMs));
    conv.onStepStarted('msg_a1');
    conv.onTextDelta('msg_a1', 0, 'world');
    expect(conv.messages.last.id, 'msg_a1');
    expect(conv.lastMessagePreview(), 'world');
    conv.onStepEnded('msg_a1', finish: 'stop');
    expect(conv.messages.last.id, 'msg_a1');
    expect(conv.lastMessagePreview(), 'world');
  });

  test('reconcile.then backfills _lastMessage after merge (E path, LPS-14)', () async {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onUserMessageArrived(userMsg(id: 'old', text: 'old msg', created: 1000));
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: old msg');
    conv.onStepStarted('new');
    conv.onTextDelta('new', 0, 'new reply');
    store.conversationFor(sid, force: true);
    for (var i = 0; i < 50 && store.lastMessageOf(sid) == '你: old msg'; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), 'new reply');
    store.dispose();
  });

  test('mock reconcile happy-path backfills _lastMessage (LPS-18)', () async {
    final entries = [
      userMsg(id: 'rest_u1', text: 'ask', created: 1000),
      assistantMsg(
        id: 'rest_a1',
        created: 2000,
        content: [textPart('reply')],
        finish: 'stop',
      ),
    ];
    final store = ServerStore()
      ..client = _MockClient(messagesFn: (_) async => entries)
      ..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onUserMessageArrived(userMsg(id: 'old', text: 'stale', created: 500));
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: stale');
    store.conversationFor(sid, force: true);
    for (var i = 0; i < 50 && store.lastMessageOf(sid) == '你: stale'; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), 'reply');
    store.dispose();
  });

  test('retry success backfills _lastMessage via _backfillCallback (LPS-20)', () async {
    var callCount = 0;
    final entries = [
      assistantMsg(
        id: 'retry_a1',
        created: 3000,
        content: [textPart('retry reply')],
        finish: 'stop',
      ),
    ];
    final store = ServerStore()
      ..client = _MockClient(messagesFn: (_) async {
        callCount++;
        if (callCount == 1) throw Exception('network error');
        return entries;
      })
      ..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onUserMessageArrived(userMsg(id: 'old', text: 'old msg', created: 1000));
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: old msg');
    store.conversationFor(sid);
    for (var i = 0; i < 200 && store.lastMessageOf(sid) == '你: old msg'; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(store.lastMessageOf(sid), 'retry reply');
    expect(callCount, 2);
    store.dispose();
  });

  test('inbox.enqueued(user) updates preview to the user text (FW-3 v2)', () async {
    final store = ServerStore()
      ..client = _MockClient(messagesFn: (_) async => [])
      ..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onStepStarted('a1');
    conv.onTextDelta('a1', 0, 'assistant reply');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'assistant reply');
    store.onEventForTesting(OpencodeEvent(
      type: 'session.inbox.enqueued',
      properties: <String, dynamic>{
        'sessionID': sid,
        'inboxID': 'u1',
        'item': <String, dynamic>{
          'type': 'user',
          'payload': <String, dynamic>{'text': 'user text'},
        },
      },
    ));
    for (var i = 0; i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), '你: user text');
    store.dispose();
  });

  test('reasoningVisibleInPreview toggle hides reasoning from list preview', () {
    final store = ServerStore()..client = _fakeClient()..activeLoc = _zhLoc;
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    conv.onStepStarted('m1');
    conv.onTextDelta('m1', 0, 'final answer');
    conv.onReasoningStarted('m1', 0);
    conv.onReasoningDelta('m1', 0, 'thinking');
    store.reasoningVisibleInPreview = true;
    expect(store.lastMessageOf(sid), 'thinking');
    store.reasoningVisibleInPreview = false;
    expect(store.lastMessageOf(sid), 'final answer');
    store.dispose();
  });
}

class _MockClient extends OpencodeClient {
  final Future<List<SessionMessage>> Function(String sessionId) messagesFn;
  _MockClient({required this.messagesFn})
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    if (cursor != null) return const MessagesPage([], null, null);
    final entries = await messagesFn(sessionId);
    return MessagesPage(entries, null, null);
  }
}
