import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/api/opencode_client.dart';
import '../../domain/models.dart';
import '../connection/connection_profile.dart';
import '../net/dio_factory.dart';
import '../sse/sse_client.dart';
import 'conversation_store.dart';

/// Live, per-active-server state: projects / sessions / status / latest-message
/// preview, plus lazy per-session [ConversationStore] caches. Fed by one SSE
/// subscription to `/event` (specs §5, frontend §2.2).
class ServerStore extends ChangeNotifier {
  OpencodeClient? client;
  SseClient? _sse;
  StreamSubscription<OpencodeEvent>? _sseSub;
  ConnectionProfile? _profile;

  List<ProjectModel> _projects = [];
  List<SessionModel> _sessions = [];
  final Map<String, SessionStatusValue> _statusMap = {};
  final Map<String, String> _lastMessage = {};
  final Map<String, ConversationStore> _conversations = {};
  bool connected = false;
  String? error;

  List<ProjectModel> get projects => List.unmodifiable(_projects);
  List<SessionModel> get sessions => List.unmodifiable(_sessions);

  Iterable<SessionModel> sortedSessions() {
    final list = [..._sessions]..sort((a, b) => b.updated.compareTo(a.updated));
    return list;
  }

  SessionStatusValue statusOf(String id) =>
      _statusMap[id] ?? const SessionStatusValue('idle');

  String? lastMessageOf(String id) => _lastMessage[id];

