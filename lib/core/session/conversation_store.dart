import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/api/opencode_client.dart';
import '../../../domain/models.dart';

/// Mutable, render-friendly part for the conversation view.
class DisplayPart {
  final String id;
  final String type; // text | reasoning | tool | agent | subtask | file | ...
  String? tool;
  String text;
  String? toolStatus;
  String? toolOutput;

  DisplayPart({
    required this.id,
    required this.type,
    this.tool,
    this.text = '',
    this.toolStatus,
    this.toolOutput,
  });

  factory DisplayPart.from(MessagePart p) {
    if (p.type == 'tool') {
      return DisplayPart(
        id: p.id,
        type: p.type,
        tool: p.tool,
        toolStatus: p.stateStatus,
        toolOutput: p.stateOutput,
      );
    }
    return DisplayPart(id: p.id, type: p.type, text: p.text ?? '');
  }
}

class DisplayMessage {
  final MessageInfo info;
  final List<DisplayPart> parts = [];
  DisplayMessage(this.info);
}

/// Per-session live state: messages (streaming), todos, permissions.
class ConversationStore extends ChangeNotifier {
  final String sessionId;
  final OpencodeClient client;

  ConversationStore(this.sessionId, this.client);

  final List<DisplayMessage> _messages = [];
  List<Todo> _todos = [];
  final List<Permission> _permissions = [];
  bool loading = false;
  bool loaded = false;
  String? error;
  String status = 'idle';

  bool _stale = false;
  bool _reloading = false;
  DateTime? _lastReloadAt;
  static const _reloadBackoff = Duration(seconds: 10);

  List<DisplayMessage> get messages => List.unmodifiable(_messages);
  List<Todo> get todos => List.unmodifiable(_todos);
  List<Permission> get permissions => List.unmodifiable(_permissions);
  bool get busy => status == 'busy' || status == 'retry';

  // ── Self-healing public API ──

  bool get isStale => _stale;
  void markStale() => _stale = true;

  Future<void> reloadIfStale() async {
    if (!_stale || _reloading) return;
    if (_lastReloadAt != null &&
        DateTime.now().difference(_lastReloadAt!) < _reloadBackoff) {
      return;
    }
    await reload();
  }

  static const _hidden = {
    'step-start',
    'step-finish',
    'snapshot',
    'retry',
    'compaction',
  };

