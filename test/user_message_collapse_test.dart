import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// User-message collapse: a user message whose natural height exceeds
/// screen-height × 0.4 (test surface 800×600 → 240px, plus a 24px minimum
/// gain) renders collapsed by default — clamped to 240px with an expand
/// affordance — and tapping toggles expand/collapse. Short messages get no
/// affordance at all.
///
/// 二期：折叠裁切保留气泡底圆角（ClipRRect bottom 14）；整个气泡可点
/// （类 tool chip）切换折叠/展开；切换带高度动画（中间高度严格介于 clamp
/// 与自然高度之间）。
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

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// The collapse host mounts a few frames after the conversation loads; guard
/// the initial settle against the not-yet-mounted host.
Future<void> _waitCollapsed(WidgetTester tester, Finder host) =>
    _settle(tester, () {
      if (host.evaluate().isEmpty) return false;
      return tester.getSize(host).height == 240.0;
    });

MessageEntry _user(String sid, String id, String text, int created) =>
    MessageEntry(
      info: MessageInfo(id: id, role: 'user', sessionID: sid, created: created),
      parts: [MessagePart({'type': 'text', 'id': 'p$id', 'text': text})],
    );

MessageEntry _assistant(String sid, String id, String text, int created) =>
    MessageEntry(
      info: MessageInfo(
        id: id,
        role: 'assistant',
        sessionID: sid,
        created: created,
        finish: 'stop',
      ),
      parts: [MessagePart({'type': 'text', 'id': 'p$id', 'text': text})],
    );

