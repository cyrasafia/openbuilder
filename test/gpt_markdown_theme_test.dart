import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:open_builder/ui/theme.dart';

void main() {
  test('AppTheme installs GptMarkdownThemeData for light and dark', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final data = theme.extension<GptMarkdownThemeData>();
      expect(data, isNotNull);
      expect(data!.autoAddDividerLineAfterH1, isFalse);
      expect(data.styleSheet.blockSpacing, 6);
      expect(data.styleSheet.heading?.textStyle?.fontWeight, FontWeight.w600);
      expect(data.h1?.fontSize, isNotNull);
      expect(data.h2?.fontSize, isNotNull);
      expect(data.h3?.fontSize, isNotNull);
      expect(data.h4?.fontSize, isNotNull);
      expect(data.h5?.fontSize, isNotNull);
      expect(data.h6?.fontSize, isNotNull);
    }
  });

  test('conversation gpt style maps AppColors to component styles', () {
    final dark = buildConversationGptStyle(
      scheme: AppTheme.dark.colorScheme,
      colors: AppColors.dark,
    );
    expect(dark.blockQuote?.barColor, AppColors.dark.quoteBar);
    expect(dark.link?.color, AppColors.dark.link);
    expect(dark.inlineCode?.backgroundColor, Colors.transparent);
    expect(dark.codeBlock?.backgroundColor, AppColors.dark.codeBackground);
    expect(dark.table?.borderColor, AppColors.dark.border);
    expect(dark.hr?.color, AppColors.dark.border);

    final light = buildConversationGptStyle(
      scheme: AppTheme.light.colorScheme,
      colors: AppColors.light,
    );
    expect(light.blockQuote?.barColor, AppColors.light.quoteBar);
    expect(light.link?.color, AppColors.light.link);
    expect(light.codeBlock?.backgroundColor, AppColors.light.codeBackground);
    expect(light.table?.borderColor, AppColors.light.border);
  });
}
