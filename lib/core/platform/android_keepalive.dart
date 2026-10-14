import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

class AndroidKeepalive {
  static const _channel = MethodChannel('com.openbuilder.app/keepalive');
  static const _tag = 'Keepalive';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static Future<void> start(int count) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('start', {'count': count});
      AppLogger.I.i(_tag, 'fgs start count=$count');
    } on PlatformException catch (e) {
      AppLogger.I.w(_tag, 'fgs start failed: ${e.code}');
      rethrow;
    } on MissingPluginException {
      AppLogger.I.w(_tag, 'fgs channel missing');
      rethrow;
    }
  }

  static Future<void> updateCount(int count) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('updateCount', {'count': count});
    } on PlatformException catch (e) {
      AppLogger.I.w(_tag, 'fgs updateCount failed: ${e.code}');
    } on MissingPluginException {
      AppLogger.I.w(_tag, 'fgs channel missing');
    }
  }

  static Future<void> stop() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('stop');
      AppLogger.I.i(_tag, 'fgs stop');
    } on PlatformException catch (e) {
      AppLogger.I.w(_tag, 'fgs stop failed: ${e.code}');
    } on MissingPluginException {
      AppLogger.I.w(_tag, 'fgs channel missing');
    }
  }
}