void main() {
  testWidgets(
    'tall user message is collapsed by default and toggles on tap',
    (tester) async {
      const sid = 'uc-tall';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );

      final host = find.byKey(const ValueKey('uc:u1'));
      // The app bar's agent/model chips also carry expand_more icons — scope
      // every affordance lookup to the collapse host.
      final expandMore = find.descendant(
        of: host,
        matching: find.byIcon(Icons.expand_more),
      );
      final expandLess = find.descendant(
        of: host,
        matching: find.byIcon(Icons.expand_less),
      );
      // The collapsed bubble must keep its bottom rounded corners: the clip
      // is a bottom-only 14px ClipRRect (markdown may add its own clips, so
      // match on the specific border geometry, not the widget type).
      bool hasBottomRoundedClip() => find
          .descendant(of: host, matching: find.byType(ClipRRect))
          .evaluate()
          .any((e) {
            final w = e.widget as ClipRRect;
            final r = w.borderRadius;
            return r is BorderRadius &&
                r.topLeft == Radius.zero &&
                r.topRight == Radius.zero &&
                r.bottomLeft == const Radius.circular(14) &&
                r.bottomRight == const Radius.circular(14);
          });
      await _settle(tester, () {
        if (host.evaluate().isEmpty) return false;
        return tester.getSize(host).height == 240.0;
      });
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'tall user message must be clamped to 40% of the 600px '
            'screen height by default',
      );
      expect(expandMore, findsOneWidget);
      expect(hasBottomRoundedClip(), isTrue);

      // Tap anywhere on the bubble (its center — no affordance there).
      await tester.tap(host);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final midHeight = tester.getSize(host).height;
      await _settle(tester, () {
        if (expandLess.evaluate().isEmpty) return false;
        return tester.getSize(host).height > 240.0;
      });
      final fullHeight = tester.getSize(host).height;
      expect(
        fullHeight,
        greaterThan(240.0),
        reason: 'expanding must restore the natural height',
      );
      expect(
        midHeight,
        allOf(greaterThan(240.0), lessThan(fullHeight)),
        reason: 'expansion must animate through intermediate heights',
      );
      expect(hasBottomRoundedClip(), isFalse);

      // The expansion scrolls with the reveal (bubble top stays anchored), so
      // the text body — selectable markdown whose EditableText consumes taps —
      // is not a toggle target while expanded. The pill floats at the bubble's
      // top-right, which the anchoring keeps on screen.
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      await tester.tap(expandLess);
      // Mid-animation: the collapse correction must never drive pixels below
      // the min extent — collapsed content (240px bubble + short reply)
      // under-fills the 600px viewport, exactly the under-filled case where
      // an unclamped correction used to go negative and fight the physics.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(
          scroll.position.pixels,
          greaterThanOrEqualTo(scroll.position.minScrollExtent),
          reason: 'collapse correction must keep pixels in range '
              '(frame $i: ${scroll.position.pixels})',
        );
      }
      await _settle(tester, () => tester.getSize(host).height == 240.0);
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'collapsing again must clamp back to the threshold',
      );
      expect(expandMore, findsOneWidget);
      expect(hasBottomRoundedClip(), isTrue);
    },
  );

  testWidgets(
    'short user message has no collapse affordance',
    (tester) async {
      const sid = 'uc-short';
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', 'question', 1000),
          _assistant(sid, 'a1', 'short reply', 2000),
        ],
      );
      await _settle(
        tester,
        () => find.textContaining('short reply').evaluate().isNotEmpty,
      );
      // Extra frames: collapse decision is event-driven; give it a chance to
      // (incorrectly) fire before asserting the affordance stays absent.
      await tester.pump(const Duration(milliseconds: 200));

      final host = find.byKey(const ValueKey('uc:u1'));
      expect(
        find.descendant(of: host, matching: find.byIcon(Icons.expand_more)),
        findsNothing,
      );
      expect(
        find.descendant(of: host, matching: find.byIcon(Icons.expand_less)),
        findsNothing,
      );
      final heightBefore = tester.getSize(host).height;
      expect(heightBefore, lessThan(240.0));

      // A text tap on a non-collapsible message is guarded off — no toggle,
      // no affordance, no height change.
      await tester.tap(find.textContaining('question'));
      await tester.pumpAndSettle();
      expect(tester.getSize(host).height, heightBefore);
      expect(
        find.descendant(of: host, matching: find.byIcon(Icons.expand_more)),
        findsNothing,
      );
    },
  );

  // 三期：收起/展开手势行为一致——文本区 tap 经 onTapText 切换（两态皆可），
  // 链接 tap 分流不切换，长按选词 + 工具栏，代码块横向拖动转发到内部横向
  // Scrollable，正文 tap 不抢输入框焦点。

  testWidgets(
    'expanded: tapping the text body collapses (onTapText path)',
    (tester) async {
      const sid = 'uc-text-tap';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      // Expand via a text-area tap (bubble center is text, not affordance).
      await tester.tap(host);
      await _settle(tester, () => tester.getSize(host).height > 240.0);
      final expanded = tester.getSize(host).height;
      expect(expanded, greaterThan(240.0));

      // While expanded, a tap on the text body must collapse again — the
      // selectable markdown wins the tap and reports it via onTapText.
      final top = tester.getTopLeft(host);
      await tester.tapAt(top + const Offset(60, 120));
      await _settle(tester, () => tester.getSize(host).height == 240.0);
      expect(tester.getSize(host).height, 240.0);
    },
  );

  testWidgets(
    'collapsed: tapping a link opens it without expanding',
    (tester) async {
      const sid = 'uc-link-tap';
      // The link is the entire first paragraph so the paragraph's center —
      // the tap point — is guaranteed to land on the link span.
      final tail = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      final longText = '[the docs](https://example.com/x)\n\n$tail';
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      final launched = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') {
            launched.add((call.arguments as Map)['url'] as String);
            return true;
          }
          return null;
        },
      );
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        );
      });

      await tester.tap(find.textContaining('the docs'));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'a link tap must be dispatched to onTapLink, not toggle',
      );
      expect(launched, ['https://example.com/x']);
    },
  );

  testWidgets(
    'collapsed: long-press selects the word and shows the copy toolbar',
    (tester) async {
      const sid = 'uc-long-press';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      // Long press inside the first paragraph's text (its horizontal center
      // can fall past the end of a short line; bias toward the leading edge).
      final firstText = find
          .descendant(of: host, matching: find.byType(SelectableText))
          .first;
      await tester.longPressAt(
        tester.getTopLeft(firstText) + const Offset(30, 10),
      );
      await tester.pumpAndSettle();

      bool anySelection() {
        for (final e in find
            .descendant(of: host, matching: find.byType(EditableText))
            .evaluate()) {
          final el = e as StatefulElement;
          final st = el.state as EditableTextState;
          final sel = st.textEditingValue.selection;
          if (sel.isValid && !sel.isCollapsed) return true;
        }
        return false;
      }

      expect(anySelection(), isTrue, reason: 'long press must select a word');
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);
      expect(tester.getSize(host).height, 240.0);
    },
  );

  testWidgets(
    'collapsed: horizontal drag over code text scrolls the code block',
    (tester) async {
      const sid = 'uc-code-scroll';
      final code = 'int main() { return 0; } // ${'x' * 200}';
      final tail = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      final longText = 'before the code\n\n```\n$code\n```\n\n$tail';
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      final svFinder = find.descendant(
        of: host,
        matching: find.byType(SingleChildScrollView),
      );
      expect(svFinder, findsOneWidget);
      final sv = tester.widget<SingleChildScrollView>(svFinder);

      final start = tester.getTopLeft(svFinder) + const Offset(40, 20);
      final gesture = await tester.startGesture(start);
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      expect(
        sv.controller!.position.pixels,
        greaterThan(0.0),
        reason: 'horizontal drag over code text must be forwarded to the '
            'code block scrollview',
      );
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'a drag is not a tap — the bubble must stay collapsed',
      );
    },
  );

  testWidgets(
    'tapping the text body does not steal focus from the composer',
    (tester) async {
      const sid = 'uc-focus';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      final field = find.byType(TextField).first;
      await tester.tap(field);
      await tester.pumpAndSettle();
      final composerFocus = FocusManager.instance.primaryFocus;
      expect(composerFocus, isNotNull);

      await tester.tap(host);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        same(composerFocus),
        reason: 'message text is focus-excluded; the composer must keep '
            'focus (and the keyboard) when a bubble is tapped',
      );
      await _settle(tester, () => tester.getSize(host).height > 240.0);
      expect(tester.getSize(host).height, greaterThan(240.0));
    },
  );

  testWidgets(
    'vertical drag from the text body still scrolls the conversation list',
    (tester) async {
      const sid = 'uc-vscroll';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          // Newest first in the reversed list: the collapsed user bubble is
          // visible at pixels=0; the older replies make the list scrollable.
          _assistant(sid, 'a1', List.generate(8, (i) => 'older reply $i').join('\n\n'), 1000),
          _assistant(sid, 'a2', List.generate(8, (i) => 'older reply $i').join('\n\n'), 2000),
          _assistant(sid, 'a3', List.generate(8, (i) => 'older reply $i').join('\n\n'), 3000),
          _user(sid, 'u1', longText, 4000),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));
      await _waitCollapsed(tester, host);

      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scroll.position.pixels;
      final start = tester.getCenter(host);
      final gesture = await tester.startGesture(start);
      for (var i = 0; i < 6; i++) {
        await gesture.moveBy(const Offset(0, 40));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        scroll.position.pixels,
        greaterThan(before),
        reason: 'vertical drag over the text body must scroll the list',
      );
    },
  );
}
