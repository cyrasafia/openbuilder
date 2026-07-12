import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['DejaVu Sans Mono', 'Menlo', 'Courier New'],
  );

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

  static ThemeData _base(ColorScheme scheme, Color scaffold) => ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scaffold,
        appBarTheme: AppBarTheme(
          backgroundColor: scaffold,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: scheme.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        navigationBarTheme: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.all(
            const TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
        ),
      );
}
