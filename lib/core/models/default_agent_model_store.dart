import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../domain/models.dart';

class DefaultAgentModelStore extends ChangeNotifier {
  static const _key = 'opencode.default-model.v1';
  static const _storage = FlutterSecureStorage();

  final Map<String, ModelRef> _defaults = {};
  bool _loaded = false;

  bool get loaded => _loaded;

  ModelRef? getDefaultModel(String? serverId) {
    if (serverId == null) return null;
    return _defaults[serverId];
  }

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        _defaults.clear();
        for (final e in d.entries) {
          final v = e.value as Map<String, dynamic>;
          _defaults[e.key] = ModelRef(
            id: (v['id'] ?? '').toString(),
            providerID: (v['providerID'] ?? '').toString(),
            variant: v['variant']?.toString(),
          );
        }
      } catch (_) {
        _defaults.clear();
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> saveDefaultModel(String? serverId, ModelRef model) async {
    if (serverId == null) return;
    _defaults[serverId] = model;
    await _save();
  }

  Future<void> _save() async {
    final data = jsonEncode(
      _defaults.map((k, v) => MapEntry(k, v.toJson())),
    );
    await _storage.write(key: _key, value: data);
    notifyListeners();
  }
}