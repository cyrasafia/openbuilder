import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../cache/cache_store.dart';
import 'connection_profile.dart';

/// Persisted list of configured opencode servers + the active one.
class ConnectionStore extends ChangeNotifier {
  static const _key = 'opencode.servers.v1';
  static const _storage = FlutterSecureStorage();

  List<ConnectionProfile> _servers = [];
  String? _activeId;
  bool _loaded = false;
  final Set<String> _authBrokenIds = {};

  List<ConnectionProfile> get servers => List.unmodifiable(_servers);
  String? get activeId => _activeId;
  bool get loaded => _loaded;
  bool get isEmpty => _servers.isEmpty;

  bool isAuthBroken(String id) => _authBrokenIds.contains(id);

  void markAuthBroken(String id) {
    if (_authBrokenIds.add(id)) notifyListeners();
  }

  void clearAuthBroken(String id) {
    if (_authBrokenIds.remove(id)) notifyListeners();
  }

  ConnectionProfile? byId(String id) {
    for (final s in _servers) {
      if (s.id == id) return s;
    }
    return null;
  }

  ConnectionProfile? get active {
    if (_activeId == null) return null;
    return byId(_activeId!);
  }

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        _servers = (d['servers'] as List? ?? [])
            .map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>))
            .toList(growable: true);
        _activeId = d['activeId'] as String?;
        if (_activeId != null && byId(_activeId!) == null) {
          _activeId = _servers.isEmpty ? null : _servers.first.id;
        }
      } catch (_) {
        _servers = [];
        _activeId = null;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> add(ConnectionProfile p) async {
    _servers.add(p);
    _activeId ??= p.id;
    await _save();
  }

  Future<void> update(ConnectionProfile p) async {
    for (var i = 0; i < _servers.length; i++) {
      if (_servers[i].id == p.id) {
        _servers[i] = p;
        break;
      }
    }
    clearAuthBroken(p.id);
    await _save();
  }

  Future<void> remove(String id) async {
    _servers.removeWhere((s) => s.id == id);
    if (_activeId == id) {
      _activeId = _servers.isEmpty ? null : _servers.first.id;
    }
    clearAuthBroken(id);
    await _save();
    // Drop the profile's whole cache namespace (server + all conv_*). Needs
    // only the profile id — the per-profile directory is the mapping.
    await FileCacheStore.removeProfile(id);
  }

  Future<void> setActive(String id) async {
    if (byId(id) == null) return;
    _activeId = id;
    await _save();
  }

  Future<void> _save() async {
    final data = jsonEncode({
      'activeId': _activeId,
      'servers': _servers.map((s) => s.toJson()).toList(),
    });
    await _storage.write(key: _key, value: data);
    notifyListeners();
  }
}