  Future<void> load() async {
    if (loaded || loading) return;
    loading = true;
    notifyListeners();
    try {
      final entries = await client.messages(sessionId);
      _messages
        ..clear()
        ..addAll(entries.map(_toDisplay));
      try {
        _todos = await client.todos(sessionId);
      } catch (_) {}
      loaded = true;
      error = null;
      unawaited(_saveCache());
    } catch (e) {
      error = '$e';
      // Offline fallback: restore last-known messages from local cache so the
      // user can still review the conversation (specs §5, plan item 19).
      await _loadCache();
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  Future<void> reload() async {
    if (_reloading) return;
    _reloading = true;
    _lastReloadAt = DateTime.now();
    try {
      final entries = await client.messages(sessionId);
      _messages
        ..clear()
        ..addAll(entries.map(_toDisplay));
      try {
        _todos = await client.todos(sessionId);
      } catch (_) {}
      loaded = true;
      error = null;
      _stale = false;
      unawaited(_saveCache());
    } catch (_) {
      _stale = true;
      // Only restore from cache if we have no data at all — if SSE has been
      // delivering messages (_messages is non-empty), that data is always more
      // current than the cache (saved during the last successful load/reload).
      // Overwriting SSE-delivered messages with stale cache causes data loss
      // when switching sessions on flaky networks.
      if (_messages.isEmpty) {
        await _loadCache();
      }
    } finally {
      _reloading = false;
    }
    notifyListeners();
  }

  // ── Local cache for offline read-back ──

  String get _cacheKey => 'conv_$sessionId';

  Future<void> _saveCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final j = {
        'messages': _messages
            .map((m) => {
                  'info': m.info.toJson(),
                  'parts': m.parts
                      .map((p) => {
                            'id': p.id,
                            'type': p.type,
                            'tool': p.tool,
                            'text': p.text,
                            'toolStatus': p.toolStatus,
                            'toolOutput': p.toolOutput,
                          })
                      .toList(),
                })
            .toList(),
        'todos': _todos.map((t) => t.toJson()).toList(),
      };
      await prefs.setString(_cacheKey, jsonEncode(j));
    } catch (_) {}
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final msgs = j['messages'] as List? ?? [];
      _messages.clear();
      for (final m in msgs) {
        final m2 = m as Map<String, dynamic>;
        final info = MessageInfo.fromJson(
            (m2['info'] as Map).cast<String, dynamic>());
        final dm = DisplayMessage(info);
        for (final p in (m2['parts'] as List? ?? [])) {
          final p2 = p as Map<String, dynamic>;
          dm.parts.add(DisplayPart(
            id: p2['id']?.toString() ?? '',
            type: p2['type']?.toString() ?? 'text',
            tool: p2['tool']?.toString(),
            text: p2['text']?.toString() ?? '',
            toolStatus: p2['toolStatus']?.toString(),
            toolOutput: p2['toolOutput']?.toString(),
          ));
        }
        _messages.add(dm);
      }
      final todos = j['todos'] as List? ?? [];
      _todos = todos
          .map((t) => Todo.fromJson((t as Map).cast<String, dynamic>()))
          .toList();
      if (_messages.isNotEmpty) loaded = true;
    } catch (_) {}
  }

  DisplayMessage _toDisplay(MessageEntry e) {
    final m = DisplayMessage(e.info);
    for (final p in e.parts) {
      if (_hidden.contains(p.type)) continue;
      m.parts.add(DisplayPart.from(p));
    }
    return m;
  }

  void setStatus(String s) {
    status = s;
    notifyListeners();
  }

  void onMessageUpdated(MessageInfo info) {
    final existing = _findMessage(info.id);
    if (existing != null) {
      _messages.remove(existing);
      final recreated = DisplayMessage(info);
      recreated.parts.addAll(existing.parts);
      _messages.add(recreated);
    } else {
      _messages.add(DisplayMessage(info));
    }
    _sort();
    notifyListeners();
  }

  void onPartUpdated(Map<String, dynamic> partRaw, String? delta) {
    final p = MessagePart(partRaw);
    final mid = p.raw['messageID']?.toString();
    if (mid == null) return;
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    DisplayPart dp;
    final idx = msg.parts.indexWhere((x) => x.id == p.id);
    if (idx == -1) {
      // Insert only renderable part types; skip hidden ones.
      if (_hidden.contains(p.type)) return;
      dp = DisplayPart.from(p);
      msg.parts.add(dp);
    } else {
      dp = msg.parts[idx];
    }
    switch (p.type) {
      case 'tool':
        if (p.tool != null) dp.tool = p.tool;
        if (p.stateStatus != null) dp.toolStatus = p.stateStatus;
        if (p.stateOutput != null) dp.toolOutput = p.stateOutput;
        break;
      case 'text':
      case 'reasoning':
        if (delta != null && delta.isNotEmpty) {
          dp.text += delta;
        } else if ((p.text ?? '').isNotEmpty) {
          dp.text = p.text!;
        }
        break;
    }
    notifyListeners();
  }

  void onTodosUpdated(List<Todo> todos) {
    _todos = todos;
    notifyListeners();
  }

  void onPermission(Permission p) {
    final idx = _permissions.indexWhere((x) => x.id == p.id);
    if (idx == -1) {
      _permissions.add(p);
    } else {
      _permissions[idx] = p;
    }
    notifyListeners();
  }

  void onPermissionReplied(String permissionId) {
    _permissions.removeWhere((p) => p.id == permissionId);
    notifyListeners();
  }

  Future<void> respondPermission(Permission p, String response,
      {bool? remember}) async {
    await client.respondPermission(sessionId, p.id, response,
        remember: remember);
    onPermissionReplied(p.id);
  }

  DisplayMessage? _findMessage(String id) {
    for (final m in _messages) {
      if (m.info.id == id) return m;
    }
    return null;
  }

  DisplayMessage _ensureMessage(String id) {
    final found = _findMessage(id);
    if (found != null) return found;
    final m = DisplayMessage(MessageInfo(
      id: id,
      role: 'assistant',
      created: DateTime.now().millisecondsSinceEpoch,
    ));
    _messages.add(m);
    _sort();
    return m;
  }

  void _sort() {
    _messages.sort((a, b) => (a.info.created ?? 0).compareTo(b.info.created ?? 0));
  }
}
