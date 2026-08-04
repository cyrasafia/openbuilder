import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decodes a `data:` URL to its raw bytes.
typedef DataUrlDecoder = Future<Uint8List?> Function(String url);

class ImageDataCache {
  static final instance = ImageDataCache();

  final DataUrlDecoder decode;
  final int maxEntries;

  ImageDataCache({this.decode = _isolateDecode, this.maxEntries = 64});

  // Dart's Map default is insertion-ordered (LinkedHashMap); keys.first is the
  // oldest entry → O(1) FIFO eviction.
  final _cache = <String, Future<Uint8List?>>{};

  Future<Uint8List?> get(String url) {
    if (!url.startsWith('data:')) return Future.value(null);
    final cached = _cache.putIfAbsent(url, () => decode(url));
    if (_cache.length > maxEntries) _cache.remove(_cache.keys.first);
    return cached;
  }

  static Future<Uint8List?> _isolateDecode(String url) async {
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    try {
      return await compute(_decodeBase64, url.substring(comma + 1));
    } catch (_) {
      return null;
    }
  }
}

Uint8List _decodeBase64(String s) => base64Decode(s);
