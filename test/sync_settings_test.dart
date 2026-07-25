import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/settings/sync_settings.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sync_settings');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('SyncSettings', () {
    test('getString returns null for fresh store', () async {
      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), isNull);
    });

    test('setString is durable across re-init (restart)', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.setString('locale', 'en');

      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), 'en');
    });

    test('remove is durable across re-init — no stale value resurfaces', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.setString('locale', 'en');
      expect(SyncSettings.I.getString('locale'), 'en');
      SyncSettings.I.remove('locale');

      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), isNull);
    });

    test('remove when key absent does not rewrite file', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.remove('locale');
      expect(File('${tmp.path}/app_settings.json').existsSync(), isFalse);
    });

    test('corrupt file is treated as empty without throwing', () async {
      File('${tmp.path}/app_settings.json').writeAsStringSync('{not json');
      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), isNull);
      SyncSettings.I.setString('locale', 'zh');
      expect(SyncSettings.I.getString('locale'), 'zh');
    });

    test('getString returns null for a wrong-type value instead of throwing',
        () async {
      File('${tmp.path}/app_settings.json').writeAsStringSync('{"locale": 5}');
      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), isNull);
    });

    test('setString overwrites previous value', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.setString('locale', 'en');
      SyncSettings.I.setString('locale', 'zh');

      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), 'zh');
    });

    test('other keys are preserved when one is removed', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.setString('locale', 'en');
      SyncSettings.I.setString('theme', 'dark');
      SyncSettings.I.remove('locale');

      await SyncSettings.I.init(tmp);
      expect(SyncSettings.I.getString('locale'), isNull);
      expect(SyncSettings.I.getString('theme'), 'dark');
      final raw = jsonDecode(
          File('${tmp.path}/app_settings.json').readAsStringSync());
      expect((raw as Map).containsKey('locale'), isFalse);
    });

    test('atomic write leaves no .tmp file behind on success', () async {
      await SyncSettings.I.init(tmp);
      SyncSettings.I.setString('locale', 'en');
      expect(File('${tmp.path}/app_settings.json.tmp').existsSync(), isFalse);
      expect(File('${tmp.path}/app_settings.json').existsSync(), isTrue);
    });
  });
}
