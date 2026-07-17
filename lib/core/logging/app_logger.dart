import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
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

  static String _p(int n) => n.toString().padLeft(2, '0');
  static String _p3(int n) => n.toString().padLeft(3, '0');
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
    _currentDate = date;
    final file = File('${_dir!.path}/$date.log');
    final old = _sink;
    _sink = file.openWrite(mode: FileMode.append);
    unawaited(old?.close());
  }

  void _cleanup() {
    final now = DateTime.now();
    try {
      for (final f in _dir!.listSync().whereType<File>()) {
        if (shouldDeleteLogFile(f.uri.pathSegments.last, now)) {
          f.deleteSync();
        }
      }
    } catch (_) {}
  }

  @visibleForTesting
  static bool shouldDeleteLogFile(String fileName, DateTime now) {
    if (!fileName.endsWith('.log')) return false;
    final base = fileName.replaceAll('.log', '');
    if (base.split('-').length != 3) return false;
    final fileDate = DateTime.tryParse(base);
    if (fileDate == null) return false;
    return fileDate.isBefore(now.subtract(const Duration(days: _retentionDays)));
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

  List<LogEntry> exportRecent(Duration since) {
    final cutoff = DateTime.now().subtract(since);
    return _buffer.where((e) => e.time.isAfter(cutoff)).toList();
  }

  Future<String> exportDiskText({required bool todayOnly}) async {
    if (_dir == null) {
      return _buffer.map((e) => e.line).join('\n');
    }
    await _sink?.flush();
    _rotate();
    return readDiskLogs(_dir!, _currentDate, todayOnly: todayOnly);
  }

  @visibleForTesting
  static Future<String> readDiskLogs(
      Directory dir, String? currentDate, {required bool todayOnly}) async {
    final files = <File>[];
    if (todayOnly) {
      if (currentDate != null) {
        final f = File('${dir.path}/$currentDate.log');
        if (await f.exists()) files.add(f);
      }
    } else {
      final all = dir.listSync().whereType<File>().where((f) {
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

  @visibleForTesting
  static void prepareDiskForTesting(Directory dir, String currentDate) {
    I._dir = dir;
    I._currentDate = currentDate;
    I._sink = null;
  }

  Future<File> exportFileRecent(Duration since, {String? filename}) async {
    final entries = exportRecent(since);
    return _writeTemp(entries.map((e) => e.line).join('\n'), filename);
  }

  Future<File> exportFileDisk({required bool todayOnly, String? filename}) async {
    final text = await exportDiskText(todayOnly: todayOnly);
    return _writeTemp(text, filename);
  }

  Future<File> _writeTemp(String text, String? filename) async {
    final n = DateTime.now();
    final name = filename ?? 'opencode-logs-${_p(n.hour)}${_p(n.minute)}.log';
    final tmp = await getTemporaryDirectory();
    final file = File('${tmp.path}/$name');
    await file.writeAsString(text);
    return file;
  }

  static String _p(int n) => n.toString().padLeft(2, '0');

  Future<void> flush() async {
    await _sink?.flush();
  }

  Future<void> dispose() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
  }

  @visibleForTesting
  static void resetForTesting() {
    I._buffer.clear();
    I._dir = null;
    I._sink = null;
    I._currentDate = null;
  }
}
