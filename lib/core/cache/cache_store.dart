import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logging/app_logger.dart';

const _tag = 'Cache';

/// Per-key string blob cache. Backed by [FileCacheStore] in production; an
/// [InMemoryCacheStore] is provided for tests.
abstract interface class CacheStore {
  Future<String?> read(String key);

  /// Returns true if written; false if skipped (over cap) or failed (I/O
  /// error). Lets callers avoid deleting a still-valid source on failure.
  Future<bool> write(String key, String value);

  Future<void> remove(String key);

  /// Remove every key owned by this store (the whole profile namespace).
  Future<void> clear();
}

/// Single cache blob may not exceed this many characters when written. Guards
/// against a runaway conversation (huge tool outputs) re-bloating storage and
/// re-introducing the OOM class of bug this layer exists to prevent.
const _maxBlobChars = 8 * 1024 * 1024; // 8 MiB

/// If FlutterSharedPreferences.xml exceeds this, the whole file is deleted
/// (its getAll() is the historical OOM source). Only affects already-broken,
/// over-bloated installs; normal users stay under it.
const _prefsBloatThreshold = 4 * 1024 * 1024; // 4 MiB

const _rootName = 'ob_cache';
const _migrateMarker = 'migrated_v1';

/// Profile-scoped file cache. Root: `<appSupport>/ob_cache/<profileId>/`.
/// Keys map to `<root>/<key>.json` (a key may contain path separators, e.g.
/// `conv/<sessionId>`). Writes are atomic (`.tmp` + `rename` on the same dir).
class FileCacheStore implements CacheStore {
  FileCacheStore(this.profileId);

  final String profileId;

  @override
  Future<String?> read(String key) async {
    final f = await _fileFor(key);
    if (!f.existsSync()) return null;
    try {
      return f.readAsString();
    } catch (e) {
      AppLogger.I.w(_tag, 'read $key failed: $e');
      return null;
    }
  }

  @override
  Future<bool> write(String key, String value) async {
    if (value.length > _maxBlobChars) {
      AppLogger.I.w(_tag, 'write $key skipped: ${value.length} chars > cap');
      return false;
    }
    final f = await _fileFor(key);
    try {
      await f.parent.create(recursive: true);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(f.path);
      return true;
    } catch (e) {
      AppLogger.I.w(_tag, 'write $key failed: $e');
      return false;
    }
  }

  @override
  Future<void> remove(String key) async {
    final f = await _fileFor(key);
    try {
      if (f.existsSync()) await f.delete();
    } catch (e) {
      AppLogger.I.w(_tag, 'remove $key failed: $e');
    }
  }

  @override
  Future<void> clear() => removeProfile(profileId);

  Future<File> _fileFor(String key) async {
    final root = await _root();
    return File('${root.path}/$key.json');
  }

  Future<Directory> _root() async {
    final base = await _ensureRootBase();
    return Directory('${base.path}/$profileId');
  }

  /// Delete an entire profile namespace (`ob_cache/<profileId>/`). Used on
  /// profile removal — needs only the profile id, no session→profile mapping
  /// (the per-profile directory *is* the mapping).
  static Future<void> removeProfile(String profileId) async {
    try {
      final base = await _ensureRootBase();
      final dir = Directory('${base.path}/$profileId');
      if (dir.existsSync()) await dir.delete(recursive: true);
    } catch (e) {
      AppLogger.I.w(_tag, 'removeProfile $profileId failed: $e');
    }
  }

