import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/image_data_cache.dart';

Future<Uint8List?> _syncDecode(String url) async {
  final comma = url.indexOf(',');
  if (comma < 0) return null;
  try {
    return base64Decode(url.substring(comma + 1));
  } catch (_) {
    return null;
  }
}

String _url(Uint8List bytes) =>
    'data:application/octet-stream;base64,${base64Encode(bytes)}';

void main() {
  group('ImageDataCache', () {
    test('decodes a valid data url', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      expect(await cache.get(_url(bytes)), bytes);
    });

    test('returns null for non-data url', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      expect(await cache.get('https://example.com/a.png'), isNull);
    });

    test('returns null when payload has no comma', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      expect(await cache.get('data:no-comma-here'), isNull);
    });

    test('returns null for invalid base64', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      expect(await cache.get('data:;base64,@@@not-base64@@@'), isNull);
    });

    test('caches in-flight future (same object on repeated get)', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      final url = _url(Uint8List.fromList([9]));
      final f1 = cache.get(url);
      final f2 = cache.get(url);
      expect(identical(f1, f2), isTrue);
      expect(await f1, Uint8List.fromList([9]));
    });

    test('caches resolved bytes across calls', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      final bytes = Uint8List.fromList([7, 7]);
      final url = _url(bytes);
      await cache.get(url);
      expect(await cache.get(url), bytes);
    });

    test('decode failure caches null and does not throw', () async {
      final cache = ImageDataCache(decode: _syncDecode);
      final url = 'data:;base64,@@@bad@@@';
      expect(await cache.get(url), isNull);
      expect(await cache.get(url), isNull);
    });

    test('evicts oldest beyond maxEntries (FIFO)', () async {
      var calls = 0;
      final cache = ImageDataCache(
        decode: (url) async {
          calls++;
          return _syncDecode(url);
        },
        maxEntries: 3,
      );
      final f0 = cache.get(_url(Uint8List.fromList([0])));
      await f0;
      for (var i = 1; i <= 3; i++) {
        await cache.get(_url(Uint8List.fromList([i])));
      }
      expect(calls, 4);
      final f0Again = cache.get(_url(Uint8List.fromList([0])));
      expect(identical(f0, f0Again), isFalse);
      await f0Again;
      expect(calls, 5);
    });
  });
}
