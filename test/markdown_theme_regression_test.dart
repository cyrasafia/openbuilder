import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/ui/theme.dart';

// Regression test for the gray conversation-detail screen.
//
// flutter_markdown's MarkdownStyleSheet.fromTheme asserts
// `theme.textTheme.bodyMedium?.fontSize != null` (style_sheet.dart:102) and in
// release does `bodyMedium.fontSize! * 0.85` (line 110) — a null fontSize
// throws NullCheckOperator → ErrorWidget → gray screen.
//
// The raw AppTheme.dark/light static finals keep bodyMedium.fontSize = null
// (unresolved inherit:true), while MaterialApp-localized Theme.of(context)
// resolves it (e.g. 14.0). Commit 28c97da fed the raw AppTheme.dark into
// fromTheme for user messages / dark mode, crashing every conversation that
// contained a user message (or any conversation in dark theme).

void main() {
  testWidgets(
      'MarkdownStyleSheet.fromTheme(Theme.of(context)) has non-null bodyMedium fontSize',
      (tester) async {
    double? bodyFontSize;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Builder(builder: (context) {
        bodyFontSize =
            Theme.of(context).textTheme.bodyMedium?.fontSize;
        return const SizedBox();
      }),
    ));
    await tester.pump();
    expect(bodyFontSize, isNotNull,
        reason: 'MaterialApp must localize the theme so bodyMedium has fontSize');
    expect(bodyFontSize, 14.0);
  });

  testWidgets('fromTheme(Theme.of(context)) builds without asserting', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      home: Builder(builder: (context) {
        // This is what the conversation screen now does. Must not throw.
        final sheet = MarkdownStyleSheet.fromTheme(Theme.of(context));
        expect(sheet.p?.fontSize, isNotNull);
        expect(sheet.code?.fontSize, isNotNull);
        return const SizedBox();
      }),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  test('raw AppTheme.dark bodyMedium.fontSize is null (documents the trap)', () {
    // Feeding the raw static-final theme to fromTheme is what crashed.
    expect(AppTheme.dark.textTheme.bodyMedium?.fontSize, isNull);
    expect(AppTheme.light.textTheme.bodyMedium?.fontSize, isNull);
  });
}
