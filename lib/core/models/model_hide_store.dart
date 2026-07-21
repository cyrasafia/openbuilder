import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Persists a per-server set of models the user hid from the model picker.
///
/// opencode's HTTP API exposes no model-level enable/disable signal: every
/// configured provider's models arrive as `status: active` with no `enabled`
/// flag. Hiding is therefore a client-only preference, keyed by the
/// `connectionStore.activeId` (the server profile id). Keys are
/// `providerID/modelId` strings.
class ModelHideStore extends ChangeNotifier {
  static const _key = 'opencode.hidden-models.v1';
  static const _storage = FlutterSecureStorage();

  final Map<String, Set<String>> _hidden = {};
  bool _loaded = false;

  bool get loaded => _loaded;

  static String makeKey(String providerID, String id) => '$providerID/$id';

  bool isHidden(String? serverId, String providerID, String id) {
    if (serverId == null) return false;
    return _hidden[serverId]?.contains(makeKey(providerID, id)) ?? false;
  }

  Future<void> load() async {
    final raw = await _storage.read(key: _key);
    if (raw != null) {
      try {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        _hidden.clear();
        for (final e in d.entries) {
          _hidden[e.key] =
              (e.value as List).map((x) => x.toString()).toSet();
        }
      } catch (_) {
        _hidden.clear();
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> hide(String serverId, String providerID, String id) async {
    final k = makeKey(providerID, id);
    final set = _hidden[serverId] ??= {};
    if (!set.add(k)) return;
    await _save();
  }

  Future<void> unhide(String serverId, String providerID, String id) async {
    final set = _hidden[serverId];
    if (set == null || !set.remove(makeKey(providerID, id))) return;
    if (set.isEmpty) _hidden.remove(serverId);
    await _save();
  }

  Future<void> _save() async {
    final data = jsonEncode(
      _hidden.map((k, v) => MapEntry(k, v.toList())),
    );
    await _storage.write(key: _key, value: data);
    notifyListeners();
  }
}