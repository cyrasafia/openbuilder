import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../domain/models.dart';

class OpenFileEntry {
  final String path;
  final double scrollOffset;
  final bool wrap;
  final bool mdShowSource;
  final bool hadContent;
  const OpenFileEntry({
    required this.path,
    required this.scrollOffset,
    required this.wrap,
    required this.mdShowSource,
    this.hadContent = false,
  });
}

class FileListRestore {
  final double scrollOffset;
  final String searchQuery;
  final bool searchExpanded;
  const FileListRestore({
    required this.scrollOffset,
    required this.searchQuery,
    required this.searchExpanded,
  });
}

class FileBrowsingSnapshot {
  String listPath;
  double listScrollOffset;
  String searchQuery;
  bool searchExpanded;
  final List<OpenFileEntry> openFiles;

  FileBrowsingSnapshot({
    this.listPath = '',
    this.listScrollOffset = 0,
    this.searchQuery = '',
    this.searchExpanded = false,
    List<OpenFileEntry>? openFiles,
  }) : openFiles = openFiles ?? [];
}

class _ContentEntry {
  final StreamedFile file;
  final int bytes;
  final DateTime cachedAt;
  const _ContentEntry(this.file, this.bytes, this.cachedAt);
}

class FileBrowsingStore {
  static const maxSnapshots = 10;
  static const maxOpenFiles = 8;
  static const maxContentBytes = 16 << 20;
  static const maxSingleFileBytes = 8 << 20;
  static const contentTtl = Duration(seconds: 60);
  static const collapseTimeout = Duration(seconds: 5);

  final LinkedHashMap<String, FileBrowsingSnapshot> _snapshots =
      LinkedHashMap();
  final LinkedHashMap<String, _ContentEntry> _content = LinkedHashMap();
  int _contentBytes = 0;

  @visibleForTesting
  int get debugContentBytes => _contentBytes;

  String? _collapseKey;
  DateTime? _collapseStartedAt;
  FileBrowsingSnapshot? _staged;

  final Map<String, int> _listAnchors = {};

  final Map<String, Object> _containers = {};

  void registerContainer(
    String sessionId,
    String? directory,
    Object container,
  ) {
    _containers[_key(sessionId, directory)] = container;
  }

  void unregisterContainer(
    String sessionId,
    String? directory,
    Object container,
  ) {
    final k = _key(sessionId, directory);
    if (_containers[k] == container) _containers.remove(k);
  }

  T? containerFor<T>(String sessionId, String? directory) {
    final c = _containers[_key(sessionId, directory)];
    return c is T ? c : null;
  }

  void registerListAnchor(String sessionId, String? directory) {
    final k = _key(sessionId, directory);
    _listAnchors[k] = (_listAnchors[k] ?? 0) + 1;
  }

  void unregisterListAnchor(String sessionId, String? directory) {
    final k = _key(sessionId, directory);
    final n = (_listAnchors[k] ?? 0) - 1;
    if (n <= 0) {
      _listAnchors.remove(k);
    } else {
      _listAnchors[k] = n;
    }
  }

  bool hasListAnchor(String sessionId, String? directory) =>
      (_listAnchors[_key(sessionId, directory)] ?? 0) > 0;

  String _key(String sessionId, String? directory) =>
      '$sessionId|${directory ?? ''}';

  String _contentKey(String sessionId, String? directory, String path) =>
      '${_key(sessionId, directory)}|$path';

  FileBrowsingSnapshot? snapshotFor(String sessionId, String? directory) {
    final key = _key(sessionId, directory);
    final snap = _snapshots.remove(key);
    if (snap == null) return null;
    _snapshots[key] = snap;
    return snap;
  }

  void clearSnapshot(String sessionId, String? directory) {
    _snapshots.remove(_key(sessionId, directory));
  }

