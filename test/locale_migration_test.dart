import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/settings/sync_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('locale_migration');
    SharedPreferences.setMockInitialValues({});
    await SyncSettings.I.init(tmp);
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('resolvePersistedLocale', () {
    test('web path reads SharedPreferences directly', () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      expect(await resolvePersistedLocale(prefs, false), 'en');
    });

    test('file value takes precedence over legacy prefs', () async {
      SharedPreferences.setMockInitialValues({'locale': 'zh'});
      final prefs = await SharedPreferences.getInstance();
      SyncSettings.I.setString('locale', 'en');
      expect(await resolvePersistedLocale(prefs, true), 'en');
      expect(prefs.getString('locale'), 'zh');
    });

    test('legacy prefs value is migrated into file and cleared', () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      expect(await resolvePersistedLocale(prefs, true), 'en');
      expect(SyncSettings.I.getString('locale'), 'en');
      expect(prefs.getString('locale'), isNull);
    });

    test('regression: System choice survives restart (no re-migration)',
        () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      await resolvePersistedLocale(prefs, true);
      SyncSettings.I.remove('locale');
      expect(await resolvePersistedLocale(prefs, true), isNull);
    });

    test('System survives even when legacy prefs.clear failed (marker one-shot)',
        () async {
      SharedPreferences.setMockInitialValues({'locale': 'en'});
      final prefs = await SharedPreferences.getInstance();
      SyncSettings.I.setString('locale', 'en');
      SyncSettings.I.setString('localeMigrated', '1');
      SyncSettings.I.remove('locale');
      expect(await resolvePersistedLocale(prefs, true), isNull);
      expect(prefs.getString('locale'), 'en');
    });

    test('no value anywhere returns null', () async {
      final prefs = await SharedPreferences.getInstance();
      expect(await resolvePersistedLocale(prefs, true), isNull);
    });
  });
}
