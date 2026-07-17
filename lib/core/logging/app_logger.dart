import 'dart:async';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

enum LogLevel { debug, info, warning, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String tag;
  final String message;

  const LogEntry(this.time, this.level, this.tag, this.message);

  String get line =>
      '${_fmt(time)} [${level.name.toUpperCase()}] $tag: $message';

  static String _fmt(DateTime t) =>
      '${t.year}-${_p(t.month)}-${_p(t.day)} '
      '${_p(t.hour)}:${_p(t.minute)}:${_p(t.second)}.${_p3(t.millisecond)}';

  static String _p(int n) => n < 10 ? '0$n' : '$n';
  static String _p3(int n) => n < 100 ? n < 10 ? '00$n' : '0$n' : '$n';
}

class AppLogger {
  AppLogger._();
  static final AppLogger I = AppLogger._();

  Directory? _dir;
  IOSink? _sink;
  String? _currentDate;
  final List<LogEntry> _buffer = [];
  static const _maxBuffer = 2000;
  static const _retentionDays = 7;

  Future<void> init() async {
    final appDir = await getApplicationDocumentsDirectory();
    _dir = Directory('${appDir.path}/logs');
    await _dir!.create(recursive: true);
    _rotate();
    _cleanup();
  }

  void _rotate() {
    if (_dir == null) return;
    final now = DateTime.now();
    final date = '${now.year}-${_p(now.month)}-${_p(now.day)}';
    if (date == _currentDate && _sink != null) return;
    _sink?.close();
    _currentDate = date;
    final file = File('${_dir!.path}/$date.log');
    _sink = file.openWrite(mode: FileMode.append);
  }

  void _cleanup() {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: _retentionDays));
    try {
      for (final f in _dir!.listSync().whereType<File>()) {
        final name = f.uri.pathSegments.last;
        if (!name.endsWith('.log')) continue;
        final base = name.replaceAll('.log', '');
        final parts = base.split('-');
        if (parts.length != 3) continue;
        final fileDate = DateTime.tryParse(base);
        if (fileDate != null && fileDate.isBefore(cutoff)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  void log(LogLevel level, String tag, String message) {
    final entry = LogEntry(DateTime.now(), level, tag, message);
    _buffer.add(entry);
    if (_buffer.length > _maxBuffer) {
      _buffer.removeRange(0, _buffer.length - _maxBuffer);
    }
    _rotate();
    _sink?.writeln(entry.line);
  }

  void d(String tag, String message) => log(LogLevel.debug, tag, message);
  void i(String tag, String message) => log(LogLevel.info, tag, message);
  void w(String tag, String message) => log(LogLevel.warning, tag, message);
  void e(String tag, String message) => log(LogLevel.error, tag, message);

  Future<List<LogEntry>> exportRecent(Duration since) async {
    final cutoff = DateTime.now().subtract(since);
    return _buffer.where((e) => e.time.isAfter(cutoff)).toList();
  }

  Future<String> exportDiskText({required bool todayOnly}) async {
    if (_dir == null) {
      return _buffer.map((e) => e.line).join('\n');
    }
    await _sink?.flush();
    final files = <File>[];
    if (todayOnly) {
      if (_currentDate != null) {
        final f = File('${_dir!.path}/$_currentDate.log');
        if (await f.exists()) files.add(f);
      }
    } else {
      final all = _dir!.listSync().whereType<File>().where((f) {
        return f.uri.pathSegments.last.endsWith('.log');
      }).toList();
      all.sort(
          (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
      files.addAll(all);
    }
    final sb = StringBuffer();
    for (final f in files) {
      final content = await f.readAsString();
      if (content.isEmpty) continue;
      sb.write(content);
      if (!content.endsWith('\n')) sb.writeln();
    }
    return sb.toString().trimRight();
  }

  Future<File> exportFileRecent(Duration since, {String? filename}) async {
    final entries = await exportRecent(since);
    return _writeTemp(entries.map((e) => e.line).join('\n'), filename);
  }

  Future<File> exportFileDisk({required bool todayOnly, String? filename}) async {
    final text = await exportDiskText(todayOnly: todayOnly);
    return _writeTemp(text, filename);
  }

  Future<File> _writeTemp(String text, String? filename) async {
    final name = filename ??
        'opencode-logs-${_p(DateTime.now().hour)}${_p(DateTime.now().minute)}.log';
    final tmp = await getTemporaryDirectory();
    final file = File('${tmp.path}/$name');
    await file.writeAsString(text);
    return file;
  }

  static String _p(int n) => n < 10 ? '0$n' : '$n';

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
  }
}
