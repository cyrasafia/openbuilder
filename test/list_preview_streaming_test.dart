import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/core/connection/connection_profile.dart';
import 'package:opencode_mobile/core/net/dio_factory.dart';
import 'package:opencode_mobile/core/session/conversation_store.dart';
import 'package:opencode_mobile/core/session/server_store.dart';
import 'package:opencode_mobile/core/sse/sse_client.dart';
import 'package:opencode_mobile/data/api/opencode_client.dart';

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
}
