import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// Regression test for the detail-page message order bug.
///
/// `renderableMessages` returns newest-first (for a `reverse: true` ListView).
/// The screen must NOT apply an extra `.reversed` — that would double-reverse
/// the list, putting the OLDEST message at the visual bottom (what the user
/// calls "last message") instead of the newest.
///
/// Real-world symptom (session "会话对账改为增量对账", 256 messages):
///   - List preview showed the true last msg ("已提交 2af129d…") ✓
///   - Detail page's bottom msg was the older "现在处理 IR-9…" ✗
///   because the segment's oldest ≈ "现在处理 IR-9…" landed at the visual
///   bottom after the double-reversal.

class _MockClient extends OpencodeClient {
  _MockClient() : super(_dio());
  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    return const MessagesPage([], null, null);
  }
}

Dio _dio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

void main() {
  test('renderableMessages is newest-first (correct for reverse ListView)', () {
    final conv = ConversationStore('s1', _MockClient());
    for (var i = 1; i <= 5; i++) {
      conv.onStepStarted('m$i');
      conv.onTextDelta('m$i', 0, 'msg $i');
      conv.onStepEnded('m$i', finish: 'stop');
    }
    // No reconcile yet → _segments empty → renderableMessages = _messages.reversed.
    final r = conv.renderableMessages;
    expect(r.first.id, 'm5', reason: 'newest must be first');
    expect(r.last.id, 'm1', reason: 'oldest must be last');

    // The screen builds ListView children as:
    //   ...renderableMessages.map(_message)   // (NO extra .reversed)
    // With reverse:true, children[0] is at the visual bottom. So the FIRST
    // child (after padding/typing) = renderableMessages.first = newest →
    // newest at the bottom. Assert the contract the screen relies on:
    expect(r.first.id, 'm5');
  });

  testWidgets('reverse ListView renders newest at the bottom',
      (tester) async {
    // Verify the contract the fixed screen relies on:
    //   renderableMessages is newest-first → fed directly (no extra .reversed)
    //   into a reverse:true ListView → newest lands at the visual bottom.
    // Children mimic what the screen produces after the fix:
    //   [SizedBox(padding), TypingDots?, newest, mid, oldest, loadingEarlier?]
    final children = ['newest', 'mid', 'oldest']; // newest-first
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(
          reverse: true,
          children: [
            const SizedBox(height: 8),
            ...children.map((s) => Text(s, textDirection: TextDirection.ltr)),
          ],
        ),
      ),
    ));
    final newestRect = tester.getRect(find.text('newest'));
    final oldestRect = tester.getRect(find.text('oldest'));
    expect(newestRect.bottom > oldestRect.bottom, isTrue,
        reason: 'newest-first children in reverse ListView → newest at bottom');
  });
}
