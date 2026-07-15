import 'package:flutter/material.dart';

import '../core/net/system_font_weight.dart';

class AppTheme {
  AppTheme._();

  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['DejaVu Sans Mono', 'Menlo', 'Courier New'],
  );

  /// System font weight variations for variable fonts (e.g. MiSans).
  /// Applied to all text styles so the app responds to the system's font
  /// weight slider on Xiaomi/HyperOS. Returns null if the system setting
  /// isn't available.
  static List<FontVariation>? get _weightVariations =>
      SystemFontWeight.variations;

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4ADE80),
      brightness: Brightness.dark,
    );
    return _base(scheme, const Color(0xFF0E0F12));
  }

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF16A34A),
      brightness: Brightness.light,
    );
    return _base(scheme, const Color(0xFFF7F8FA));
  }

  static ThemeData _base(ColorScheme scheme, Color scaffold) {
    final variations = _weightVariations;
    final hasVariations = variations != null && variations.isNotEmpty;

    // Apply fontVariations to every text style in the default TextTheme.
    TextTheme textTheme;
    if (hasVariations) {
      final base = Typography.material2021().black;
      TextStyle? apply(TextStyle? s) =>
          s?.copyWith(fontVariations: [...(s.fontVariations ?? []), ...variations]);
      textTheme = TextTheme(
        displayLarge: apply(base.displayLarge),
        displayMedium: apply(base.displayMedium),
        displaySmall: apply(base.displaySmall),
        headlineLarge: apply(base.headlineLarge),
        headlineMedium: apply(base.headlineMedium),
        headlineSmall: apply(base.headlineSmall),
        titleLarge: apply(base.titleLarge),
        titleMedium: apply(base.titleMedium),
        titleSmall: apply(base.titleSmall),
        bodyLarge: apply(base.bodyLarge),
        bodyMedium: apply(base.bodyMedium),
        bodySmall: apply(base.bodySmall),
        labelLarge: apply(base.labelLarge),
        labelMedium: apply(base.labelMedium),
        labelSmall: apply(base.labelSmall),
      );
    } else {
      textTheme = Typography.material2021().black;
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: scaffold,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
          fontVariations: hasVariations ? variations : null,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        labelTextStyle: WidgetStateProperty.all(
          TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w500,
            fontVariations: hasVariations ? variations : null,
          ),
        ),
      ),
    );
  }
}
