import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/core/logging/app_logger.dart';

void main() {
  setUp(AppLogger.resetForTesting);

  group('LogEntry.line', () {
    test('formats timestamp, level, tag, message', () {
      final t = DateTime(2026, 7, 17, 14, 30, 15, 123);
      expect(
        LogEntry(t, LogLevel.info, 'Server', 'connect 1.2.3.4').line,
        '2026-07-17 14:30:15.123 [INFO] Server: connect 1.2.3.4',
      );
    });

    test('zero-pads single-digit fields and milliseconds', () {
      expect(
        LogEntry(DateTime(2026, 1, 2, 3, 4, 5, 6), LogLevel.error, 'T', 'm')
            .line,
        '2026-01-02 03:04:05.006 [ERROR] T: m',
      );
      expect(
        LogEntry(DateTime(2026, 7, 17, 14, 30, 15, 50), LogLevel.warning,
                'T', 'm')
            .line,
        '2026-07-17 14:30:15.050 [WARNING] T: m',
      );
    });

    test('uppercases level name', () {
      final line =
          LogEntry(DateTime(2026, 1, 1), LogLevel.debug, 'T', 'm').line;
      expect(line, contains('[DEBUG]'));
    });
  });

  group('buffer', () {
    test('caps at 2000 and drops oldest from head', () {
      for (var i = 0; i < 2001; i++) {
        AppLogger.I.d('T', 'm$i');
      }
      final all = AppLogger.I.exportRecent(const Duration(days: 365));
      expect(all.length, 2000);
      expect(all.first.message, 'm1');
      expect(all.last.message, 'm2000');
    });
  });

  group('exportRecent', () {
    test('duration boundary filters entries', () {
      AppLogger.I.d('T', 'a');
      AppLogger.I.d('T', 'b');
      AppLogger.I.d('T', 'c');
      expect(AppLogger.I.exportRecent(Duration.zero), isEmpty);
      expect(AppLogger.I.exportRecent(const Duration(days: 365)).length, 3);
    });
  });

  group('shouldDeleteLogFile', () {
    final now = DateTime(2026, 7, 17, 12, 0, 0);

    test('deletes files older than retention window', () {
      expect(AppLogger.shouldDeleteLogFile('2026-06-17.log', now), isTrue);
    });

    test('keeps recent and today', () {
      expect(AppLogger.shouldDeleteLogFile('2026-07-16.log', now), isFalse);
      expect(AppLogger.shouldDeleteLogFile('2026-07-17.log', now), isFalse);
    });

    test('skips non-.log and unparseable names', () {
      expect(AppLogger.shouldDeleteLogFile('2026-06-17.txt', now), isFalse);
      expect(AppLogger.shouldDeleteLogFile('not-a-date.log', now), isFalse);
      expect(AppLogger.shouldDeleteLogFile('2026-13-01.log', now), isFalse);
    });
  });

  group('readDiskLogs', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('applog_read');
    });
    tearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('todayOnly reads only the current-date file', () async {
      File('${tmp.path}/2026-07-16.log').writeAsStringSync('yesterday\n');
      File('${tmp.path}/2026-07-17.log')
          .writeAsStringSync('today line1\ntoday line2\n');
      expect(
        await AppLogger.readDiskLogs(tmp, '2026-07-17', todayOnly: true),
        'today line1\ntoday line2',
      );
    });

    test('todayOnly returns empty when current-date file is missing', () async {
      File('${tmp.path}/2026-07-16.log').writeAsStringSync('x\n');
      expect(
        await AppLogger.readDiskLogs(tmp, '2026-07-17', todayOnly: true),
        '',
      );
    });

    test('todayOnly returns empty when currentDate is null', () async {
      File('${tmp.path}/2026-07-17.log').writeAsStringSync('x\n');
      expect(
        await AppLogger.readDiskLogs(tmp, null, todayOnly: true),
        '',
      );
    });

    test('all reads every .log sorted by name, skips non-.log', () async {
      File('${tmp.path}/2026-07-17.log').writeAsStringSync('day2\n');
      File('${tmp.path}/2026-07-16.log').writeAsStringSync('day1\n');
      File('${tmp.path}/notes.txt').writeAsStringSync('ignore\n');
      expect(
        await AppLogger.readDiskLogs(tmp, null, todayOnly: false),
        'day1\nday2',
      );
    });

    test('all joins files, inserting missing trailing newline', () async {
      File('${tmp.path}/2026-07-16.log').writeAsStringSync('noeol');
      File('${tmp.path}/2026-07-17.log').writeAsStringSync('has\n');
      expect(
        await AppLogger.readDiskLogs(tmp, null, todayOnly: false),
        'noeol\nhas',
      );
    });
  });

  group('exportDiskText', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('applog_export');
    });
    tearDown(() async {
      await AppLogger.I.dispose();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('todayOnly refreshes stale currentDate via _rotate (AL-R1)', () async {
      File('${tmp.path}/2020-01-01.log').writeAsStringSync('past content\n');
      AppLogger.prepareDiskForTesting(tmp, '2020-01-01');
      final text = await AppLogger.I.exportDiskText(todayOnly: true);
      expect(text, '');
      expect(text.contains('past content'), isFalse);
    });
  });
}
