import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression lock for the back-to-turn-top button never appearing.
///
/// Root cause (pre-fix): `_heightCache` was populated ONLY via
/// `SizeChangedLayoutNotification`, but the framework does NOT dispatch that
/// notification for the INITIAL layout (`_RenderSizeChangedWithCallback`
/// skips `_oldSize == null`). A static conversation's messages never change
/// size after first layout, so no height ever landed in the cache, the
/// run-top sum always saw a `gap`, and the button's target was never computed.
///
/// The fix reads each mounted message's real height directly in
/// `_evaluateFrame`. This test pumps the real [ConversationScreen] with a
/// single long assistant run pinned at the bottom: the viewport is fully
/// covered by the run and the run top is scrolled out above, so the button
/// must be visible. Without the fix the height cache stays empty and the
/// button stays hidden (opacity 0 / IgnorePointer ignoring).
class _MockClient extends OpencodeClient {
  final List<MessageEntry> entries;
  _MockClient(this.entries) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? before,
  }) async =>
      MessagesPage(entries, null);

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

Future<void> _pumpConversation(
  WidgetTester tester, {
  required String sessionId,
  required List<MessageEntry> entries,
}) async {
  SharedPreferences.setMockInitialValues({});
  serverStore.client = _MockClient(entries);
  final router = GoRouter(
    initialLocation: '/session/$sessionId',
    routes: [
      GoRoute(
        path: '/session/:id',
        builder: (_, s) =>
            ConversationScreen(sessionId: s.pathParameters['id']!),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

/// Pump frames until [probe] is satisfied (async reconcile must finish and the
/// message list must lay out before `_evaluateFrame` can compute the target).
Future<void> _settle(
  WidgetTester tester,
  bool Function() probe,
) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  // A couple extra frames so the post-frame `_evaluateFrame` writes the target
  // and the button's ValueListenableBuilder rebuilds.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

({double opacity, bool ignoring}) _buttonState(WidgetTester tester) {
  final icon = find.byIcon(Icons.vertical_align_top);
  expect(icon, findsOneWidget, reason: 'back-to-top button must exist in tree');
  final animatedOpacity = tester.widget<AnimatedOpacity>(
    find
        .ancestor(of: icon, matching: find.byType(AnimatedOpacity))
        .first,
  );
  final ignorePointer = tester.widget<IgnorePointer>(
    find
        .ancestor(of: icon, matching: find.byType(IgnorePointer))
        .first,
  );
  return (opacity: animatedOpacity.opacity, ignoring: ignorePointer.ignoring);
}

void main() {
  testWidgets(
    'long static run pinned at bottom shows the back-to-top button',
    (tester) async {
      const sid = 'btt-long';
      // One user question + one very long assistant reply (newest). The reply
      // renders several screens tall, so at pixels==0 (pinned to bottom) the
      // viewport is entirely inside that run and the run top is out of view.
      final longText = List.generate(
        80,
        (i) => 'line $i of the long assistant reply',
      ).join('\n\n');
      final entries = [
        MessageEntry(
          info: MessageInfo(
            id: 'u1',
            role: 'user',
            sessionID: sid,
            created: 1000,
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pu1', 'text': 'question'}),
          ],
        ),
        MessageEntry(
          info: MessageInfo(
            id: 'a1',
            role: 'assistant',
            sessionID: sid,
            created: 2000,
            finish: 'stop',
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pa1', 'text': longText}),
          ],
        ),
      ];
      await _pumpConversation(tester, sessionId: sid, entries: entries);
      await _settle(
        tester,
        () => find.textContaining('line 79').evaluate().isNotEmpty,
      );

      final s = _buttonState(tester);
      expect(
        s.opacity,
        1.0,
        reason: 'button must be visible when a long run fills the viewport '
            'and its top is out of view (height cache must be populated)',
      );
      expect(s.ignoring, isFalse, reason: 'visible button must be tappable');
    },
  );

  testWidgets(
    'short conversation keeps the back-to-top button hidden',
    (tester) async {
      const sid = 'btt-short';
      // A short reply that fits within the viewport: no run top to return to,
      // so the button must stay hidden. Guards against an over-eager fix that
      // shows the button regardless of the >=2-screen / top-out conditions.
      final entries = [
        MessageEntry(
          info: MessageInfo(
            id: 'u1',
            role: 'user',
            sessionID: sid,
            created: 1000,
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pu1', 'text': 'question'}),
          ],
        ),
        MessageEntry(
          info: MessageInfo(
            id: 'a1',
            role: 'assistant',
            sessionID: sid,
            created: 2000,
            finish: 'stop',
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pa1', 'text': 'short reply'}),
          ],
        ),
      ];
      await _pumpConversation(tester, sessionId: sid, entries: entries);
      await _settle(
        tester,
        () => find.textContaining('short reply').evaluate().isNotEmpty,
      );

      final s = _buttonState(tester);
      expect(s.opacity, 0.0, reason: 'short run must not show the button');
      expect(s.ignoring, isTrue, reason: 'hidden button must not be tappable');
    },
  );
}
