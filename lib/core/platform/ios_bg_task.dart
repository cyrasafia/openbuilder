import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

class IosBgTask {
  static const _channel = MethodChannel('com.openbuilder.app/bg_task');
  static const _tag = 'IosBgTask';

  static int? _id;

  static Future<void> begin(String label) async {
    if (kIsWeb || !Platform.isIOS) return;
    try {
      _id = await _channel.invokeMethod<int>('begin', {'label': label});
      AppLogger.I.i(_tag, 'begin "$label" -> id=$_id');
    } on PlatformException catch (e) {
      _id = null;
      AppLogger.I.w(_tag, 'begin failed: ${e.code}');
    } on MissingPluginException {
      _id = null;
      AppLogger.I.w(_tag, 'channel missing');
    }
  }

  static Future<void> end() async {
    final id = _id;
    _id = null;
    if (id == null) return;
    try {
      await _channel.invokeMethod<void>('end', {'id': id});
      AppLogger.I.i(_tag, 'end id=$id');
    } on PlatformException catch (e) {
      AppLogger.I.w(_tag, 'end failed: ${e.code}');
    } on MissingPluginException {
      AppLogger.I.w(_tag, 'channel missing');
    }
  }
}
