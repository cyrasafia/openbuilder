import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../../data/api/opencode_client.dart';
import '../../domain/models.dart';
import '../connection/connection_profile.dart';
import '../net/dio_factory.dart';
import '../notifications/notification_service.dart';
import '../sse/sse_client.dart';
import 'conversation_store.dart';

/// Live, per-active-server state: projects / sessions / status / latest-message
/// preview, plus lazy per-session [ConversationStore] caches. Fed by one SSE
/// subscription to `/event` (specs §5, frontend §2.2).
class ServerStore extends ChangeNotifier {
  OpencodeClient? client;
  /// One SSE subscription per project directory. opencode's `/event` stream is
  /// scoped to a `directory` (no directory ⇒ only `server.connected`), so we
  /// open one connection per directory to receive that project's live events.
  final Map<String, SseClient> _sseByDir = {};
  final Map<String, StreamSubscription<OpencodeEvent>> _sseSubs = {};
  final Map<String, StreamSubscription<SseState>> _sseStateSubs = {};
  final Map<String, SseState> _stateByDir = {};
  Map<String, String> _sseHeaders = {};
  Timer? _reconcileTimer;
  ConnectionProfile? _profile;

  // ── Self-healing state ──
  String? _activeSessionId;
  bool _needsStaleMarking = false;
  String? _resumeReloadedSessionId;

  /// Pending permissions keyed by sessionId (fed by SSE + REST backfill).
  final Map<String, Permission> _pendingPermissions = {};

  /// True while the SSE connection is in backoff reconnect (specs §11 banner).
  bool reconnecting = false;
  /// Current reconnect attempt (1-based); 0 when connected / idle.
  int reconnectAttempt = 0;

  List<ProjectModel> _projects = [];
  List<SessionModel> _sessions = [];
  final Map<String, SessionStatusValue> _statusMap = {};
  final Map<String, String> _lastMessage = {};
  /// Per-session conversation caches, capped at [_kMaxConversations] with
  /// LRU eviction (oldest accessed evicted on insert). Uses a LinkedHashMap
  /// so iteration order reflects access recency.
  final LinkedHashMap<String, ConversationStore> _conversations =
      LinkedHashMap<String, ConversationStore>();
  static const _kMaxConversations = 20;
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

  bool hasPendingPermission(String sessionId) =>
      _pendingPermissions.containsKey(sessionId);

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

  void setActiveConversation(String? sid) {
    _activeSessionId = sid;
  }

  ConversationStore? conversationFor(String sessionId, {bool force = false}) {
    final existing = _conversations[sessionId];
    if (existing != null) {
      _conversations.remove(sessionId);
      _conversations[sessionId] = existing;
      if (existing.isStale) {
        unawaited(force ? existing.reload() : existing.reloadIfStale());
      }
      return existing;
    }
    final c = client;
    if (c == null) return null;
    final conv = ConversationStore(sessionId, c);
    _conversations[sessionId] = conv;
    // LRU eviction: drop the oldest entries while over capacity.
    while (_conversations.length > _kMaxConversations) {
      final oldest = _conversations.keys.first;
      _conversations.remove(oldest);
    }
    conv.status = statusOf(sessionId).type;
    // Inject any pending permission known from SSE/REST backfill.
    final pending = _pendingPermissions[sessionId];
    if (pending != null) {
      conv.onPermission(pending);
    }
    unawaited(conv.load());
    // After loading, backfill the list preview (frontend §2.2 D4 compromise).
    unawaited(_backfillPreview(sessionId, conv));
    return conv;
  }

