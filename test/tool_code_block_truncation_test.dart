import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';

// 巨型 tool 输出（日志 dump / 目录扫描）曾以全量文本进水平滚动的 Text——
// 单行数千字符 × 全量内容让 Skia 在 native 层分配巨量排版内存，进程被
// LMK 直接杀死（无任何 Dart 错误日志）。这里锁定 toolCodeBlock 的截断：
// 超限内容只渲染前 kToolCodeMaxChars 字符 + 截断提示。

const _tailMarker = 'TAIL_MARKER_THAT_MUST_NOT_RENDER';

Future<void> _pumpBlock(WidgetTester tester, String body) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) => SingleChildScrollView(
            child: toolCodeBlock(
              context,
              body,
              Theme.of(context).extension<AppColors>()!,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('short output renders in full without truncation note',
      (tester) async {
    await _pumpBlock(tester, 'ls -la\nsrc/ docs/');
    expect(find.text('ls -la\nsrc/ docs/'), findsOneWidget);
    expect(find.textContaining('truncated'), findsNothing);
  });

  testWidgets('oversized output is capped and tail is dropped', (tester) async {
    final body =
        'L' * (kToolCodeMaxChars + 2000) + _tailMarker;
    await _pumpBlock(tester, body);

    final rendered = tester
        .widget<Text>(find.byType(Text).first)
        .data!;
    expect(rendered.length, kToolCodeMaxChars,
        reason: 'rendered text must be capped, tail dropped');
    expect(rendered.contains(_tailMarker), isFalse);
    expect(find.textContaining('chars omitted'), findsOneWidget,
        reason: 'truncation note must be visible');
  });

  testWidgets('boundary never splits a surrogate pair', (tester) async {
    final body = 'a' * (kToolCodeMaxChars - 1) + '😀${'b' * 50}';
    await _pumpBlock(tester, body);

    final rendered = tester
        .widget<Text>(find.byType(Text).first)
        .data!;
    expect(rendered.length, kToolCodeMaxChars - 1,
        reason: 'boundary lands inside the emoji — back off one code unit');
    expect(rendered.endsWith('a'), isTrue);
    expect(find.textContaining('chars omitted'), findsOneWidget);
  });

  testWidgets('trailing newline is trimmed before the cap check',
      (tester) async {
    await _pumpBlock(tester, 'ok\n');
    expect(find.text('ok'), findsOneWidget);
  });
}
