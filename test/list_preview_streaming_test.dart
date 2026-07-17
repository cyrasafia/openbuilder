import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/core/connection/connection_profile.dart';
import 'package:opencode_mobile/core/net/dio_factory.dart';
import 'package:opencode_mobile/core/session/conversation_store.dart';
import 'package:opencode_mobile/core/session/server_store.dart';
import 'package:opencode_mobile/core/sse/sse_client.dart';
import 'package:opencode_mobile/data/api/opencode_client.dart';
import 'package:opencode_mobile/domain/models.dart';

// A non-null [OpencodeClient] pointing at a discard port. The preview logic
// under test never makes network calls (onPartUpdated / lastMessagePreview /
// addOptimisticUserMessage / reflectPreviewFrom are all local), so this only
// satisfies the non-null client guard in [ServerStore.ensureConversation].
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

void main() {
  // LPSI-1 (1/3): lastMessagePreview returns accumulating text mid-stream —
  // the core of the A path (server_store feeds part deltas to conv, then reads
  // lastMessagePreview for the list).
  test('lastMessagePreview tracks accumulating text during onPartUpdated', () {
    final conv = ConversationStore('s1', _fakeClient());
    const mid = 'm1';
    conv.onPartUpdated(
        <String, dynamic>{'messageID': mid, 'id': 'p1', 'type': 'text'},
        'Hello');
    expect(conv.lastMessagePreview(), 'Hello');
    conv.onPartUpdated(
        <String, dynamic>{'messageID': mid, 'id': 'p1', 'type': 'text'},
        ', world');
    expect(conv.lastMessagePreview(), 'Hello, world');
    conv.onPartUpdated(
        <String, dynamic>{'messageID': mid, 'id': 'p1', 'type': 'text'},
        '!');
    expect(conv.lastMessagePreview(), 'Hello, world!');
  });

  // LPSI-1 (2/3): reflectPreviewFrom shows optimistic preview, reverts on remove.
  test('reflectPreviewFrom shows optimistic preview and reverts on remove', () {
    final store = ServerStore()..client = _fakeClient();
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    // Seed a prior real assistant reply so the revert has something to show.
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'real', 'id': 'rp', 'type': 'text'},
        'prior reply');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'prior reply');
    // Optimistic user send -> preview becomes "你: ...".
    conv.addOptimisticUserMessage('hello there');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: hello there');
    // Send fails: remove optimistic, reflect reverts to the prior reply.
    conv.removeOptimisticMessages();
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'prior reply');
    store.dispose();
  });

  // LPSI-1 (3/3): rapid preview updates via reflectPreviewFrom are coalesced by
  // the 120ms throttle (not one notify per call). Locks _notifyPreviewChanged
  // coalescing — the mechanism break->return (LPS-1) relies on — but does NOT
  // drive the _onEvent part.updated path (reflectPreviewFrom bypasses :790).
  // The break↔return regression lock for that path is the onEventForTesting
  // test below (LPSI-1R1).
  test('reflectPreviewFrom coalesces rapid notifications via 120ms throttle', () {
    final store = ServerStore()..client = _fakeClient();
    const sid = 's1';
    store.ensureConversation(sid)!.addOptimisticUserMessage('hi');
    var count = 0;
    store.addListener(() => count++);
    // 20 rapid calls: the first notifies immediately, the rest are coalesced
    // into the trailing 120ms timer (still pending when we assert, then dispose
    // cancels it).
    for (var i = 0; i < 20; i++) {
      store.reflectPreviewFrom(sid);
    }
    expect(count, 1); // immediate first only; rest throttled
    expect(count, lessThan(20));
    store.dispose();
  });

  // LPSI-1R1: drives the REAL _onEvent message.part.updated route (via the
  // @visibleForTesting seam), so a regression of `return` back to `break`
  // (LPS-1) makes each event fall through to :790's unthrottled
  // notifyListeners → count==20 → this fails. The actual break↔return lock.
  test('part.updated events coalesce via throttle through _onEvent (locks LPS-1 break->return)', () {
    final store = ServerStore()..client = _fakeClient();
    const sid = 's1';
    // Seed a message so lastMessagePreview() is non-null (preview write happens).
    store.ensureConversation(sid)!.addOptimisticUserMessage('seed');
    var count = 0;
    store.addListener(() => count++);
    for (var i = 0; i < 20; i++) {
      store.onEventForTesting(const OpencodeEvent(
        type: 'message.part.updated',
        properties: <String, dynamic>{
          'part': <String, dynamic>{
            'sessionID': sid,
            'messageID': 'm1',
            'id': 'p1',
            'type': 'text',
          },
          'delta': 'x',
        },
      ));
    }
    // break->return (LPS-1): case returns, only _notifyPreviewChanged (throttled)
    // fires → 1 immediate notify. If regressed to break: each event hits :790
    // unthrottled → count==20 → fails.
    expect(count, 1);
    store.dispose();
  });

  // LPSI-1R2: the trailing 120ms timer emits the final state (§7/§9.1). The
  // immediate-merge test above disposes before the timer fires; this pumps past
  // the window and asserts the trailing notify + final preview content.
  testWidgets('part.updated trailing timer emits final state (LPSI-1R2)', (tester) async {
    final store = ServerStore()..client = _fakeClient();
    const sid = 's1';
    var count = 0;
    store.addListener(() => count++);
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 5; i++) {
      store.onEventForTesting(OpencodeEvent(
        type: 'message.part.updated',
        properties: <String, dynamic>{
          'part': <String, dynamic>{
            'sessionID': sid,
            'messageID': 'm1',
            'id': 'p1',
            'type': 'text',
          },
          'delta': 'seg$i',
        },
      ));
    }
    expect(count, 1); // first immediate; rest coalesced into trailing timer
    expect(store.lastMessageOf(sid), contains('seg4')); // accumulated final text
    await tester.pump(const Duration(milliseconds: 121));
    expect(count, 2); // trailing timer fired → final state reflected
    store.dispose();
  });

  // LPSI-D (§12.11, cross-clock): a server-stamped user message (created in
  // the "future" relative to the client clock, simulating client-behind-server)
  // must NOT outrank the streaming-assistant placeholder. Old code stamped the
  // placeholder with DateTime.now() (client clock) → sorted before the user →
  // _messages.last = user → lastMessagePreview() returned "你: …". D path
  // stamps max(existing created)+1 so the placeholder is always last.
  test('streaming assistant stays last against server-stamped user (D path, §1.6)', () {
    final conv = ConversationStore('s1', _fakeClient());
    final futureMs = DateTime.now().millisecondsSinceEpoch + 60000;
    conv.onMessageUpdated(MessageInfo(
      id: 'msg_u1',
      role: 'user',
      sessionID: 's1',
      created: futureMs,
    ));
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'msg_u1', 'id': 'pu1', 'type': 'text'},
        'hi');
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'msg_a1', 'id': 'pa1', 'type': 'text'},
        'world');
    expect(conv.messages.last.info.id, 'msg_a1');
    expect(conv.lastMessagePreview(), 'world'); // not '你: hi'
    conv.onMessageUpdated(MessageInfo(
      id: 'msg_a1',
      role: 'assistant',
      sessionID: 's1',
      created: futureMs + 1000,
      finish: 'stop',
    ));
    expect(conv.messages.last.info.id, 'msg_a1');
    expect(conv.lastMessagePreview(), 'world'); // no flash-back to '你: hi'
  });

  // LPSI-E (§12.12, LPS-14): when SSE events are missed (app backgrounded,
  // idle, another client sent), REST reconcile merges the new message into
  // conv._messages (detail page shows it) but did NOT bridge _lastMessage —
  // so the list preview stayed stale. E path chains _backfillPreview after
  // reconcile/load/reload completes. Without E path, conversationFor(force)
  // fires reconcile but never backfills → _lastMessage stays at the old value.
  test('reconcile.then backfills _lastMessage after merge (E path, LPS-14)', () async {
    final store = ServerStore()..client = _fakeClient();
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    // Pre-background state: an old user message + its preview seeded.
    conv.onMessageUpdated(
        MessageInfo(id: 'old', role: 'user', sessionID: sid, created: 1000));
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'old', 'id': 'po', 'type': 'text'},
        'old msg');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: old msg');
    // New message arrived while SSE was missed (simulate the post-reconcile
    // conv state — reconcile would merge this from REST).
    conv.onMessageUpdated(MessageInfo(
        id: 'new', role: 'assistant', sessionID: sid, created: 2000));
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'new', 'id': 'pn', 'type': 'text'},
        'new reply');
    // E path: conversationFor(force) chains reconcile → _backfillPreview.
    store.conversationFor(sid, force: true);
    // reconcile hits the discard port (fast ECONNREFUSED) then resolves; the
    // .then(_backfillPreview) runs and updates _lastMessage from conv's latest.
    for (var i = 0; i < 50 && store.lastMessageOf(sid) == '你: old msg'; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), 'new reply');
    store.dispose();
  });

  // LPSI-M18 (§12.13, LPS-18): mock OpencodeClient happy-path — reconcile
  // returns controlled REST messages and _backfillPreview seeds _lastMessage
  // from the merged result. Proves the happy-path E branch (reconcile succeeds)
  // actually updates the list preview, not just the .then chain mechanism.
  test('mock reconcile happy-path backfills _lastMessage (LPS-18)', () async {
    final entries = [
      MessageEntry(
        info: MessageInfo(
            id: 'rest_u1', role: 'user', sessionID: 's1', created: 1000),
        parts: [MessagePart({'type': 'text', 'id': 'pu1', 'text': 'ask'})],
      ),
      MessageEntry(
        info: MessageInfo(
            id: 'rest_a1',
            role: 'assistant',
            sessionID: 's1',
            created: 2000,
            finish: 'stop'),
        parts: [MessagePart({'type': 'text', 'id': 'pa1', 'text': 'reply'})],
      ),
    ];
    final store = ServerStore()
      ..client = _MockClient(messagesFn: (_) async => entries);
    const sid = 's1';
    // Seed stale state so conversationFor triggers load→reconcile.
    final conv = store.ensureConversation(sid)!;
    conv.onMessageUpdated(
        MessageInfo(id: 'old', role: 'user', sessionID: sid, created: 500));
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'old', 'id': 'po', 'type': 'text'},
        'stale');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: stale');
    // conversationFor(force) → reconcile (mock returns entries) → backfill.
    store.conversationFor(sid, force: true);
    for (var i = 0; i < 50 && store.lastMessageOf(sid) == '你: stale'; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), 'reply');
    store.dispose();
  });

  // LPSI-R20 (§12.14, LPS-20): retry success backfills _lastMessage. Mock
  // client throws on first call (simulating network failure), then succeeds
  // on retry. Without LPS-20 fix, _scheduleLoadRetry calls _attemptLoad()
  // without triggering _backfillCallback, so _lastMessage stays stale after retry.
  test('retry success backfills _lastMessage via _backfillCallback (LPS-20)', () async {
    var callCount = 0;
    final entries = [
      MessageEntry(
        info: MessageInfo(
            id: 'retry_a1',
            role: 'assistant',
            sessionID: 's1',
            created: 3000,
            finish: 'stop'),
        parts: [MessagePart({'type': 'text', 'id': 'ra1', 'text': 'retry reply'})],
      ),
    ];
    final store = ServerStore()
      ..client = _MockClient(messagesFn: (_) async {
        callCount++;
        if (callCount == 1) throw Exception('network error');
        return entries;
      });
    const sid = 's1';
    // Seed old preview.
    final conv = store.ensureConversation(sid)!;
    conv.onMessageUpdated(
        MessageInfo(id: 'old', role: 'user', sessionID: sid, created: 1000));
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'old', 'id': 'po', 'type': 'text'},
        'old msg');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), '你: old msg');
    // conversationFor without force → !loaded path → load() → _attemptLoad()
    // → reconcile (fails) → _scheduleLoadRetry → retry → reconcile (succeeds)
    // → _backfillCallback fires (LPS-20).
    store.conversationFor(sid);
    // Wait for retry timer (2s initial backoff) + reconcile to complete.
    for (var i = 0; i < 200 && store.lastMessageOf(sid) == '你: old msg'; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    expect(store.lastMessageOf(sid), 'retry reply');
    expect(callCount, 2); // first failed, second succeeded
    store.dispose();
  });

  // FW-3: regression test for tool-call preview revert. When conv exists but
  // lastMessagePreview() returns null (streaming assistant has no parts yet),
  // a message.updated(user) event must NOT overwrite _lastMessage with the
  // user's text. Uses _MockClient with message() returning user text — if
  // someone re-introduces the network fallback, the mock fetch succeeds,
  // overwrites _lastMessage, and this test FAILS. Poll loop lets the
  // unawaited async _onMessageUpdated complete before asserting.
  test('message.updated(user) does not revert preview when conv has no parts (FW-3)', () async {
    final store = ServerStore()
      ..client = _MockClient(
        messagesFn: (_) async => [],
        messageFn: (_, _) async => MessageEntry(
          info: const MessageInfo(
              id: 'u1', role: 'user', sessionID: 's1', created: 1000),
          parts: [MessagePart({'type': 'text', 'id': 'pu1', 'text': 'user text'})],
        ),
      );
    const sid = 's1';
    final conv = store.ensureConversation(sid)!;
    // Seed an assistant message with parts so _lastMessage has a real value.
    conv.onPartUpdated(
        <String, dynamic>{'messageID': 'a1', 'id': 'p1', 'type': 'text'},
        'assistant reply');
    store.reflectPreviewFrom(sid);
    expect(store.lastMessageOf(sid), 'assistant reply');
    // Add a new streaming assistant (finish=null, no parts) — simulates
    // the tool-call boundary where a new assistant message is created.
    conv.onMessageUpdated(MessageInfo(
        id: 'a2', role: 'assistant', sessionID: sid, created: 2000));
    // _messages.last = a2 (no parts) → lastMessagePreview() = null.
    // Push message.updated(user) via SSE route (unawaited async).
    store.onEventForTesting(const OpencodeEvent(
      type: 'message.updated',
      properties: <String, dynamic>{
        'info': <String, dynamic>{
          'id': 'u1',
          'role': 'user',
          'sessionID': sid,
          'created': 1000,
        },
      },
    ));
    // Poll: let unawaited _onMessageUpdated complete. If a fallback is
    // re-introduced, the mock returns 'user text' → _lastMessage becomes
    // '你: user text' → assertion fails (true regression).
    for (var i = 0; i < 50; i++) {
      await Future.delayed(const Duration(milliseconds: 10));
    }
    expect(store.lastMessageOf(sid), 'assistant reply');
    store.dispose();
  });
}

/// Minimal [OpencodeClient] subclass that returns controlled responses without
/// hitting the network. Used by LPS-18 / LPS-20 tests to prove the happy-path
/// and retry-success backfill logic.
class _MockClient extends OpencodeClient {
  final Future<List<MessageEntry>> Function(String sessionId) messagesFn;
  final Future<MessageEntry> Function(String sessionId, String messageId)? messageFn;
  _MockClient({required this.messagesFn, this.messageFn})
      : super(_noopDio());

  @override
  Future<List<MessageEntry>> messages(String sessionId, {int? limit}) =>
      messagesFn(sessionId);

  @override
  Future<MessageEntry> message(String sessionId, String messageId) =>
      messageFn != null
          ? messageFn!(sessionId, messageId)
          : super.message(sessionId, messageId);

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));