  Future<void> connect(ConnectionProfile profile) async {
    // Idempotent: no-op if already connected with same server + credentials.
    // On bootstrap failure connected stays false, so a retry (calling
    // connect again with the same profile) bypasses this guard and re-runs.
    if (_profile != null &&
        _profile!.id == profile.id &&
        _signature(_profile!) == _signature(profile) &&
        client != null &&
        connected) {
      return;
    }
    _profile = profile;
    await _teardown();
    final dio = dioFor(profile);
    client = OpencodeClient(dio);
    _sseHeaders = Map.from(dio.options.headers.map(
        (k, v) => MapEntry(k, v is String ? v : v.toString())));
    final ok = await _bootstrap();
    if (!ok) {
      // Bootstrap failed: stay disconnected with a clear error. Don't start
      // SSE — there's no point streaming from a server we can't talk to.
      connected = false;
      notifyListeners();
      return;
    }
    // Always open a bare `/event` as a global watchdog so we still receive
    // `server.connected` (and any future un-scoped events) even when the
    // server has zero projects/sessions — without it an empty server would
    // open no SSE at all and miss newly-created sessions until a manual
    // refresh.
    _startSse(_kGlobalWatchdog);
    // Subscribe to `/event` once per project directory (specs §5: the stream
    // is directory-scoped — a bare `/event` only yields `server.connected`).
    for (final dir in _eventDirectories()) {
      _startSse(dir);
    }
    connected = true;
    notifyListeners();
  }

  /// Sentinel key for the always-on bare `/event` connection (no `directory`
  /// query). Kept distinct from any real directory path.
  static const _kGlobalWatchdog = '\u0000__global_watchdog__';

  /// Distinct directories to stream: every project's worktree plus every known
  /// session directory (covers sandbox worktrees too).
  Set<String> _eventDirectories() {
    final dirs = <String>{};
    for (final p in _projects) {
      if (p.worktree.isNotEmpty) dirs.add(p.worktree);
    }
    for (final s in _sessions) {
      if (s.directory.isNotEmpty) dirs.add(s.directory);
    }
    return dirs;
  }

  void _startSse(String key) {
    if (_sseByDir.containsKey(key)) return;
    final base = Uri.parse('${_profile!.baseUrl}/event');
    final uri = key == _kGlobalWatchdog
        ? base // bare /event — global watchdog
        : base.replace(queryParameters: {'directory': key});
    final c = SseClient(uri: uri, headers: _sseHeaders);
    _sseByDir[key] = c;
    _sseSubs[key] =
        c.events.listen(_onEvent, onError: (Object e) => error = '$e');
    _sseStateSubs[key] = c.state.listen((s) => _onSseState(key, s));
    c.start();
  }

  String _signature(ConnectionProfile p) =>
      '${p.baseUrl}|${p.username}|${p.password}';

  Future<bool> _bootstrap() async {
    try {
      final projects = await client!.projects();
      final sessions = await _fetchAllSessions();
      final status =
          await _fetchAllStatuses(projects: projects, sessions: sessions);
      _projects = projects;
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      error = null;
      return true;
    } catch (e) {
      error = '$e';
      return false;
    }
  }

  /// Aggregate session status across all project + session directories.
  /// Without a directory, GET /session/status returns `{}`, so we must query
  /// per-dir. Includes sandbox worktree directories (SS-1: must match the
  /// directory coverage of _eventDirectories / _fetchAllSessions).
  Future<Map<String, SessionStatusValue>> _fetchAllStatuses({
    required List<ProjectModel> projects,
    List<SessionModel> sessions = const [],
  }) async {
    final dirs = <String>{};
    for (final p in projects) {
      if (p.worktree.isNotEmpty) dirs.add(p.worktree);
    }
    for (final s in sessions) {
      if (s.directory.isNotEmpty) dirs.add(s.directory);
    }
    final results = await Future.wait(dirs.map((dir) async {
      try {
        return await client!.sessionStatus(directory: dir);
      } catch (_) {
        return const <String, SessionStatusValue>{};
      }
    }));
    final out = <String, SessionStatusValue>{};
    for (final r in results) {
      out.addAll(r);
    }
    return out;
  }

  /// Aggregate sessions across all projects. For each project, fetches
  /// unarchived sessions for its main worktree AND every sandbox worktree
  /// (via `/experimental/worktree`), so multi-worktree projects like plan-travel
  /// show all their conversations. Subtask/child sessions (`parentID` set) and
  /// archived sessions are skipped, matching the opencode web UI.
  ///
  /// All per-project and per-worktree requests run concurrently via
  /// [Future.wait] (instead of N×M serial round-trips), so a large server with
  /// many projects/worktrees doesn't stall the first screen.
  Future<List<SessionModel>> _fetchAllSessions() async {
    final futures = <Future<List<SessionModel>>>[];
    for (final p in _projects) {
      if (p.id == 'global') {
        futures.add(client!.sessions());
      } else {
        futures.add(_sessionsForProject(p));
      }
    }
    final results = await Future.wait(futures);
    final all = <String, SessionModel>{};
    for (final list in results) {
      _addSessions(all, list);
    }
    return all.values.toList();
  }

