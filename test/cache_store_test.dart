import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/cache/cache_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _maxBlobChars = 8 * 1024 * 1024;

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('cache_store_test');
    // Root base is `<tmp>/data/files/ob_cache`; its parent chain lets the
    // bloat-check derive an isolated `<tmp>/data/shared_prefs/...`.
    FileCacheStore.rootBaseOverride =
        Directory('${tmp.path}/data/files/ob_cache');
  });

  tearDown(() async {
    FileCacheStore.rootBaseOverride = null;
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('FileCacheStore', () {
    test('write then read round-trips', () async {
      final cs = FileCacheStore('p1');
      await cs.write('server', '{"v":1}');
      await cs.write('conv/s1', '{"v":1,"messages":[]}');
      expect(await cs.read('server'), '{"v":1}');
      expect(await cs.read('conv/s1'), '{"v":1,"messages":[]}');
    });

    test('read returns null for missing key', () async {
      final cs = FileCacheStore('p1');
      expect(await cs.read('server'), isNull);
    });

    test('remove deletes a written key', () async {
      final cs = FileCacheStore('p1');
      await cs.write('conv/s1', 'x');
      await cs.remove('conv/s1');
      expect(await cs.read('conv/s1'), isNull);
    });

    test('write above the blob cap is rejected', () async {
      final cs = FileCacheStore('p1');
      final huge = 'x' * (_maxBlobChars + 1);
      await cs.write('conv/big', huge);
      expect(await cs.read('conv/big'), isNull);
    });

    test('profiles are isolated by directory', () async {
      await FileCacheStore('p1').write('server', 'A');
      await FileCacheStore('p2').write('server', 'B');
      expect(await FileCacheStore('p1').read('server'), 'A');
      expect(await FileCacheStore('p2').read('server'), 'B');
    });

    test('removeProfile deletes the whole profile namespace', () async {
      final cs = FileCacheStore('p1');
      await cs.write('server', 'S');
      await cs.write('conv/s1', '1');
      await cs.write('conv/s2', '2');
      await FileCacheStore.removeProfile('p1');
      expect(await cs.read('server'), isNull);
      expect(await cs.read('conv/s1'), isNull);
      expect(await cs.read('conv/s2'), isNull);
      // Other profiles untouched.
      await FileCacheStore('p2').write('server', 'S2');
      expect(await FileCacheStore('p2').read('server'), 'S2');
    });

    test('clear removes the profile namespace', () async {
      final cs = FileCacheStore('p1');
      await cs.write('server', 'S');
      await cs.write('conv/s1', '1');
      await cs.clear();
      expect(await cs.read('server'), isNull);
      expect(await cs.read('conv/s1'), isNull);
    });

    test('overwrite replaces previous value', () async {
      final cs = FileCacheStore('p1');
      await cs.write('server', 'old');
      await cs.write('server', 'new');
      expect(await cs.read('server'), 'new');
    });

    test('concurrent writes to same key do not race (no .tmp residue)',
        () async {
      final cs = FileCacheStore('p1');
      final n = 100;
      final futures = <Future<bool>>[];
      for (var i = 0; i < n; i++) {
        futures.add(cs.write('conv/s1', 'v$i'));
      }
      final results = await Future.wait(futures);
      expect(results.every((r) => r), isTrue);
      final value = await cs.read('conv/s1');
      expect(value, isNotNull);
      expect(int.parse(value!.substring(1)), inInclusiveRange(0, n - 1));
      final root = FileCacheStore.rootBaseOverride!;
      final residue = root
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.tmp'))
          .toList();
      expect(residue, isEmpty);
    });
  });

  group('migrateFromPrefs', () {
    test('moves server + conv blobs into per-profile files and clears prefs',
        () async {
      SharedPreferences.setMockInitialValues({
        'server_p1': '{"v":1,"sessions":[{"id":"s1"},{"id":"s2"}]}',
        'conv_s1': '{"messages":[],"draft":"hi"}',
        'conv_s2': '{"messages":[]}',
        'themeMode': '1', // unrelated small setting, must survive
      });

      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1']);

      expect(await FileCacheStore('p1').read('server'),
          '{"v":1,"sessions":[{"id":"s1"},{"id":"s2"}]}');
      expect(await FileCacheStore('p1').read('conv/s1'),
          '{"messages":[],"draft":"hi"}');
      expect(await FileCacheStore('p1').read('conv/s2'), '{"messages":[]}');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('server_p1'), isNull);
      expect(prefs.getString('conv_s1'), isNull);
      expect(prefs.getString('conv_s2'), isNull);
      expect(prefs.getString('themeMode'), '1'); // preserved
    });

    test('drops orphan conv_* with no matching server cache', () async {
      SharedPreferences.setMockInitialValues({
        'conv_orphan': '{"messages":[]}',
      });
      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1']);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('conv_orphan'), isNull);
    });

    test('maps each conv to its owning profile via server cache sessions',
        () async {
      SharedPreferences.setMockInitialValues({
        'server_p1': '{"v":1,"sessions":[{"id":"a"}]}',
        'server_p2': '{"v":1,"sessions":[{"id":"b"}]}',
        'conv_a': '{"messages":[],"owner":"p1"}',
        'conv_b': '{"messages":[],"owner":"p2"}',
      });
      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1', 'p2']);
      expect(await FileCacheStore('p1').read('conv/a'),
          '{"messages":[],"owner":"p1"}');
      expect(await FileCacheStore('p2').read('conv/b'),
          '{"messages":[],"owner":"p2"}');
      // No cross-contamination.
      expect(await FileCacheStore('p1').read('conv/b'), isNull);
    });

    test('is idempotent (marker gates re-run)', () async {
      SharedPreferences.setMockInitialValues({
        'server_p1': '{"v":1,"sessions":[{"id":"s1"}]}',
        'conv_s1': '{"messages":[]}',
      });
      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1']);
      final firstRead = await FileCacheStore('p1').read('server');
      // Mutate prefs after first migration; second run must not touch them.
      SharedPreferences.setMockInitialValues({
        'server_p1': '{"v":1,"sessions":[]}',
      });
      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1']);
      expect(await FileCacheStore('p1').read('server'), firstRead);
    });

    test('skips conv blob that exceeds the cap (and removes it)', () async {
      SharedPreferences.setMockInitialValues({
        'server_p1': '{"v":1,"sessions":[{"id":"big"}]}',
        'conv_big': 'x' * (_maxBlobChars + 1),
      });
      await FileCacheStore.migrateFromPrefs(profileIds: const ['p1']);
      expect(await FileCacheStore('p1').read('conv/big'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('conv_big'), isNull);
    });
  });

  group('migrateFromPrefs bloat guard (CSM-10)', () {
    test('deletes an over-threshold FlutterSharedPreferences.xml', () async {
      // rootBaseOverride = <tmp>/data/files/ob_cache
      // → support = <tmp>/data/files → dataDir = <tmp>/data
      // → prefs file at <tmp>/data/shared_prefs/FlutterSharedPreferences.xml
      final prefsDir = Directory('${tmp.path}/data/shared_prefs')
        ..createSync(recursive: true);
      final prefsFile =
          File('${prefsDir.path}/FlutterSharedPreferences.xml');
      prefsFile.writeAsBytesSync(List<int>.filled(5 * 1024 * 1024, 0));

      await FileCacheStore.migrateFromPrefs(profileIds: const []);

      expect(prefsFile.existsSync(), isFalse);
      // Marker written so Dart never re-reads prefs.
      expect(File('${FileCacheStore.rootBaseOverride!.path}/migrated_v1')
          .existsSync(),
          isTrue);
    });

    test('leaves a small prefs file untouched', () async {
      final prefsDir = Directory('${tmp.path}/data/shared_prefs')
        ..createSync(recursive: true);
      final prefsFile =
          File('${prefsDir.path}/FlutterSharedPreferences.xml');
      prefsFile.writeAsStringSync('<small/>');
      await FileCacheStore.migrateFromPrefs(profileIds: const []);
      expect(prefsFile.existsSync(), isTrue);
    });
  });

  group('InMemoryCacheStore', () {
    test('round-trip + remove + cap', () async {
      final cs = InMemoryCacheStore();
      await cs.write('k', 'v');
      expect(await cs.read('k'), 'v');
      await cs.remove('k');
      expect(await cs.read('k'), isNull);
      await cs.write('big', 'x' * (_maxBlobChars + 1));
      expect(await cs.read('big'), isNull);
    });
  });
}