  /// One-time migration of legacy SharedPreferences blobs (`conv_*` /
  /// `server_*`) into the file store. Runs once per install (gated by
  /// `ob_cache/migrated_v1`).
  ///
  /// [profileIds] — all known profile ids (from ConnectionStore), used to
  /// recover the session→profile mapping by parsing each `server_$id` cache's
  /// `sessions[].id` (the conv blob itself carries no profile id).
  ///
  /// Order: must run before any store `_loadCache` (see design doc CSM-6) and
  /// after `connectionStore.load()` (profile ids must be enumerable, CSM-7).
  /// Belt-and-suspenders: if the native cleanup didn't fire and prefs is still
  /// bloated, delete it here before `getInstance()` re-triggers the OOM
  /// (CSM-10).
  static Future<void> migrateFromPrefs({
    required List<String> profileIds,
  }) async {
    try {
      final base = await _ensureRootBase();
      final marker = File('${base.path}/$_migrateMarker');
      if (marker.existsSync()) return;

      await _maybeDeleteBloatedPrefs();

      final prefs = await SharedPreferences.getInstance();
      for (final pid in profileIds) {
        final serverRaw = prefs.getString('server_$pid');
        final sessionIds = <String>{};
        if (serverRaw != null && serverRaw.isNotEmpty) {
          sessionIds.addAll(_extractSessionIds(serverRaw));
          // Drop from prefs only if written to file, or if it was over-cap
          // (garbage). On write failure, keep the prefs copy so it isn't lost.
          final tooBig = serverRaw.length > _maxBlobChars;
          final wrote = !tooBig &&
              await FileCacheStore(pid).write('server', serverRaw);
          if (wrote || tooBig) await prefs.remove('server_$pid');
        }
        for (final sid in sessionIds) {
          final convRaw = prefs.getString('conv_$sid');
          if (convRaw == null || convRaw.isEmpty) continue;
          final tooBig = convRaw.length > _maxBlobChars;
          final wrote =
              !tooBig && await FileCacheStore(pid).write('conv/$sid', convRaw);
          if (wrote || tooBig) await prefs.remove('conv_$sid');
        }
      }
      // Orphan conv_* (no surviving server cache to map them) — drop.
      for (final key in prefs.getKeys().toList()) {
        if (key.startsWith('conv_')) await prefs.remove(key);
      }
      await marker.create(recursive: true);
    } catch (e) {
      AppLogger.I.w(_tag, 'migrateFromPrefs failed: $e');
    }
  }

  static Set<String> _extractSessionIds(String serverJson) {
    final ids = <String>{};
    try {
      final j = jsonDecode(serverJson) as Map<String, dynamic>;
      final sessions = j['sessions'];
      if (sessions is List) {
        for (final s in sessions) {
          if (s is Map) {
            final id = s['id']?.toString();
            if (id != null && id.isNotEmpty) ids.add(id);
          }
        }
      }
    } catch (e) {
      AppLogger.I.w(_tag, 'extractSessionIds failed: $e');
    }
    return ids;
  }

  // CSM-10: defense-in-depth. If native Application.onCreate didn't clear the
  // bloated prefs file (not registered / wrong path / threw), getInstance()
  // below would re-crash exactly as before. Stat the file via dart:io (no
  // plugin) and delete it ourselves first.
  static Future<void> _maybeDeleteBloatedPrefs() async {
    try {
      final base = await _ensureRootBase(); // <support>/ob_cache
      final support = base.parent; // <support> (= filesDir on Android)
      final f = File('${support.parent.path}/shared_prefs/'
          'FlutterSharedPreferences.xml');
      if (f.existsSync() && f.lengthSync() > _prefsBloatThreshold) {
        final size = f.lengthSync();
        await f.delete();
        AppLogger.I.w(_tag, 'deleted bloated FlutterSharedPreferences.xml '
            '($size bytes > $_prefsBloatThreshold)');
      }
    } catch (e) {
      AppLogger.I.w(_tag, 'bloat check failed: $e');
    }
  }

  /// Test override for the cache root base (`<support>/ob_cache`). When set,
  /// [path_provider] is not consulted. Must be cleared in tearDown.
  @visibleForTesting
  static Directory? rootBaseOverride;

  /// Memoized root base. The support dir never changes post-startup, so this
  /// avoids a platform-channel hop + existsSync on every read/write/remove —
  /// matters on the streaming save path (2s-throttled _saveCache).
  static Directory? _rootBaseCached;

  static Future<Directory> _ensureRootBase() async {
    if (rootBaseOverride != null) return rootBaseOverride!;
    final cached = _rootBaseCached;
    if (cached != null) return cached;
    final support = await getApplicationSupportDirectory();
    final base = Directory('${support.path}/$_rootName');
    if (!base.existsSync()) base.createSync(recursive: true);
    _rootBaseCached = base;
    return base;
  }
}

/// In-memory CacheStore for tests.
class InMemoryCacheStore implements CacheStore {
  InMemoryCacheStore([Map<String, String>? initial]) : _data = {...?initial};

  final Map<String, String> _data;

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<bool> write(String key, String value) async {
    if (value.length > _maxBlobChars) return false;
    _data[key] = value;
    return true;
  }

  @override
  Future<void> remove(String key) async => _data.remove(key);

  @override
  Future<void> clear() async => _data.clear();
}
