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

  static final ThemeData dark = _base(
    ColorScheme.fromSeed(
      seedColor: const Color(0xFF4ADE80),
      brightness: Brightness.dark,
    ),
    const Color(0xFF0E0F12),
  );

  static final ThemeData light = _base(
    ColorScheme.fromSeed(
      seedColor: const Color(0xFF16A34A),
      brightness: Brightness.light,
    ),
    const Color(0xFFF7F8FA),
  );

  static ThemeData _base(ColorScheme scheme, Color scaffold) {
    final variations = _weightVariations;
    final hasVariations = variations != null && variations.isNotEmpty;

    // Only set a custom textTheme when we have font variations to inject.
    // Otherwise, let ThemeData auto-derive colors from colorScheme (correct
    // for both light/dark). Using Typography.black unconditionally would
    // give dark theme dark-on-dark text (FW-1).
    TextTheme? textTheme;
    if (hasVariations) {
      // Pick the correct base: .black for light, .white for dark.
      final base = scheme.brightness == Brightness.dark
          ? Typography.material2021().white
          : Typography.material2021().black;
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
    }

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: textTheme,
      extensions: [
        scheme.brightness == Brightness.dark
            ? AppColors.dark
            : AppColors.light,
      ],
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
            fontWeight: FontWeight.w400,
            fontVariations: hasVariations ? variations : null,
          ),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: scheme.brightness == Brightness.dark
            ? const Color(0xFF23272E)
            : null,
        contentTextStyle: scheme.brightness == Brightness.dark
            ? TextStyle(
                color: const Color(0xFFE6EDF3),
                fontVariations: hasVariations ? variations : null,
              )
            : null,
      ),
    );
  }
}

class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.code,
    required this.link,
    required this.codeBackground,
    required this.border,
    required this.quoteBar,
  });

  final Color code;
  final Color link;
  final Color codeBackground;
  final Color border;
  final Color quoteBar;

  static const dark = AppColors(
    code: Color(0xFFEC407A),
    link: Color(0xFF2196F3),
    codeBackground: Color(0xFF161B22),
    border: Color(0xFF30363D),
    quoteBar: Color(0xFF6E7681),
  );

  static const light = AppColors(
    code: Color(0xFFC2185B),
    link: Color(0xFF2196F3),
    codeBackground: Color(0xFFF0F2F5),
    border: Color(0xFFDADDE3),
    quoteBar: Color(0xFF8C959F),
  );

  @override
  AppColors copyWith({
    Color? code,
    Color? link,
    Color? codeBackground,
    Color? border,
    Color? quoteBar,
  }) =>
      AppColors(
        code: code ?? this.code,
        link: link ?? this.link,
        codeBackground: codeBackground ?? this.codeBackground,
        border: border ?? this.border,
        quoteBar: quoteBar ?? this.quoteBar,
      );

  @override
  AppColors lerp(AppColors? other, double t) {
    if (other == null) return this;
    return AppColors(
      code: Color.lerp(code, other.code, t)!,
      link: Color.lerp(link, other.link, t)!,
      codeBackground: Color.lerp(codeBackground, other.codeBackground, t)!,
      border: Color.lerp(border, other.border, t)!,
      quoteBar: Color.lerp(quoteBar, other.quoteBar, t)!,
    );
  }
}
