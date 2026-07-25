import 'dart:convert';
import 'dart:io';

import '../logging/app_logger.dart';

class SyncSettings {
  SyncSettings._();
  static final SyncSettings I = SyncSettings._();

  File? _file;
  Map<String, Object?> _data = {};

  Future<void> init(Directory appDocDir) async {
    _file = File('${appDocDir.path}/app_settings.json');
    _data = {};
    if (!_file!.existsSync()) return;
    try {
      final raw = _file!.readAsStringSync();
      if (raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) {
        _data = decoded;
      }
    } catch (e) {
      AppLogger.I.w('SyncSettings', 'parse failed: $e');
      _data = {};
    }
  }

  String? getString(String key) {
    final v = _data[key];
    return v is String ? v : null;
  }

  void setString(String key, String value) => _write(key, value);

  void remove(String key) {
    if (!_data.containsKey(key)) return;
    _data.remove(key);
    _flush();
  }

  void _write(String key, Object? value) {
    _data[key] = value;
    _flush();
  }

  void _flush() {
    final f = _file;
    if (f == null) return;
    try {
      final tmp = File('${f.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(_data), flush: true);
      tmp.renameSync(f.path);
    } catch (e) {
      AppLogger.I.w('SyncSettings', 'write failed: $e');
    }
  }
}
