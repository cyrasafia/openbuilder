import 'package:flutter/foundation.dart';

/// FIFO cache of agent inline image fetches (design-agent-inline-image D5).
///
/// Keys are `directory\x1fpath`; values are the in-flight [Future] itself so
/// concurrent same-key callers share one request. A failed fetch resolves to
/// null (or an error) and stays cached until natural eviction — a negative
/// cache that keeps dead images (e.g. files the agent deleted, 404) from
/// re-requesting within the eviction window.
class LocalImageCache {
  static final instance = LocalImageCache();

  final int maxEntries;

  LocalImageCache({this.maxEntries = 32});

  // Dart's Map default is insertion-ordered (LinkedHashMap); keys.first is the
  // oldest entry → O(1) FIFO eviction. Same shape as [ImageDataCache].
  final _cache = <String, Future<Uint8List?>>{};

  Future<Uint8List?> fetch(String key, Future<Uint8List?> Function() loader) {
    final cached = _cache.putIfAbsent(key, loader);
    if (_cache.length > maxEntries) _cache.remove(_cache.keys.first);
    return cached;
  }
}