  ProjectModel? projectOf(String id) {
    for (final p in _projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  SessionModel? sessionById(String id) {
    for (final s in _sessions) {
      if (s.id == id) return s;
    }
    return null;
  }

  String projectDisplayOf(SessionModel s) {
    if (s.projectID == 'global') {
      return s.dirName.isEmpty ? 'global' : s.dirName;
    }
    return projectOf(s.projectID)?.displayName ??
        (s.dirName.isNotEmpty
            ? s.dirName
            : 'project-${s.projectID.substring(0, 8)}');
  }

  /// Worktree/directory name to show for a session, or '' when it should be
  /// hidden: single-worktree projects (no ambiguity) and the `global` project
  /// where the folder name is already shown as the project name.
  String worktreeDisplayOf(SessionModel s) {
    if (s.projectID == 'global') return '';
    if (_hasMultipleWorktrees(s.projectID)) return s.dirName;
    return '';
  }

  bool _hasMultipleWorktrees(String projectID) {
    final dirs = <String>{};
    for (final s in _sessions) {
      if (s.projectID == projectID && s.directory.isNotEmpty) {
        dirs.add(s.directory);
        if (dirs.length > 1) return true;
      }
    }
    return false;
  }

  ConversationStore? conversationFor(String sessionId) {
    final existing = _conversations[sessionId];
    if (existing != null) return existing;
    final c = client;
    if (c == null) return null;
    final conv = ConversationStore(sessionId, c);
    _conversations[sessionId] = conv;
    conv.status = statusOf(sessionId).type;
    unawaited(conv.load());
    // After loading, backfill the list preview (frontend §2.2 D4 compromise).
    unawaited(_backfillPreview(sessionId, conv));
    return conv;
  }

  Future<void> connect(ConnectionProfile profile) async {
    // Idempotent: no-op if same server + credentials already connected.
    if (_profile != null &&
        _profile!.id == profile.id &&
        _signature(_profile!) == _signature(profile) &&
        client != null) {
      return;
    }
    _profile = profile;
    await _teardown();
    final dio = dioFor(profile);
    client = OpencodeClient(dio);
    _sse = SseClient(
      uri: Uri.parse('${profile.baseUrl}/event'),
      headers: Map.from(dio.options.headers.map(
          (k, v) => MapEntry(k, v is String ? v : v.toString()))),
    );
    await _bootstrap();
    _sseSub = _sse!.events.listen(_onEvent, onError: (Object e) => error = '$e');
    _sse!.start();
    connected = true;
    notifyListeners();
  }

  String _signature(ConnectionProfile p) =>
      '${p.baseUrl}|${p.username}|${p.password}';

  Future<void> _bootstrap() async {
    try {
      final projects = await client!.projects();
      final sessions = await _fetchAllSessions();
      final status = await client!.sessionStatus();
      _projects = projects;
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      error = null;
    } catch (e) {
      error = '$e';
    }
  }

  /// Aggregate sessions across all projects. For each project, fetches
  /// unarchived sessions for its main worktree AND every sandbox worktree
  /// (via `/experimental/worktree`), so multi-worktree projects like plan-travel
  /// show all their conversations. Subtask/child sessions (`parentID` set) and
  /// archived sessions are skipped, matching the opencode web UI.
  Future<List<SessionModel>> _fetchAllSessions() async {
    final all = <String, SessionModel>{};
    for (final p in _projects) {
      if (p.id == 'global') {
        _addSessions(all, await client!.sessions());
        continue;
      }
      final dirs = [p.worktree, ...await _safeWorktrees(p.worktree)];
      for (final dir in dirs) {
        if (dir.isEmpty) continue;
        try {
          _addSessions(all, await client!.sessionsForDirectory(dir));
        } catch (_) {
          // non-git / inaccessible worktree — skip
        }
      }
    }
    return all.values.toList();
  }

  Future<List<String>> _safeWorktrees(String directory) async {
    try {
      return await client!.worktrees(directory);
    } catch (_) {
      return const [];
    }
  }

  void _addSessions(Map<String, SessionModel> out, List<SessionModel> list) {
    for (final s in list) {
      if (s.archived != null) continue; // archived
      if (s.parentID != null) continue; // subtask / child session
      out[s.id] = s;
    }
  }

  Future<void> _reconcile() async {
    // server.connected: refresh authoritative state.
    if (client == null) return;
    try {
      final sessions = await _fetchAllSessions();
      final status = await client!.sessionStatus();
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      for (final conv in _conversations.values) {
        conv.setStatus(status[conv.sessionId]?.type ?? 'idle');
      }
      error = null;
    } catch (e) {
      error = '$e';
    }
    notifyListeners();
  }

  void _onEvent(OpencodeEvent ev) {
    switch (ev.type) {
      case 'server.connected':
        unawaited(_reconcile());
        return; // _reconcile notifies
      case 'session.status':
        final sid = ev.properties['sessionID']?.toString();
        final st = ev.properties['status'];
        if (sid != null && st is Map) {
          _statusMap[sid] = SessionStatusValue.fromJson(st.cast());
          _conversations[sid]?.setStatus(_statusMap[sid]!.type);
        }
        break;
      case 'session.idle':
        final sid = ev.properties['sessionID']?.toString();
        if (sid != null) _statusMap[sid] = const SessionStatusValue('idle');
        break;
      case 'session.created':
      case 'session.updated':
        final info = ev.properties['info'];
        if (info is Map) _upsertSession(SessionModel.fromJson(info.cast()));
        break;
      case 'session.deleted':
        final info = ev.properties['info'];
        if (info is Map) _removeSession((info['id'] ?? '').toString());
        break;
      case 'message.updated':
        unawaited(_onMessageUpdated(ev.properties));
        return;
      case 'message.part.updated':
        final part = ev.properties['part'];
        final sid = part is Map ? part['sessionID']?.toString() : null;
        final delta = ev.properties['delta']?.toString();
        if (sid != null && part is Map) {
          _conversations[sid]?.onPartUpdated(part.cast(), delta);
        }
        break;
      case 'todo.updated':
        final sid = ev.properties['sessionID']?.toString();
        final todos = ev.properties['todos'];
        if (sid != null && todos is List) {
          final list = todos
              .map((e) => Todo.fromJson((e as Map).cast<String, dynamic>()))
              .toList();
          _conversations[sid]?.onTodosUpdated(list);
        }
        break;
      case 'permission.updated':
        final p = Permission.fromJson(ev.properties);
        _conversations[p.sessionID]?.onPermission(p);
        break;
      case 'permission.replied':
        final sid = ev.properties['sessionID']?.toString();
        final pid = ev.properties['permissionID']?.toString();
        if (sid != null && pid != null) {
          _conversations[sid]?.onPermissionReplied(pid);
        }
        break;
    }
    notifyListeners();
  }

  Future<void> _onMessageUpdated(Map<String, dynamic> props) async {
    final infoRaw = props['info'];
    if (infoRaw is! Map) return;
    final m = MessageInfo.fromJson(infoRaw.cast<String, dynamic>());
    final sid = m.sessionID;
    if (sid == null || sid.isEmpty) return;
    _conversations[sid]?.onMessageUpdated(m);
    // Preview (frontend §2.2 D1/D2): refresh on message completion / user msg.
    if (m.role == 'user' || (m.finish != null && m.finish!.isNotEmpty)) {
      try {
        final entry = await client!.message(sid, m.id);
        final preview = _previewOf(entry);
        if (preview != null) {
          _lastMessage[sid] =
              (m.role == 'user' ? '你: ' : '') + preview;
        }
      } catch (_) {}
    }
    notifyListeners();
  }

  String? _previewOf(MessageEntry entry) {
    for (var i = entry.parts.length - 1; i >= 0; i--) {
      final p = entry.parts[i];
      if (const {'step-start', 'step-finish', 'snapshot', 'retry', 'compaction'}
          .contains(p.type)) {
        continue;
      }
      final pv = p.preview.replaceAll('\n', ' ').trim();
      if (pv.isNotEmpty) return pv;
    }
    return null;
  }

  Future<void> _backfillPreview(String sid, ConversationStore conv) async {
    // After the conversation loads, surface its last message as the list preview
    // (avoids bulk-proactive fetch but keeps viewed sessions informative).
    if (conv.messages.isEmpty) return;
    final last = conv.messages.last;
    var preview = '';
    for (var i = last.parts.length - 1; i >= 0; i--) {
      final dp = last.parts[i];
      final pv = dp.type == 'tool'
          ? '${dp.tool ?? 'tool'}${dp.toolStatus == null ? '' : ' · ${dp.toolStatus}'}'
          : dp.text.replaceAll('\n', ' ').trim();
      if (pv.isNotEmpty) {
        preview = pv;
        break;
      }
    }
    if (preview.isNotEmpty) {
      _lastMessage[sid] =
          (last.info.role == 'user' ? '你: ' : '') + preview;
      notifyListeners();
    }
  }

  void _upsertSession(SessionModel s) {
    // Drop archived sessions and subtask/child sessions from the active list.
    if (s.archived != null || s.parentID != null) {
      _sessions.removeWhere((x) => x.id == s.id);
      return;
    }
    final idx = _sessions.indexWhere((x) => x.id == s.id);
    if (idx == -1) {
      _sessions.add(s);
    } else {
      _sessions[idx] = s;
    }
  }

  void _removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _conversations.remove(id);
  }

  Future<void> _teardown() async {
    await _sseSub?.cancel();
    _sseSub = null;
    await _sse?.stop();
    _sse = null;
    _conversations.clear();
  }

  Future<void> disconnect() async {
    connected = false;
    await _teardown();
    _projects = [];
    _sessions = [];
    _statusMap.clear();
    _lastMessage.clear();
    client = null;
    _profile = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (client == null) return;
    await _bootstrap();
    notifyListeners();
  }
}
