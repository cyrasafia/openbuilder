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

import 'v2_test_fixtures.dart';

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
  final List<SessionMessage> entries;
  _MockClient(this.entries) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async =>
      MessagesPage(entries, null, null);
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
  required List<SessionMessage> entries,
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

SessionMessage _user(String sid, String id, String text, int created) =>
    userMsg(id: id, text: text, created: created);

SessionMessage _assistant(String sid, String id, String text, int created) =>
    assistantMsg(
      id: id,
      created: created,
      content: [textPart(text)],
      finish: 'stop',
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
      // is not a toggle target while expanded. The gradient indicator floats
      // at the bubble's bottom-center, mirroring the collapsed affordance
      // position — on a tall expanded bubble that is below the fold, so
      // scroll it into view first.
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      await tester.ensureVisible(expandLess);
      await tester.pump();
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

  // _HScrollForwarder 焦点守卫：正文获焦（长按选词/点正文）后 SDK 横向扩选
  // 激活，转发会与扩选叠加——获焦期间不转发；toggle 回调 unfocus 后恢复。
  testWidgets(
    'code-block horizontal forwarding yields while text is focused and '
    'resumes after toggle unfocus',
    (tester) async {
      const sid = 'uc-code-focus';
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
      double codePixels() =>
          tester.widget<SingleChildScrollView>(svFinder).controller!.position
              .pixels;

      // Focus the text body by long-pressing the first paragraph (not the
      // code block): the selection toolbar appears and primary focus moves
      // into the bubble.
      final firstText = find
          .descendant(of: host, matching: find.byType(SelectableText))
          .first;
      await tester.longPressAt(
        tester.getTopLeft(firstText) + const Offset(30, 10),
      );
      await tester.pumpAndSettle();
      expect(codePixels(), 0.0);

      // While focused, a horizontal drag over the code text must NOT be
      // forwarded (SDK drag-selection owns it).
      var gesture = await tester.startGesture(
        tester.getTopLeft(svFinder) + const Offset(40, 20),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        codePixels(),
        0.0,
        reason: 'forwarding must yield while the text body holds focus',
      );

      // Tapping the text body toggles expand and unfocuses (toggle callback),
      // so focus leaves the bubble and forwarding must resume.
      await tester.tapAt(tester.getCenter(firstText));
      await tester.pumpAndSettle();
      final focus = FocusManager.instance.primaryFocus;
      var focusInBubble = false;
      focus?.context?.visitAncestorElements((ancestor) {
        if (ancestor == host.evaluate().single) {
          focusInBubble = true;
          return false;
        }
        return true;
      });
      expect(focusInBubble, isFalse, reason: 'toggle must unfocus the body');

      gesture = await tester.startGesture(
        tester.getTopLeft(svFinder) + const Offset(40, 20),
      );
      for (var i = 0; i < 8; i++) {
        await gesture.moveBy(const Offset(-30, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(
        codePixels(),
        greaterThan(0.0),
        reason: 'forwarding must resume once focus leaves the bubble',
      );
    },
  );

  // ExcludeFocus 已移除（2026-10-10）：它使 SelectableText 永不可获焦，SDK
  // 在无焦点时每次 controller 变更都会 dispose 整个 selection overlay——
  // 工具栏上按「全选」后菜单直接消失。放弃「点气泡不弹键盘」换取选中
  // 交互正常：点正文会获焦（键盘收起，可接受）。
  testWidgets(
    'tapping the text body focuses the text and select-all keeps the toolbar',
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

      // Long-press a word while still collapsed, then press Select all on
      // the toolbar: the toolbar must survive the controller change.
      final firstText = find
          .descendant(of: host, matching: find.byType(SelectableText))
          .first;
      await tester.longPressAt(
        tester.getTopLeft(firstText) + const Offset(30, 10),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AdaptiveTextSelectionToolbar), findsOneWidget);

      // The long-press path requests keyboard, which must actually focus the
      // text now (ExcludeFocus removed) — this is what keeps the overlay
      // alive through controller changes below.
      final focus = FocusManager.instance.primaryFocus;
      expect(focus, isNotNull);
      var insideBubble = false;
      focus!.context!.visitAncestorElements((ancestor) {
        if (ancestor == host.evaluate().single) {
          insideBubble = true;
          return false;
        }
        return true;
      });
      expect(insideBubble, isTrue, reason: 'text body must be focusable');

      await tester.tap(find.text('Select all').first);
      await tester.pumpAndSettle();
      expect(
        find.byType(AdaptiveTextSelectionToolbar),
        findsOneWidget,
        reason: 'select-all is a controller change; with focus the overlay '
            'must be updated, not disposed',
      );
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

  // 折叠盒按自然高度布局 child、仅 clamp 自身尺寸：裁切线以下的段落保有
  // 真实布局坐标。Android 拖选 handle 时 SDK 按 drag cause 对选区端点调
  // bringIntoView→showOnScreen，外层列表会为这段「布局存在但视觉不可见」
  // 的几何大幅跳滚（实测单次数百 px），handle 拖动被打断。_TopClampBox
  // 需把 child 的 reveal 矩形截进盒子可见区后再向上传播。
  testWidgets(
    'collapsed: drag selection below the clamp line does not jump the list',
    (tester) async {
      const sid = 'uc-reveal-clamp';
      final longText = List.generate(
        40,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _assistant(
            sid,
            'a3',
            List.generate(8, (i) => 'older reply $i').join('\n\n'),
            1000,
          ),
          _user(sid, 'u1', longText, 2000),
          _assistant(
            sid,
            'a1',
            List.generate(20, (i) => 'newer reply $i').join('\n\n'),
            3000,
          ),
          _assistant(sid, 'a2', 'end', 3001),
        ],
      );
      final host = find.byKey(const ValueKey('uc:u1'));

      // Scroll toward older messages until the collapsed bubble is in view
      // with scroll room left below it (toward newer messages), so a reveal
      // jump would have space to happen.
      final listFinder = find.byType(Scrollable).first;
      await _settle(
        tester,
        () => find.byType(Scrollable).evaluate().isNotEmpty,
      );
      for (var i = 0; i < 30 && host.evaluate().isEmpty; i++) {
        await tester.drag(listFinder, const Offset(0, 300));
        await tester.pumpAndSettle();
      }
      await _waitCollapsed(tester, host);

      // One EditableText per markdown paragraph; pick the deepest one — its
      // layout position sits far below the clamp line, invisible.
      final paragraphs = find
          .descendant(of: host, matching: find.byType(EditableText))
          .evaluate()
          .map((e) => (e as StatefulElement).state as EditableTextState)
          .toList()
        ..sort((a, b) => a.renderEditable
            .localToGlobal(Offset.zero)
            .dy
            .compareTo(b.renderEditable.localToGlobal(Offset.zero).dy));
      final deep = paragraphs.last;
      final deepTop = deep.renderEditable.localToGlobal(Offset.zero);
      expect(deepTop.dy, greaterThan(600), reason: 'deepest paragraph is off-screen');

      final scroll = tester.state<ScrollableState>(listFinder);
      final before = scroll.position.pixels;
      deep.renderEditable.selectPositionAt(
        from: deepTop + const Offset(60, 10),
        to: deepTop + const Offset(60, 30),
        cause: SelectionChangedCause.drag,
      );
      await tester.pumpAndSettle();
      expect(
        (scroll.position.pixels - before).abs(),
        lessThan(1.0),
        reason: 'reveal requests for clipped-off geometry must not scroll '
            'the conversation list',
      );
    },
  );

  // 展开目标含底部留白（气泡 + 44 外壳延伸）：过渡动画分支的 _TopClampBox
  // child 必须同样含留白（_UserExpandBase），否则 clamp 上限 = 气泡自然高，
  // 动画末端停滞后在 t>=1 分支切换帧 +44 单帧跳变（评审实测捕获）。
  testWidgets(
    'expand animation grows continuously into the extended height',
    (tester) async {
      const sid = 'uc-anim-cont';
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

      await tester.tap(host);
      await tester.pump();
      final heights = <double>[];
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 8));
        if (host.evaluate().isNotEmpty) {
          heights.add(tester.getSize(host).height);
        }
      }
      await tester.pumpAndSettle();
      final settled = tester.getSize(host).height;
      expect(heights, isNotEmpty);

      for (var i = 1; i < heights.length; i++) {
        expect(
          heights[i],
          greaterThanOrEqualTo(heights[i - 1]),
          reason: 'expansion heights must be monotonically non-decreasing '
              '(frame $i: ${heights[i - 1]} -> ${heights[i]})',
        );
      }
      var prev = settled;
      for (final h in heights.reversed) {
        if (h < settled) {
          prev = h;
          break;
        }
      }
      expect(
        settled - prev,
        lessThan(24.0),
        reason: 'the bottom extension must animate in frame-by-frame, not '
            'land as a single-frame +44 jump at the t>=1 branch switch '
            '(prev=$prev, settled=$settled)',
      );
    },
  );
}