  void removeSessionData(String sessionId) {
    final prefix = '$sessionId|';
    for (final k
        in _snapshots.keys.where((k) => k.startsWith(prefix)).toList()) {
      _snapshots.remove(k);
    }
    for (final k in _content.keys.where((k) => k.startsWith(prefix)).toList()) {
      final e = _content.remove(k);
      _contentBytes -= e?.bytes ?? 0;
    }
    for (final k
        in _listAnchors.keys.where((k) => k.startsWith(prefix)).toList()) {
      _listAnchors.remove(k);
    }
    for (final k
        in _containers.keys.where((k) => k.startsWith(prefix)).toList()) {
      _containers.remove(k);
    }
    if (_collapseKey?.startsWith(prefix) ?? false) resetCollapse();
  }

  // ── collapse protocol ──

  void beginCollapse(String sessionId, String? directory) {
    _collapseKey = _key(sessionId, directory);
    _collapseStartedAt = DateTime.now();
    _staged = FileBrowsingSnapshot();
  }

  bool isCollapsing(String sessionId, String? directory) {
    final key = _collapseKey;
    if (key == null) return false;
    final started = _collapseStartedAt;
    if (started == null ||
        DateTime.now().difference(started) > collapseTimeout) {
      resetCollapse();
      return false;
    }
    return key == _key(sessionId, directory);
  }

  void collectFile(String sessionId, String? directory, OpenFileEntry entry) {
    if (!isCollapsing(sessionId, directory) || _staged == null) return;
    _staged!.openFiles.insert(0, entry);
    if (_staged!.openFiles.length > maxOpenFiles) {
      _staged!.openFiles.removeAt(0);
    }
  }

  void collectList(
    String sessionId,
    String? directory, {
    required String path,
    required double scrollOffset,
    required String searchQuery,
    required bool searchExpanded,
  }) {
    if (!isCollapsing(sessionId, directory) || _staged == null) return;
    _staged!
      ..listPath = path
      ..listScrollOffset = scrollOffset
      ..searchQuery = searchQuery
      ..searchExpanded = searchExpanded;
    endCollapse(sessionId, directory);
  }

  void endCollapse(String sessionId, String? directory) {
    final staged = _staged;
    final key = _collapseKey;
    if (staged != null && key != null) {
      _snapshots.remove(key);
      _snapshots[key] = staged;
      while (_snapshots.length > maxSnapshots) {
        _snapshots.remove(_snapshots.keys.first);
      }
    }
    resetCollapse();
  }

  void resetCollapse() {
    _collapseKey = null;
    _collapseStartedAt = null;
    _staged = null;
  }

  // ── content cache ──

  StreamedFile? cachedContent(
    String sessionId,
    String? directory,
    String path, {
    DateTime? now,
  }) {
    final key = _contentKey(sessionId, directory, path);
    final entry = _content[key];
    if (entry == null) return null;
    if ((now ?? DateTime.now()).difference(entry.cachedAt) > contentTtl) {
      _content.remove(key);
      _contentBytes -= entry.bytes;
      return null;
    }
    _content.remove(key);
    _content[key] = entry;
    return entry.file;
  }

  void cacheContent(
    String sessionId,
    String? directory,
    String path,
    StreamedFile file,
  ) {
    final bytes = file.bytes?.length ?? file.text?.length ?? 0;
    if (bytes > maxSingleFileBytes) return;
    final key = _contentKey(sessionId, directory, path);
    final old = _content.remove(key);
    if (old != null) _contentBytes -= old.bytes;
    _content[key] = _ContentEntry(file, bytes, DateTime.now());
    _contentBytes += bytes;
    while (_contentBytes > maxContentBytes && _content.isNotEmpty) {
      final evicted = _content.remove(_content.keys.first);
      _contentBytes -= evicted?.bytes ?? 0;
    }
  }

  void invalidateContentForSession(String sessionId) {
    final prefix = '$sessionId|';
    for (final k in _content.keys.where((k) => k.startsWith(prefix)).toList()) {
      final e = _content.remove(k);
      _contentBytes -= e?.bytes ?? 0;
    }
  }
}