  /// Sessions for one project: resolve its worktrees, then fetch sessions for
  /// the main worktree and every worktree in parallel.
  Future<List<SessionModel>> _sessionsForProject(ProjectModel p) async {
    final dirs = [p.worktree, ...await _safeWorktrees(p.worktree)]
        .where((d) => d.isNotEmpty)
        .toList();
    final lists = await Future.wait(dirs.map((dir) async {
      try {
        return await client!.sessionsForDirectory(dir);
      } catch (_) {
        return const <SessionModel>[]; // non-git / inaccessible worktree
      }
    }));
    final out = <SessionModel>[];
    for (final list in lists) {
      out.addAll(list);
    }
    return out;
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

  /// Coalesce the many `server.connected` events (one per directory
  /// connection) into a single reconcile shortly after connect.
  void _scheduleReconcile() {
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_reconcile());
    });
  }

  Future<void> _reconcile() async {
    // server.connected: refresh authoritative state.
    if (client == null) return;
    try {
      final sessions = await _fetchAllSessions();
      final status =
          await _fetchAllStatuses(projects: _projects, sessions: sessions);
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      for (final conv in _conversations.values) {
        conv.setStatus(status[conv.sessionId]?.type ?? 'idle');
      }
      // Drop SSE for directories that vanished (sessions deleted / projects
      // removed) and add any newly-appeared directories.
      _pruneSse();
      for (final dir in _eventDirectories()) {
        _startSse(dir);
      }
      error = null;
    } catch (e) {
      error = '$e';
    }
    // R1: Conversation-layer healing lives OUTSIDE the try so it only
    // depends on conversation-level REST, not list/status fetching. A weak
    // network may fail _fetchAllSessions while messages() still works.
    final activeId = _activeSessionId;
    final activeConv =
        activeId != null ? _conversations[activeId] : null;
    if (activeConv != null) {
      if (activeId == _resumeReloadedSessionId) {
        _resumeReloadedSessionId = null;
      } else if (activeConv.busy) {
        activeConv.markStale();
      } else {
        unawaited(activeConv.reload());
      }
    }
    if (_needsStaleMarking) {
      for (final entry in _conversations.entries) {
        if (entry.key != activeId) {
          entry.value.markStale();
        }
      }
      _needsStaleMarking = false;
    }
    unawaited(_backfillPermissions());
    notifyListeners();
  }

  /// Fetch pending permissions via REST and route to cached conversations.
  /// SSE only pushes permission.asked at creation time — if the app wasn't
  /// listening, the event is missed. This backfills on connect/reconcile/resume.
  Future<void> _backfillPermissions() async {
    final c = client;
    if (c == null) return;
    final prev = Map.of(_pendingPermissions);
    _pendingPermissions.clear();
    // R-Perm-3: fetch per all event directories (includes sandbox worktrees),
    // not just main project worktrees, so sandbox session permissions are
    // covered.
    final dirs = _eventDirectories();
    final failedDirs = <String>{};
    for (final dir in dirs) {
      try {
        final pending = await c.pendingPermissions(dir);
        for (final perm in pending) {
          _pendingPermissions[perm.sessionID] = perm;
          _conversations[perm.sessionID]?.onPermission(perm);
        }
      } catch (_) {
        failedDirs.add(dir);
      }
    }
    // Only restore SSE-delivered permissions whose session's directory had a
    // failed REST fetch — successful fetches are authoritative.
    for (final entry in prev.entries) {
      final session = sessionById(entry.key);
      final dir = session?.directory ?? '';
      if (failedDirs.contains(dir) || dir.isEmpty || !dirs.contains(dir)) {
        _pendingPermissions.putIfAbsent(entry.key, () => entry.value);
      }
    }
    // R-Perm-1: notify if the permission map changed so list shield updates.
    final changed = prev.length != _pendingPermissions.length ||
        !prev.keys.toSet().containsAll(_pendingPermissions.keys);
    if (changed) {
      notifyListeners();
    }
  }

  void _onSseState(String dir, SseState s) {
    final wasReconnecting = _stateByDir[dir]?.reconnecting ?? false;
    _stateByDir[dir] = s;
    final anyReconnecting = _stateByDir.values.any((e) => e.reconnecting);
    final maxAttempt = _stateByDir.values
        .map((e) => e.attempt)
        .fold(0, (a, b) => a > b ? a : b);
    if (anyReconnecting != reconnecting || maxAttempt != reconnectAttempt) {
      reconnecting = anyReconnecting;
      reconnectAttempt = maxAttempt;
      notifyListeners();
    }
    // When a connection transitions from reconnecting → connected, trigger a
    // reconcile to catch up on anything missed during the disconnect (the
    // server may not always emit server.connected on every reconnect).
    if (wasReconnecting && !s.reconnecting) {
      _needsStaleMarking = true;
      _scheduleReconcile();
    }
  }

  void _onEvent(OpencodeEvent ev) {
    switch (ev.type) {
      case 'server.connected':
        _scheduleReconcile();
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
        if (sid != null) {
          // Only notify if the session was previously busy (not a spurious
          // idle on an already-idle session).
          final wasBusy = _statusMap[sid]?.type == 'busy';
          _statusMap[sid] = const SessionStatusValue('idle');
          if (wasBusy) {
            final title = sessionById(sid)?.title ?? '会话';
            unawaited(NotificationService.notifyRunComplete(title)
                .catchError((_) {}));
            final conv = _conversations[sid];
            if (conv != null && conv.isStale) {
              unawaited(conv.reload());
            }
          }
        }
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
      case 'permission.asked':
      case 'permission.v2.asked':
      case 'permission.updated': // compat fallback for older opencode versions
        final p = Permission.fromJson(ev.properties);
        _pendingPermissions[p.sessionID] = p;
        _conversations[p.sessionID]?.onPermission(p);
        final title = sessionById(p.sessionID)?.title ?? '会话';
        unawaited(
            NotificationService.notifyPermission(title, p.title).catchError((_) {}));
        break;
      case 'permission.replied':
      case 'permission.v2.replied':
        final sid = ev.properties['sessionID']?.toString();
        final pid = ev.properties['permissionID']?.toString();
        if (sid != null) {
          _pendingPermissions.removeWhere((_, p) => p.id == pid);
        }
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
    // MU-1: notify immediately so the list layer knows a message changed,
    // before the preview fetch (which may be slow on weak networks).
    notifyListeners();
    // Preview (frontend §2.2 D1/D2): refresh on message completion / user msg.
    if (m.role == 'user' || (m.finish != null && m.finish!.isNotEmpty)) {
      try {
        final entry = await client!.message(sid, m.id);
        final preview = _previewOf(entry);
        if (preview != null) {
          _lastMessage[sid] =
              (m.role == 'user' ? '你: ' : '') + preview;
          notifyListeners();
        }
      } catch (_) {}
    }
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
    // A session for a directory we aren't streaming yet (e.g. a brand-new
    // project) — start a scoped SSE so it receives live events too.
    if (s.directory.isNotEmpty && !_sseByDir.containsKey(s.directory)) {
      _startSse(s.directory);
    }
  }

  void _removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _conversations.remove(id);
    _pruneSse();
  }

  /// Stop SSE connections for directories that no longer have any session nor
  /// match a project worktree (keeps the connection count bounded — review §2).
  /// The global watchdog (`_kGlobalWatchdog`) is always retained.
  void _pruneSse() {
    final keep = <String>{_kGlobalWatchdog};
    for (final p in _projects) {
      if (p.worktree.isNotEmpty) keep.add(p.worktree);
    }
    for (final s in _sessions) {
      if (s.directory.isNotEmpty) keep.add(s.directory);
    }
    final stale = _sseByDir.keys.where((k) => !keep.contains(k)).toList();
    for (final k in stale) {
      _sseSubs[k]?.cancel();
      _sseSubs.remove(k);
      _sseStateSubs[k]?.cancel();
      _sseStateSubs.remove(k);
      _stateByDir.remove(k);
      _sseByDir[k]?.stop();
      _sseByDir.remove(k);
    }
  }

  Future<void> _teardown() async {
    await _stopSse();
    _conversations.clear();
  }

  Future<void> disconnect() async {
    connected = false;
    await _teardown();
    _projects = [];
    _sessions = [];
    _statusMap.clear();
    _lastMessage.clear();
    _pendingPermissions.clear();
    client = null;
    _profile = null;
    notifyListeners();
  }

  Future<void> refresh() async {
    if (client == null) return;
    final ok = await _bootstrap();
    if (ok && !connected) {
      // A refresh recovered a previously-failed connection: start SSE now.
      _startSse(_kGlobalWatchdog);
      for (final dir in _eventDirectories()) {
        _startSse(dir);
      }
      connected = true;
    }
    notifyListeners();
  }

  // ── App lifecycle (specs §5: background → pause, foreground → resume) ──

  /// Called when the app goes to background: stop SSE to save battery.
  /// Cached data (sessions, conversations) is retained for instant resume.
  /// All conversations are marked stale since we lose live SSE updates.
  Future<void> pause() async {
    if (!connected || _profile == null) return;
    for (final conv in _conversations.values) {
      conv.markStale();
    }
    await _stopSse();
  }

  /// Called when the app returns to foreground: restart SSE and do a full
  /// reconcile to catch up on anything missed while backgrounded.
  ///
  /// Only runs the heavy bootstrap+reload path when SSE was actually torn
  /// down by [pause] (backgrounded ≥30s). On a quick app switch the 30s
  /// pause timer is cancelled before firing, so SSE stays connected and
  /// buffered events drain naturally on resume — triggering a REST reload
  /// here would clear those SSE-delivered deltas with a stale snapshot
  /// (MU-2 race made deterministic), silently dropping a message segment.
  Future<void> resume() async {
    if (!connected || client == null || _profile == null) return;
    if (_sseByDir.isNotEmpty) {
      // SSE never stopped — events buffered while backgrounded are still
      // waiting in the socket and will be dispatched now that the event
      // loop is running again. A reload would clobber them; just backfill
      // permissions (idempotent) and let SSE continue.
      unawaited(_backfillPermissions());
      notifyListeners();
      return;
    }
    await _bootstrap();
    // Directly reload the active conversation — don't wait for the
    // server.connected SSE event (which may be delayed or whose reconcile
    // may fail before reaching the reload step on weak networks).
    final activeId = _activeSessionId;
    final activeConv =
        activeId != null ? _conversations[activeId] : null;
    if (activeConv != null) {
      // Sync conv status from _bootstrap's fresh _statusMap — pause may have
      // missed a session.idle event, leaving conv.status stuck on 'busy'.
      activeConv.setStatus(_statusMap[activeId]?.type ?? 'idle');
      if (activeConv.busy) {
        activeConv.markStale();
      } else {
        unawaited(activeConv.reload());
        _resumeReloadedSessionId = activeId;
      }
    }
    _startSse(_kGlobalWatchdog);
    for (final dir in _eventDirectories()) {
      _startSse(dir);
    }
    unawaited(_backfillPermissions());
    notifyListeners();
  }

  /// Stop all SSE connections without clearing cached data (used by pause).
  Future<void> _stopSse() async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    for (final sub in _sseSubs.values) {
      await sub.cancel();
    }
    _sseSubs.clear();
    for (final sub in _sseStateSubs.values) {
      await sub.cancel();
    }
    _sseStateSubs.clear();
    for (final c in _sseByDir.values) {
      await c.stop();
    }
    _sseByDir.clear();
    _stateByDir.clear();
    // Reset public reconnect indicators so the banner doesn't linger after
    // all connections are torn down (pause / teardown / disconnect).
    reconnecting = false;
    reconnectAttempt = 0;
  }
}
