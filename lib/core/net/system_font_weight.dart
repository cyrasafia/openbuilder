import 'dart:io';
import 'dart:ui' show FontVariation;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// Reads the system font weight setting (Android only).
///
/// Flutter's Skia text rendering bypasses Android's font system, so system
/// font weight settings (e.g. Xiaomi/HyperOS font weight slider) don't affect
/// Flutter text. This class reads the setting via a platform channel and
/// exposes it as a [FontVariation] that can be applied to variable fonts.
class SystemFontWeight {
  static const _channel = MethodChannel('com.openbuilder.app/font_weight');

  /// The system's font weight (100–900), or null if not available.
  /// 400 = normal, 500 = medium, 600 = semibold, 700 = bold.
  static int? _weight;
  static int? get weight => _weight;

  /// FontVariation for the 'wght' axis, or null if system weight isn't available.
  static List<FontVariation>? get variations =>
      _weight != null ? [FontVariation('wght', _weight!.toDouble())] : null;

  /// Read the system font weight. Call once at startup (e.g. in main()).
  /// On non-Android platforms or if the setting is unavailable, this is a no-op.
  static Future<void> init() async {
    if (kIsWeb || !Platform.isAndroid) {
      AppLogger.I
          .i('FontWeight', 'init skipped: kIsWeb=$kIsWeb, android=${Platform.isAndroid}');
      return;
    }
    try {
      final result = await _channel.invokeMethod<int>('getFontWeight');
      _weight = result;
      AppLogger.I.i('FontWeight',
          'system weight read = $result (variations will ${result == null ? "NOT" : ""} be applied)');
    } catch (e) {
      AppLogger.I.w('FontWeight', 'init failed: $e');
    }
  }
}
