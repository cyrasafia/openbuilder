import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/api/opencode_client.dart';
import '../../domain/models.dart';
import '../connection/connection_profile.dart';
import '../logging/app_logger.dart';
import '../net/dio_factory.dart';
import '../notifications/notification_service.dart';
import '../sse/sse_client.dart';
import 'conversation_store.dart';

const _tag = 'Server';

/// Live, per-active-server state: projects / sessions / status / latest-message
/// preview, plus lazy per-session [ConversationStore] caches. Fed by one SSE
/// subscription to `/event` (specs §5, frontend §2.2).
class ServerStore extends ChangeNotifier {
  @visibleForTesting
  static Duration sseStopTimeout = const Duration(seconds: 2);

  OpencodeClient? client;
  /// One SSE subscription per directory + watchdog. opencode's `/event` stream
  /// is scoped to a `directory` (no directory ⇒ only `server.connected` /
  /// `server.heartbeat`). We keep a watchdog (bare `/event`) for liveness and
  /// per-directory SSE only for busy/retry sessions + active conversation.
  final Map<String, SseClient> _sseByDir = {};
  final Map<String, StreamSubscription<OpencodeEvent>> _sseSubs = {};
  final Map<String, StreamSubscription<SseState>> _sseStateSubs = {};
  final Map<String, bool> _sseRequired = {}; // dir -> protected from LRU
  Map<String, String> _sseHeaders = {};
  Timer? _reconcileTimer;
  Timer? _previewNotifyTimer;
  Timer? _cacheSaveTimer;
  Timer? _healthProbeTimer;
  Future<void>? _pauseOperation;
  bool _foreground = true;
  int _healthProbeGeneration = 0;
  // Health probe interval while the watchdog SSE is reconnecting. Each tick
  // is one cheap GET /global/health; on success all clients are kicked out
  // of backoff. 5s bounds recovery detection (vs the 30s backoff ceiling)
  // while staying negligible for battery/traffic during long outages.
  @visibleForTesting
  static Duration healthProbeInterval = const Duration(seconds: 5);
  DateTime? _lastPreviewNotifyAt;
  static const _previewNotifyInterval = Duration(milliseconds: 120);
  ConnectionProfile? _profile;

  // ── On-demand SSE constants ──
  static const _kGlobalWatchdog = '\u0000__global_watchdog__';
  static const _kMaxIdleSseConnections = 5;
  static const kMaxRefreshInterval = Duration(seconds: 30);
  DateTime? _lastFullRefreshAt;

  // ── Self-healing state ──
  String? _activeSessionId;
  bool _needsStaleMarking = false;
  String? _resumeReloadedSessionId;

  /// Pending permissions keyed by sessionId (fed by SSE + REST backfill).
  final Map<String, Permission> _pendingPermissions = {};

  /// Pending questions keyed by questionId (fed by SSE + REST backfill).
  final Map<String, QuestionRequest> _pendingQuestions = {};

  /// 近期已解决的 question id → 登记时刻。reply/reject 命中 200 或 404 后
  /// 由 ConversationStore.onQuestionResolved 登记于此；backfill 重建 pending
  /// 时跳过未过期项，避免服务端列表清理延迟导致的「提交后又弹回」。
  /// TTL 过期后若服务端仍返回该卡（说明真没解决）再放出来（关键设计决策 4）。
  final Map<String, DateTime> _recentlyResolvedQuestions = {};

  /// 近期已解决的 permission id → 登记时刻（同上，覆盖权限卡）。
  final Map<String, DateTime> _recentlyResolvedPermissions = {};
  static const _resolvedTtl = Duration(seconds: 60);

  List<ProjectModel> _projects = [];
  List<SessionModel> _sessions = [];
  final Map<String, SessionStatusValue> _statusMap = {};
  final Map<String, String> _lastMessage = {};
  /// Monotonic max(`SessionModel.updated`) per project activity key — includes
  /// sessions that have since been archived. `/session` does not expose
  /// archived sessions over HTTP, so we capture `updated` while a session is
  /// still visible and keep it after archive. Without this, archiving the last
  /// active session in a project would evict it from `_sessions` and sink the
  /// project to the bottom of the projects tab. Keyed by `projectID`, or
  /// `'global\u0000$directory'` for the global project's per-directory entries
  /// (the global project is expanded into one list row per working directory).
  ///
  /// Unbounded in theory (one entry per projectID / per global directory ever
  /// seen), but acceptable on mobile: typical servers have tens of projects
  /// and a handful of global directories, so the map stays in the low hundreds
  /// of entries at most. Hard-deleting a session does NOT remove its project's
  /// entry (see `_removeSession`) — monotonicity holds across deletes too.
  final Map<String, int> _lastActivityByKey = {};
  final Map<String, bool> _workspaceEnabled = {};
  bool _projectsFetched = false;
  /// Per-session conversation caches, capped at [_kMaxConversations] with
  /// LRU eviction (oldest accessed evicted on insert). Uses a LinkedHashMap
  /// so iteration order reflects access recency.
  final LinkedHashMap<String, ConversationStore> _conversations =
      LinkedHashMap<String, ConversationStore>();
  static const _kMaxConversations = 20;
  bool connected = false;

  /// Whether the global watchdog SSE is actively connected (for status indicator).
  bool get sseConnected => _sseByDir.containsKey(_kGlobalWatchdog) &&
      _watchdogConnected;

  /// Whether the watchdog SSE is in reconnecting state.
  bool get sseReconnecting =>
      _sseByDir.containsKey(_kGlobalWatchdog) && !_watchdogConnected;

  /// Whether the SSE stream for a session's directory is connected.
  bool isSessionSseConnected(String sessionId) {
    if (!_watchdogConnected) return false;
    final session = sessionById(sessionId);
    if (session == null) return false;
    return _sseByDir.containsKey(session.directory);
  }
  bool _watchdogConnected = false;
  // Set true when watchdog transitions connected → disconnected.
  // Stays true after recovery — banner is controlled by !_watchdogConnected,
  // not _watchdogFailed (which just gates "has ever failed" to suppress
  // the banner on first connect).
  bool _watchdogFailed = false;

  /// Whether the initial bootstrap failed (for showing error view + retry).
  bool bootstrapFailed = false;

  /// Whether to show the "network disconnected" banner.
  bool get showDisconnectBanner => _watchdogFailed && !_watchdogConnected;

  List<ProjectModel> get projects => List.unmodifiable(_projects);
  List<SessionModel> get sessions => List.unmodifiable(_sessions);

  Iterable<SessionModel> sortedSessions() {
    final list = [..._sessions]..sort((a, b) => b.updated.compareTo(a.updated));
    return list;
  }

  SessionStatusValue statusOf(String id) =>
      _statusMap[id] ?? const SessionStatusValue('idle');

  String? lastMessageOf(String id) => _lastMessage[id];

  /// Max `updated` ever observed for [projectID] across all of its sessions
  /// (including ones later archived). Returns 0 if never observed. Drives
  /// project-list sort order so a project doesn't sink when its last active
  /// session is archived.
  int lastActivityForProject(String projectID) =>
      _lastActivityByKey[projectID] ?? 0;

  /// Same as [lastActivityForProject] but keyed by [directory] within the
  /// global project. Each working directory under `global` is shown as its own
  /// row in the projects tab, so activity is tracked per-directory.
  int lastActivityForGlobalDir(String directory) =>
      _lastActivityByKey['global\u0000$directory'] ?? 0;

  /// Monotonically bump the per-project activity timestamp for [s]. Only ever
  /// increases — archiving a session doesn't reset the project's recency.
  /// Called from `_addSessions` (REST bulk fetch) and `_upsertSession` (SSE
  /// insert/update, including the transition into archived).
  void _bumpLastActivity(SessionModel s) {
    if (s.updated <= 0) return;
    final key = s.projectID == 'global'
        ? 'global\u0000${s.directory}'
        : s.projectID;
    final current = _lastActivityByKey[key] ?? 0;
    if (s.updated > current) {
      _lastActivityByKey[key] = s.updated;
      _scheduleCacheSave();
    }
  }

  /// Throttled notify for streaming preview updates. The session list rebuilds
  /// on every [notifyListeners], so coalescing the burst of
  /// `message.part.updated` events (one per token) keeps the UI smooth while
  /// still tracking the latest content. Always emits a trailing notify so the
  /// final state is reflected.
  void _notifyPreviewChanged() {
    final now = DateTime.now();
    if (_lastPreviewNotifyAt == null ||
        now.difference(_lastPreviewNotifyAt!) >= _previewNotifyInterval) {
      _lastPreviewNotifyAt = now;
      _previewNotifyTimer?.cancel();
      _previewNotifyTimer = null;
      notifyListeners();
    } else {
      // Ensure a trailing notify so the final streaming state is reflected.
      _previewNotifyTimer ??= Timer(_previewNotifyInterval, () {
        _lastPreviewNotifyAt = DateTime.now();
        _previewNotifyTimer = null;
        notifyListeners();
      });
    }
  }

  bool hasPendingPermission(String sessionId) =>
      _pendingPermissions.containsKey(sessionId);

  bool hasPendingQuestion(String sessionId) =>
      _pendingQuestions.values.any((q) => q.sessionID == sessionId);

  AgentIndicatorState agentIndicatorStateOf(String sessionId) {
    final permissionCount = _pendingPermissions.containsKey(sessionId) ? 1 : 0;
    final questionCount = _pendingQuestions.values
        .where((q) => q.sessionID == sessionId)
        .length;
    final pendingCount = permissionCount + questionCount;
    if (pendingCount > 0) {
      return AgentIndicatorState(AgentRunState.paused,
          pauseReason: permissionCount > 0
              ? AgentPauseReason.permission
              : AgentPauseReason.choice,
          pendingCount: pendingCount);
    }
    return switch (statusOf(sessionId).type) {
      'busy' => const AgentIndicatorState(AgentRunState.working),
      'retry' => const AgentIndicatorState(AgentRunState.retrying),
      _ => const AgentIndicatorState(AgentRunState.idle),
    };
  }

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

  bool workspaceEnabled(String projectId) {
    if (projectId == 'global') return false;
    return _workspaceEnabled[projectId] ?? false;
  }

  void setWorkspaceEnabled(String projectId, bool enabled) {
    if (projectId == 'global') return;
    if (_workspaceEnabled[projectId] == enabled) return;
    _workspaceEnabled[projectId] = enabled;
    notifyListeners();
    _scheduleCacheSave();
  }

  /// `PATCH /project/{projectId}` — update name / icon. Replaces the cached
  /// project with the server-returned value and notifies listeners.
  ///
  /// Icon field semantics (see `OpencodeClient.updateProject`): a `null`
  /// argument omits the key (leave the stored value unchanged); an empty
  /// string `""` clears the stored value; any other string sets/replaces it.
  /// Pass `updateIcon: true` only when at least one icon field is being
  /// changed, to avoid a redundant no-op write.
  Future<ProjectModel> updateProject(
    String projectId, {
    String? name,
    bool updateIcon = false,
    String? iconUrl,
    String? iconOverride,
    String? iconColor,
  }) async {
    final activeClient = client;
    if (activeClient == null) throw StateError('未连接服务器');
    final updated = await activeClient.updateProject(
      projectId,
      name: name,
      updateIcon: updateIcon,
      iconUrl: iconUrl,
      iconOverride: iconOverride,
      iconColor: iconColor,
    );
    final idx = _projects.indexWhere((p) => p.id == projectId);
    if (idx >= 0) {
      _projects[idx] = updated;
    } else {
      _projects.add(updated);
    }
    _scheduleCacheSave();
    notifyListeners();
    return updated;
  }

  void _inferWorkspaceForNewProjects() {
    final hasWorkspaceSession = <String>{};
    for (final s in _sessions) {
      final ws = s.workspaceID;
      if (ws != null && ws.isNotEmpty) {
        hasWorkspaceSession.add(s.projectID);
      }
    }
    for (final p in _projects) {
      if (p.id == 'global') continue;
      if (_workspaceEnabled.containsKey(p.id)) continue;
      _workspaceEnabled[p.id] = hasWorkspaceSession.contains(p.id);
    }
  }

  Future<SessionModel> createSession(String directory) async {
    final activeClient = client;
    if (activeClient == null) throw StateError('未连接服务器');
    final session = await activeClient.createSession(directory);
    _upsertSession(session);
    notifyListeners();
    return session;
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
    final oldId = _activeSessionId;
    _activeSessionId = sid;
    // Ensure SSE for the new active session's directory (required).
    if (sid != null) {
      final s = sessionById(sid);
      if (s != null && s.directory.isNotEmpty) {
        _startSse(s.directory, required: true);
      }
    }
    // Old active session's SSE may be downgraded — trim.
    if (oldId != null && oldId != sid) {
      _trimSse();
    }
  }

  /// Ensure SSE is open for a session's directory (used when user sends a
  /// message or interacts with permission/question cards in the detail page).
  void ensureSseForSession(String sessionId) {
    final s = sessionById(sessionId);
    if (s != null && s.directory.isNotEmpty) {
      _startSse(s.directory, required: true);
    }
  }

  /// Ensure the session has an accumulation container in `_conversations`
  /// (no load). Used by SSE event routing so messages from sessions that were
  /// never opened in the detail view still accumulate. REST reconcile is
  /// deferred to [conversationFor] (detail-page open).
  ///
  /// Intentionally does NOT touch [_lastMessage]: the existing preview (set by
  /// a prior REST [_backfillPreview] or SSE settle) stays valid, and new SSE
  /// events update it via the per-unit preview path.
  ConversationStore? ensureConversation(String sid) {
    final existing = _conversations[sid];
    if (existing != null) return existing;
    final c = client;
    if (c == null) return null;
    final directory = sessionById(sid)?.directory ?? '';
    final conv = ConversationStore(sid, c, directory: directory);
    conv.onQuestionResolved = _markQuestionResolved;
    conv.onPermissionResolved = _markPermissionResolved;
    _conversations[sid] = conv;
    final initStatus = statusOf(sid);
    conv.setStatus(initStatus.type, retryMessage: initStatus.message);
    conv.sessionUpdated = sessionById(sid)?.updated;
    // Inject any pending permission/question known from SSE/REST backfill.
    final pending = _pendingPermissions[sid];
    if (pending != null) conv.onPermission(pending);
    for (final q in _pendingQuestions.values) {
      if (q.sessionID == sid) conv.onQuestion(q);
    }
    _evictConversations();
    return conv;
  }

  /// 回填已有 conv 的 directory（session 到达后补上，解决 question.asked
  /// 早于 session 加载的 SSE 竞态——否则 reply 会因 directory 空抛错）。
  void _backfillConversationDirectory(String sid, String directory) {
    if (directory.isEmpty) return;
    _conversations[sid]?.setDirectory(directory);
  }

  void _markQuestionResolved(String qid) {
    _recentlyResolvedQuestions[qid] = DateTime.now();
    _pendingQuestions.remove(qid);
    AppLogger.I.i(_tag, 'markQuestionResolved qid=$qid → guard for ${_resolvedTtl.inSeconds}s');
  }

  void _markPermissionResolved(String pid) {
    _recentlyResolvedPermissions[pid] = DateTime.now();
    _pendingPermissions.removeWhere((_, p) => p.id == pid);
    AppLogger.I.i(_tag, 'markPermissionResolved pid=$pid → guard for ${_resolvedTtl.inSeconds}s');
  }

  /// 懒清理过期的 _recentlyResolved 项。TTL 过期后若服务端仍返回该卡，
  /// 说明真没解决（如登记后又被重新 ask），此时应放回 UI。
  void _purgeExpiredResolved() {
    final now = DateTime.now();
    _recentlyResolvedQuestions.removeWhere(
        (_, t) => now.difference(t) > _resolvedTtl);
    _recentlyResolvedPermissions.removeWhere(
        (_, t) => now.difference(t) > _resolvedTtl);
  }

  /// LRU eviction: when over [_kMaxConversations], drop the oldest
  /// non-streaming entry. Sessions that are busy/retry or the active detail
  /// session are protected — evicting them mid-stream would lose accumulated
  /// content.
  void _evictConversations() {
    while (_conversations.length > _kMaxConversations) {
      String? victim;
      for (final sid in _conversations.keys) {
        final st = _statusMap[sid]?.type;
        final streaming =
            st == 'busy' || st == 'retry' || sid == _activeSessionId;
        if (streaming) continue;
        victim = sid; // LinkedHashMap order = access order; first non-streaming
        break;
      }
      if (victim == null) break; // all streaming this round — don't evict
      _conversations.remove(victim)?.dispose();
    }
  }

  /// Read-only access without LRU promote. Used by high-frequency callers
  /// (scroll listeners) to avoid map remove/insert on every event (IR-6).
  ConversationStore? conversationForRead(String sessionId) =>
      _conversations[sessionId];

  ConversationStore? conversationFor(String sessionId, {bool force = false}) {
    final existing = _conversations[sessionId];
    if (existing != null) {
      _conversations.remove(sessionId);
      _conversations[sessionId] = existing; // LRU promote
      existing.sessionUpdated = sessionById(sessionId)?.updated;
      // Trigger reconcile: three paths (MA-8). reloadIfStale() is guarded by
      // _stale, so it cannot reconcile a never-loaded conv (whose _stale is
      // initially false) — route !loaded through load() instead.
      if (force) {
        unawaited(existing.reconcile() // active refresh, ignore backoff
            .then((_) => _backfillPreview(sessionId, existing)));
      } else if (!existing.loaded) {
        existing.setBackfillCallback(() => _backfillPreview(sessionId, existing));
        unawaited(existing.load() // first reconcile, load→reconcile, no backoff
            .then((_) => _backfillPreview(sessionId, existing)));
      } else if (existing.isStale) {
        unawaited(existing.reloadIfStale() // loaded + stale, backoff-guarded
            .then((_) => _backfillPreview(sessionId, existing)));
      }
      return existing;
    }
    // New: ensureConversation injects pending, then load (→ reconcile).
    final conv = ensureConversation(sessionId);
    if (conv == null) return null;
    // Chain _backfillPreview after load (→ reconcile) so _lastMessage seeds
    // from the REST-merged last message; previously concurrent unawaited raced
    // ahead of reconcile and no-op'd on empty _messages (LPS-19).
    conv.setBackfillCallback(() => _backfillPreview(sessionId, conv));
    unawaited(conv.load()
        .then((_) => _backfillPreview(sessionId, conv)));
    return conv;
  }

  Future<void> connect(ConnectionProfile profile) async {
    // Idempotent: no-op if already connected with same server + credentials.
    if (_profile != null &&
        _profile!.id == profile.id &&
        _signature(_profile!) == _signature(profile) &&
        client != null &&
        connected) {
      return;
    }
    AppLogger.I.i(_tag, 'connect ${profile.hostDisplay}');
    // Flush pending cache save for the OUTGOING profile before switching
    // _profile — _stopSse's flush runs AFTER reassignment and would write
    // old profile data to the new profile's key (cross-profile leak).
    if (_cacheSaveTimer != null) {
      _cacheSaveTimer!.cancel();
      _cacheSaveTimer = null;
      await _saveCache();
    }
    _profile = profile;
    await _teardown(flushCache: false);
    _projects = [];
    _sessions = [];
    _statusMap.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _workspaceEnabled.clear();
    _projectsFetched = false;
    // Load cached data first for instant offline UI, then _bootstrap refreshes.
    await _loadCache();
    final dio = dioFor(profile);
    client = OpencodeClient(dio);
    _sseHeaders = Map.from(dio.options.headers.map(
        (k, v) => MapEntry(k, v is String ? v : v.toString())));
    final ok = await _bootstrap();
    bootstrapFailed = !ok;
    if (!ok) {
      AppLogger.I.e(_tag, 'bootstrap failed ${profile.hostDisplay}');
      // Keep cached data visible (offline-first); don't clear on failure.
      connected = false;
      notifyListeners();
      return;
    }
    // Save fresh REST data to cache for next offline open.
    unawaited(_saveCache());
    // _bootstrap already fetched projects + sessions + status.
    // Just start watchdog + SSE for busy/retry sessions + active conversation.
    _startSse(_kGlobalWatchdog);
    _startRequiredSse();
    _trimSse();
    _lastFullRefreshAt = DateTime.now();
    connected = true;
    unawaited(_backfillPermissions());
    notifyListeners();
  }

  /// Sentinel key for the always-on bare `/event` connection (no `directory`
  /// query). Kept distinct from any real directory path. Used for liveness
  /// detection — only receives `server.connected` and `server.heartbeat`.
  // (defined as class constant _kGlobalWatchdog)

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

  void _startSse(String dir, {bool required = false}) {
    if (_sseByDir.containsKey(dir)) {
      // Upgrade to required if needed (don't downgrade). Also wake the
      // client if it's sleeping in reconnect backoff (e.g., resume after
      // background Doze) — no reason to wait out the exponential sleep.
      _sseRequired[dir] = required || (_sseRequired[dir] ?? false);
      _sseByDir[dir]!.reconnectNow();
      return;
    }
    final base = Uri.parse('${_profile!.baseUrl}/event');
    final uri = dir == _kGlobalWatchdog
        ? base // bare /event — global watchdog
        : base.replace(queryParameters: {'directory': dir});
    final label = dir == _kGlobalWatchdog
        ? 'watchdog'
        : (dir.split('/').lastOrNull ?? dir);
    final c = SseClient(uri: uri, headers: _sseHeaders, label: label);
    _sseByDir[dir] = c;
    _sseSubs[dir] =
        c.events.listen(_onEvent); // SSE errors handled by _onSseState reconnect
    _sseStateSubs[dir] = c.state.listen((s) => _onSseState(dir, s));
    _sseRequired[dir] = required;
    c.start();
    _trimSse();
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
      _projectsFetched = true;
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      _inferWorkspaceForNewProjects();
      return true;
    } catch (_) {
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
      // Bump before the archived/parent filter: archived and child sessions
      // (if ever returned by the API) still contribute to the project's
      // recency, so archiving the last active session doesn't sink the
      // project in the projects tab.
      _bumpLastActivity(s);
      if (s.archived != null) continue; // archived
      if (s.parentID != null) continue; // subtask / child session
      out[s.id] = s;
      // REST 批量加载路径也回填 conv directory（SSE 可能先到达创建了空
      // directory 的 conv，此处补上）。
      _backfillConversationDirectory(s.id, s.directory);
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

  /// Unified refresh entry point: REST fetch + SSE management for busy/retry.
  ///
  /// `force: true` — also (re)start the watchdog SSE. Used when watchdog is
  ///   missing (resume after pause, refresh recovering a failed connection).
  /// `force: false` — REST refresh + SSE marking/LRU only. Watchdog untouched.
  Future<bool> refreshListAndWorkingSse({bool force = false}) async {
    if (client == null) return false;
    if (force || !_sseByDir.containsKey(_kGlobalWatchdog)) {
      _startSse(_kGlobalWatchdog);
    }
    try {
      if (force || !_projectsFetched) {
        _projects = await client!.projects();
        _projectsFetched = true;
      }
      final sessions = await _fetchAllSessions();
      final status =
          await _fetchAllStatuses(projects: _projects, sessions: sessions);
      _sessions = sessions;
      _statusMap
        ..clear()
        ..addAll(status);
      _inferWorkspaceForNewProjects();
      for (final conv in _conversations.values) {
        final s = status[conv.sessionId];
        conv.setStatus(s?.type ?? 'idle', retryMessage: s?.message);
        conv.sessionUpdated = sessionById(conv.sessionId)?.updated;
      }
      // Start SSE for busy/retry sessions + active conversation.
      _startRequiredSse();
      _trimSse();
      _lastFullRefreshAt = DateTime.now();
      connected = true;
      _scheduleCacheSave();
    } catch (_) {
      // REST failed — return false so manual refresh shows toast.
      notifyListeners();
      return false;
    }
    // Conversation-layer healing (outside try/catch): only reload the active
    // conversation if it's stale. If SSE is live, reload would clobber
    // incremental updates. markStale() is safe — it defers to reloadIfStale().
    final activeId = _activeSessionId;
    final activeConv =
        activeId != null ? _conversations[activeId] : null;
    if (activeConv != null) {
      if (activeId == _resumeReloadedSessionId) {
        _resumeReloadedSessionId = null;
      } else if (activeConv.busy) {
        activeConv.markStale();
      } else if (!activeConv.loaded) {
        unawaited(activeConv.load()
            .then((_) => _backfillPreview(activeId!, activeConv)));
      } else if (activeConv.isStale) {
        unawaited(activeConv.reload()
            .then((_) => _backfillPreview(activeId!, activeConv)));
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
    return true;
  }

  /// Start SSE for all busy/retry sessions + active conversation directory.
  void _startRequiredSse() {
    for (final s in _sessions) {
      final status = _statusMap[s.id];
      if (status != null &&
          (status.type == 'busy' || status.type == 'retry') &&
          s.directory.isNotEmpty) {
        _startSse(s.directory, required: true);
      }
    }
    final activeId = _activeSessionId;
    if (activeId != null) {
      final s = sessionById(activeId);
      if (s != null && s.directory.isNotEmpty) {
        _startSse(s.directory, required: true);
      }
    }
  }

  Future<void> _reconcile() async {
    if (client == null) return;
    await refreshListAndWorkingSse(force: false);
  }

  /// Fetch pending permissions via REST and route to cached conversations.
  /// SSE only pushes permission.asked at creation time — if the app wasn't
  /// listening, the event is missed. This backfills on connect/reconcile/resume.
  Future<void> _backfillPermissions() async {
    final c = client;
    if (c == null) return;
    _purgeExpiredResolved();
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
          if (_recentlyResolvedPermissions.containsKey(perm.id)) {
            AppLogger.I.i(_tag, 'backfill permission skipped (recently resolved) sid=${perm.sessionID} pid=${perm.id} dir=$dir');
            continue;
          }
          _pendingPermissions[perm.sessionID] = perm;
          _conversations[perm.sessionID]?.onPermission(perm);
          AppLogger.I.i(_tag, 'backfill permission re-inject sid=${perm.sessionID} pid=${perm.id} dir=$dir');
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
        if (_recentlyResolvedPermissions.containsKey(entry.value.id)) continue;
        _pendingPermissions.putIfAbsent(entry.key, () => entry.value);
      }
    }
    // R-Perm-1: notify if the permission map changed so list shield updates.
    final changed = prev.length != _pendingPermissions.length ||
        !prev.keys.toSet().containsAll(_pendingPermissions.keys);
    if (changed) {
      notifyListeners();
    }
    unawaited(_backfillQuestions());
  }

  /// Fetch pending questions via REST, same pattern as permissions.
  Future<void> _backfillQuestions() async {
    final c = client;
    if (c == null) return;
    _purgeExpiredResolved();
    final prev = Map.of(_pendingQuestions);
    _pendingQuestions.clear();
    final dirs = _eventDirectories();
    final failedDirs = <String>{};
    for (final dir in dirs) {
      try {
        final pending = await c.listQuestions(directory: dir);
        for (final q in pending) {
          if (_recentlyResolvedQuestions.containsKey(q.id)) {
            AppLogger.I.i(_tag, 'backfill question skipped (recently resolved) sid=${q.sessionID} qid=${q.id} dir=$dir');
            continue;
          }
          _pendingQuestions[q.id] = q;
          _conversations[q.sessionID]?.onQuestion(q);
          AppLogger.I.i(_tag, 'backfill question re-inject sid=${q.sessionID} qid=${q.id} dir=$dir');
        }
      } catch (_) {
        failedDirs.add(dir);
      }
    }
    // Restore SSE-delivered questions whose session's directory had a failed
    // REST fetch — successful fetches are authoritative.
    for (final entry in prev.entries) {
      final session = sessionById(entry.value.sessionID);
      final dir = session?.directory ?? '';
      if (failedDirs.contains(dir) || dir.isEmpty || !dirs.contains(dir)) {
        if (_recentlyResolvedQuestions.containsKey(entry.key)) continue;
        _pendingQuestions.putIfAbsent(entry.key, () => entry.value);
      }
    }
    if (prev.length != _pendingQuestions.length ||
        !prev.keys.toSet().containsAll(_pendingQuestions.keys)) {
      notifyListeners();
    }
  }

  void _onSseState(String dir, SseState s) {
    if (dir == _kGlobalWatchdog) {
      final wasConnected = _watchdogConnected;
      _watchdogConnected = s.connected;
      // Mark "failed" when transitioning from connected → reconnecting.
      // This suppresses the banner on first connect (which starts as
      // not-connected → connected without ever being "failed").
      if (wasConnected && !s.connected) {
        _watchdogFailed = true;
      }
    }
    // While ANY SSE client is reconnecting (watchdog or directory — the
    // server might be unreachable), probe /global/health every 5s. A
    // successful probe proves reachability long before the exponential
    // backoff (up to 30s) would fire, so we kick all clients out of their
    // sleep immediately. Only the watchdog's connected state stops the
    // probe (authoritative reachability signal).
    if (s.reconnecting) {
      _startHealthProbe();
    } else if (dir == _kGlobalWatchdog && s.connected) {
      _stopHealthProbe();
    }
    // Only watchdog's reconnecting → connected triggers a reconcile.
    if (dir == _kGlobalWatchdog && s.reconnecting) {
      _needsStaleMarking = true;
    }
    if (dir == _kGlobalWatchdog && !s.reconnecting && s.connected) {
      _scheduleReconcile();
    }
    notifyListeners();
  }

  /// Periodically probe `GET /global/health` while any SSE reconnect is
  /// pending. On the first healthy response, kick every client out of its
  /// backoff sleep and stop probing (the reconnect then proceeds at once).
  void _startHealthProbe() {
    if (_healthProbeTimer != null) return;
    final generation = ++_healthProbeGeneration;
    AppLogger.I.i(
        _tag,
        'health probe started '
        '(interval ${healthProbeInterval.inSeconds}s)');
    _healthProbeTimer =
        Timer.periodic(healthProbeInterval, (_) => _probeOnce(generation));
  }

  Future<void> _probeOnce(int generation) async {
    final c = client;
    if (c == null) return;
    try {
      final h = await c.health();
      if (generation != _healthProbeGeneration || _healthProbeTimer == null) {
        return;
      }
      if (!h.healthy) {
        AppLogger.I.d(_tag, 'health probe: server unhealthy');
        return;
      }
      AppLogger.I.i(
          _tag, 'health probe: server reachable, kicking SSE reconnect');
      for (final sse in _sseByDir.values) {
        sse.reconnectNow();
      }
      _stopHealthProbe();
    } catch (e) {
      if (generation != _healthProbeGeneration || _healthProbeTimer == null) {
        return;
      }
      AppLogger.I.d(_tag, 'health probe failed: ${e.runtimeType}');
    }
  }

  void _stopHealthProbe() {
    if (_healthProbeTimer == null) return;
    _healthProbeTimer!.cancel();
    _healthProbeTimer = null;
    _healthProbeGeneration++;
    AppLogger.I.i(_tag, 'health probe stopped');
  }

  /// Test seam to drive SSE events directly into [_onEvent] (which is library-
  /// private). Lets tests assert the `message.part.updated` case's
  /// `break`->`return` (LPS-1) throttle behavior through the real event route
  /// (including the switch's trailing :811 notify).
  @visibleForTesting
  void onEventForTesting(OpencodeEvent ev) => _onEvent(ev);

  /// Test seam to drive SSE lifecycle states into [_onSseState]. Used by
  /// health-probe tests to simulate watchdog reconnecting/connected.
  @visibleForTesting
  void onSseStateForTesting(String dir, SseState s) => _onSseState(dir, s);

  /// Test seam exposing the global watchdog key for state-drive tests.
  @visibleForTesting
  static const String globalWatchdogKeyForTesting = _kGlobalWatchdog;

  /// Test seam for the REST bulk-fetch path [addSessionsForTesting] merges a
  /// list of sessions into a per-id map exactly as `_fetchAllSessions` does,
  /// bumping `_lastActivityByKey` before the archived/parent filter. Used by
  /// PA-4 to lock that ordering invariant on the REST path (not just SSE).
  @visibleForTesting
  void addSessionsForTesting(Map<String, SessionModel> out, List<SessionModel> list) =>
      _addSessions(out, list);

  /// Test seam for the cache round-trip path. Sets `_profile` (required by
  /// `_loadCache` to compute the storage key) and loads cache. Used by PA-R2
  /// to assert that an `activity` blob in SharedPreferences is restored, and
  /// that a stale cached value does NOT overwrite a fresher in-memory value
  /// (the monotonic-max merge in `_loadCache`).
  @visibleForTesting
  Future<void> loadCacheForTesting(ConnectionProfile profile) async {
    _profile = profile;
    await _loadCache();
  }

  /// Test seam: drive `_upsertSession` to populate `_sessions` (needed by
  /// `_eventDirectories` / `sessionById`) without going through SSE.
  @visibleForTesting
  void upsertSessionForTesting(SessionModel s) => _upsertSession(s);

  /// Test seam: drive `_backfillQuestions` directly to verify the
  /// `_recentlyResolvedQuestions` guard skips recently-resolved ids.
  @visibleForTesting
  Future<void> backfillQuestionsForTesting() => _backfillQuestions();

  /// Test seam: simulate TTL expiry by clearing the resolved-guard sets.
  /// Used to verify the "re-surface if still pending server-side" path
  /// (关键设计决策 4).
  @visibleForTesting
  void expireRecentlyResolvedForTesting() {
    _recentlyResolvedQuestions.clear();
    _recentlyResolvedPermissions.clear();
  }

  @visibleForTesting
  void installSseForTesting(String directory, SseClient sse) {
    _sseByDir[directory] = sse;
  }

  @visibleForTesting
  bool hasSseForTesting(String directory) => _sseByDir.containsKey(directory);

  @visibleForTesting
  Future<void> stopSseForTesting() => _stopSse(flushCache: false);

  void _onEvent(OpencodeEvent ev) {
    switch (ev.type) {
      case 'server.connected':
        AppLogger.I.i(_tag, 'server.connected');
        _scheduleReconcile();
        return; // _reconcile notifies
      case 'session.status':
        final sid = ev.properties['sessionID']?.toString();
        final st = ev.properties['status'];
        if (sid != null && st is Map) {
          final status = SessionStatusValue.fromJson(st.cast());
          AppLogger.I.d(_tag, 'session.status $sid=${status.type}'
              '${status.message != null ? ' msg=${status.message}' : ''}');
          _statusMap[sid] = status;
          _conversations[sid]?.setStatus(status.type, retryMessage: status.message);
          _scheduleCacheSave();
        }
        break;
      case 'session.idle':
        final sid = ev.properties['sessionID']?.toString();
        if (sid != null) {
          // Only notify if the session was previously busy (not a spurious
          // idle on an already-idle session).
          final wasBusy = _statusMap[sid]?.type == 'busy';
          final wasRetry = _statusMap[sid]?.type == 'retry';
          _statusMap[sid] = const SessionStatusValue('idle');
          _scheduleCacheSave();
          // Clear the retry banner when the session settles out of retry.
          // busy → idle doesn't need this (no retry message was set), so we
          // avoid a redundant conv notify for that path.
          if (wasRetry) {
            _conversations[sid]?.setStatus('idle');
          }
          if (wasBusy) {
            AppLogger.I.i(_tag, 'session.idle $sid');
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
      case 'session.error':
        final sid = ev.properties['sessionID']?.toString();
        final err = ev.properties['error'];
        if (sid != null) {
          final Map<String, dynamic> errorMap;
          if (err is Map) {
            errorMap = err.cast<String, dynamic>();
          } else if (err is String && err.isNotEmpty) {
            errorMap = {'message': err};
          } else {
            break;
          }
          AppLogger.I.e(_tag, 'session.error $sid $errorMap');
          ensureConversation(sid)?.onSessionError(errorMap);
        }
        break;
      case 'message.updated':
        AppLogger.I.d(_tag, 'message.updated.raw role=${ev.properties['info']?['role']} id=${ev.properties['info']?['id']}');
        unawaited(_onMessageUpdated(ev.properties));
        return;
      case 'message.part.updated':
        final part = ev.properties['part'];
        final sid = part is Map ? part['sessionID']?.toString() : null;
        final delta = ev.properties['delta']?.toString();
        final ptype = part is Map ? part['type']?.toString() : null;
        if (sid != null && part is Map) {
          final conv = ensureConversation(sid);
          if (conv != null) {
            conv.onPartUpdated(part.cast(), delta);
            // List preview: refresh on every renderable part event (text/
            // reasoning deltas included), coalesced by _notifyPreviewChanged()
            // (120ms). Tool parts already triggered before; now streaming text
            // also updates the preview instead of stalling on the previous
            // user message.
            // LPS-7: because this case returns early (LPS-1), the guard below
            // also implicitly decides whether to notify — non-matching part
            // types neither write the preview nor fire :811. Safe today (other
            // types are _hidden or carry no preview text), but a future
            // preview-bearing part type MUST be added here.
            if (ptype == 'tool' || ptype == 'text' || ptype == 'reasoning') {
              final pv = conv.lastMessagePreview();
              if (pv != null) {
                _lastMessage[sid] = pv;
                _notifyPreviewChanged();
                _scheduleCacheSave();
              }
            }
          }
        }
        // LPS-1: early-return (not break) so this case does NOT fall through
        // to the switch's trailing notifyListeners() at :811 — that notify is
        // unthrottled and per-token, which would bypass _notifyPreviewChanged()'s
        // 120ms coalescing and make the preview jitter per-token. Detail-page
        // typing is driven by conv.notifyListeners() in onPartUpdated, so it is
        // unaffected. Other cases still break -> :811 as before.
        return;
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
        AppLogger.I.i(_tag, 'SSE permission.asked sid=${p.sessionID} pid=${p.id}');
        final title = sessionById(p.sessionID)?.title ?? '会话';
        unawaited(
            NotificationService.notifyPermission(title, p.title).catchError((_) {}));
        break;
      case 'permission.replied':
      case 'permission.v2.replied':
        final sid = ev.properties['sessionID']?.toString();
        // Spec: permission.replied carries the permission id under "requestID"
        // (additionalProperties:false — there is no "permissionID" key).
        final pid = ev.properties['requestID']?.toString() ??
            ev.properties['permissionID']?.toString();
        AppLogger.I.i(_tag, 'SSE permission.replied sid=$sid pid=$pid');
        if (sid != null && pid != null) {
          _pendingPermissions.removeWhere((_, p) => p.id == pid);
          _conversations[sid]?.onPermissionReplied(pid);
        }
        break;
      case 'question.asked':
      case 'question.v2.asked':
        final qr = QuestionRequest.fromJson(ev.properties);
        _pendingQuestions[qr.id] = qr;
        _conversations[qr.sessionID]?.onQuestion(qr);
        AppLogger.I.i(_tag, 'SSE question.asked sid=${qr.sessionID} qid=${qr.id}');
        final title = sessionById(qr.sessionID)?.title ?? '会话';
        unawaited(NotificationService.notifyQuestion(title, qr.questions.firstOrNull?.header ?? '问题').catchError((_) {}));
        break;
      case 'question.replied':
      case 'question.v2.replied':
      case 'question.rejected':
      case 'question.v2.rejected':
        // Spec: question.replied/rejected carry the question id under
        // "requestID" (additionalProperties:false — there is no "id" key).
        final qid = ev.properties['requestID']?.toString() ??
            ev.properties['id']?.toString();
        final existing = qid != null ? _pendingQuestions[qid] : null;
        final sid = ev.properties['sessionID']?.toString() ?? existing?.sessionID;
        AppLogger.I.i(_tag, 'SSE ${ev.type} sid=$sid qid=$qid');
        if (qid != null) {
          _pendingQuestions.remove(qid);
        }
        if (sid != null && qid != null) {
          _conversations[sid]?.onQuestionReplied(qid);
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
    final conv = ensureConversation(sid);
    conv?.onMessageUpdated(m); // internally _saveCache()s on settle
    // MU-1: notify immediately so the list layer knows a message changed,
    // before the preview fetch (which may be slow on weak networks).
    notifyListeners();
    // List preview: refresh on every message event — user msg, in-flight
    // assistant (finish empty), and completed assistant (finish non-empty).
    // Covers the "no part event, only message.updated" edge (e.g. empty or
    // reasoning-only assistant messages). Part events keep the preview live
    // during streaming; this keeps it correct at message boundaries.
    final local = conv?.lastMessagePreview();
    final lastRole = conv?.messages.isNotEmpty == true ? conv!.messages.last.info.role : '?';
    final lastId = conv?.messages.isNotEmpty == true ? conv!.messages.last.info.id : '?';
    AppLogger.I.d(
        _tag,
        'message.updated.parsed sid=$sid role=${m.role} id=${m.id} '
        'finish=${m.finish} _last=($lastRole,$lastId)');
    if (local != null) {
      _lastMessage[sid] = local;
      _notifyPreviewChanged();
      _scheduleCacheSave();
      return;
    }
    // local == null: streaming assistant has no renderable parts yet, or
    // last message is empty. Keep current _lastMessage — don't overwrite
    // (prevents tool-call boundary preview revert).
  }

  Future<void> _backfillPreview(String sid, ConversationStore conv) async {
    // After the conversation loads, surface its last message as the list preview
    // (avoids bulk-proactive fetch but keeps viewed sessions informative).
    final preview = conv.lastMessagePreview();
    if (preview != null) {
      _lastMessage[sid] = preview;
      notifyListeners();
    }
  }

  /// Reflect the latest preview from the given conversation into the list cache.
  /// Used after optimistic user-message insertion so the list shows it without
  /// waiting for the message.updated(user) SSE event.
  void reflectPreviewFrom(String sid) {
    final conv = _conversations[sid];
    if (conv == null) return;
    final pv = conv.lastMessagePreview();
    if (pv != null) {
      _lastMessage[sid] = pv;
      _notifyPreviewChanged();
      _scheduleCacheSave();
    }
  }

  void _upsertSession(SessionModel s) {
    // Bump activity even when the session is being archived — `setArchived`
    // leaves `time.updated` unchanged, so this preserves the project's sort
    // position after the session disappears from `_sessions`.
    _bumpLastActivity(s);
    // Drop archived sessions and subtask/child sessions from the active list.
    if (s.archived != null || s.parentID != null) {
      _sessions.removeWhere((x) => x.id == s.id);
      _scheduleCacheSave();
      return;
    }
    final idx = _sessions.indexWhere((x) => x.id == s.id);
    if (idx == -1) {
      _sessions.add(s);
    } else {
      _sessions[idx] = s;
    }
    _scheduleCacheSave();
    // 回填 directory：question.asked 早于 session 加载时，conv 可能已用空
    // directory 创建；session 到达后补上，让后续 reply/reject 能带上 directory。
    _backfillConversationDirectory(s.id, s.directory);
    // A new/updated session — only start SSE if it's busy/retry or active.
    if (s.directory.isNotEmpty) {
      final status = _statusMap[s.id];
      final isWorking = status != null &&
          (status.type == 'busy' || status.type == 'retry');
      final isActive = _activeSessionId == s.id;
      if (isWorking || isActive) {
        _startSse(s.directory, required: true);
      }
    }
  }

  void _removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _conversations.remove(id);
    _lastMessage.remove(id);
    _statusMap.remove(id);
    // Intentionally keeps `_lastActivityByKey` — activity is monotonic across
    // deletes too. Removing the entry here would sink the project if its last
    // observed session is hard-deleted (PA-5 locks this invariant). The entry
    // is stale only in the sense of "session no longer exists server-side",
    // which doesn't affect sort correctness for the remaining sessions.
    _trimSse();
    _scheduleCacheSave();
  }

  /// LRU eviction + stale directory cleanup. Merges the old `_pruneSse()`
  /// logic with idle SSE pool management.
  ///
  /// Rules:
  /// 1. Watchdog is never evicted.
  /// 2. Directories not in `_eventDirectories()` are closed immediately.
  /// 3. Required directories (busy/retry + active conversation) are kept.
  /// 4. Non-required (idle) SSE are capped at `_kMaxIdleSseConnections`,
  ///    evicting oldest by `lastEventAt`.
  void _trimSse() {
    // 1. Compute required directories.
    final requiredDirs = <String>{};
    for (final s in _sessions) {
      final status = _statusMap[s.id];
      if (status != null &&
          (status.type == 'busy' || status.type == 'retry') &&
          s.directory.isNotEmpty) {
        requiredDirs.add(s.directory);
      }
    }
    final activeId = _activeSessionId;
    if (activeId != null) {
      final s = sessionById(activeId);
      if (s != null && s.directory.isNotEmpty) {
        requiredDirs.add(s.directory);
      }
    }

    // 2. Clean up + classify.
    final validDirs = _eventDirectories();
    final removable = <String>[];
    for (final dir in _sseByDir.keys.toList()) {
      if (dir == _kGlobalWatchdog) continue;
      if (!validDirs.contains(dir)) {
        _stopSseForDirectory(dir);
        continue;
      }
      if (requiredDirs.contains(dir)) {
        _sseRequired[dir] = true;
        continue;
      }
      _sseRequired[dir] = false;
      removable.add(dir);
    }

    // 3. Evict oldest idle SSE if over limit.
    removable.sort((a, b) =>
        _sseByDir[a]!.lastEventAt.compareTo(_sseByDir[b]!.lastEventAt));
    while (removable.length > _kMaxIdleSseConnections) {
      final oldest = removable.removeAt(0);
      _stopSseForDirectory(oldest);
    }
  }

  Future<void> _stopSseForDirectory(String dir) {
    _sseSubs[dir]?.cancel();
    _sseSubs.remove(dir);
    _sseStateSubs[dir]?.cancel();
    _sseStateSubs.remove(dir);
    _sseRequired.remove(dir);
    return _sseByDir.remove(dir)?.stop() ?? Future.value();
  }

  Future<void> _teardown({bool flushCache = true}) async {
    await _stopSse(flushCache: flushCache);
    for (final conv in _conversations.values) {
      conv.dispose();
    }
    _conversations.clear();
    _previewNotifyTimer?.cancel();
    _previewNotifyTimer = null;
    _lastPreviewNotifyAt = null;
  }

  Future<void> disconnect() async {
    connected = false;
    await _teardown();
    _projects = [];
    _sessions = [];
    _statusMap.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _workspaceEnabled.clear();
    _pendingPermissions.clear();
    _pendingQuestions.clear();
    _recentlyResolvedQuestions.clear();
    _recentlyResolvedPermissions.clear();
    client = null;
    _profile = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _stopHealthProbe();
    _previewNotifyTimer?.cancel();
    _previewNotifyTimer = null;
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer = null;
    super.dispose();
  }

  /// Manual refresh (from pull-to-refresh). Returns true on success.
  Future<bool> refresh() async {
    if (client == null) return false;
    return await refreshListAndWorkingSse(force: true);
  }

  // ── App lifecycle (specs §5: background → pause, foreground → resume) ──

  /// Called when the app goes to background: stop SSE to save battery.
  /// Cached data (sessions, conversations) is retained for instant resume.
  /// All conversations are marked stale since we lose live SSE updates.
  Future<void> pause() {
    if (!connected || _profile == null) return Future.value();
    _foreground = false;
    AppLogger.I.i(_tag, 'pause');
    for (final conv in _conversations.values) {
      conv.markStale();
      conv.cancelLoadRetry();
    }
    final activePause = _pauseOperation;
    if (activePause != null) return activePause;
    final operation = _stopSse();
    _pauseOperation = operation;
    return operation.whenComplete(() {
      if (identical(_pauseOperation, operation)) _pauseOperation = null;
    });
  }

  /// Called when the app returns to foreground. Decision logic:
  /// - No watchdog → SSE was torn down by pause → full refresh.
  /// - Has watchdog but last refresh >30s ago → refresh.
  /// - Has watchdog and recent refresh → just backfill permissions.
  Future<void> resume() async {
    if (!connected || client == null || _profile == null) return;
    _foreground = true;
    AppLogger.I.i(_tag, 'resume');

    final activePause = _pauseOperation;
    if (activePause != null) await activePause;
    if (!_foreground || !connected || client == null || _profile == null) {
      return;
    }

    // Wake all SSE clients sleeping in reconnect backoff (earned under
    // background/Doze suspended-network conditions). The app is now in the
    // foreground with the network available — reconnect immediately instead
    // of waiting out the exponential sleep (up to 30s).
    for (final c in _sseByDir.values) {
      c.reconnectNow();
    }

    // No watchdog: SSE was torn down (pause timer fired). Full refresh.
    if (!_sseByDir.containsKey(_kGlobalWatchdog)) {
      await refreshListAndWorkingSse(force: true);
      return;
    }

    // Has watchdog but data is stale.
    final stale = _lastFullRefreshAt == null ||
        DateTime.now().difference(_lastFullRefreshAt!) > kMaxRefreshInterval;
    if (stale) {
      await refreshListAndWorkingSse(force: false);
      return;
    }

    // SSE still live and data fresh — just backfill permissions.
    unawaited(_backfillPermissions());
    notifyListeners();
  }

  /// Stop all SSE connections without clearing cached data (used by pause).
  Future<void> _stopSse({bool flushCache = true}) async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _stopHealthProbe();
    final eventSubs = _sseSubs.values.toList();
    final stateSubs = _sseStateSubs.values.toList();
    final clients = _sseByDir.values.toList();
    _sseSubs.clear();
    _sseStateSubs.clear();
    _sseByDir.clear();
    _sseRequired.clear();
    _watchdogConnected = false;
    _watchdogFailed = false;
    final stops = <Future<void>>[
      ...eventSubs.map((sub) => sub.cancel()),
      ...stateSubs.map((sub) => sub.cancel()),
      ...clients.map((sse) => sse.stop()),
    ];
    // Flush pending cache save before canceling — prevents data loss on
    // pause/disconnect (up to 2s of SSE updates would be dropped).
    // connect() passes flushCache: false because it already flushed the
    // outgoing profile's pending save before reassigning _profile; flushing
    // again here would use the NEW _profile and write old data to the new
    // key (cross-profile leak, see LC3-1).
    if (_cacheSaveTimer != null) {
      _cacheSaveTimer!.cancel();
      _cacheSaveTimer = null;
      if (flushCache) await _saveCache();
    }
    try {
      await Future.wait(stops).timeout(sseStopTimeout);
    } on TimeoutException {
      AppLogger.I.w(_tag, 'SSE stop timed out; detached clients left stopping');
    }
  }

  // ── Local cache (offline-first: instant UI on app open) ──

  String _cacheKey(String profileId) => 'server_$profileId';

  void _scheduleCacheSave() {
    if (_profile == null) return;
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer = Timer(const Duration(seconds: 2), () => _saveCache());
  }

  Future<void> _saveCache() async {
    final profile = _profile;
    if (profile == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final j = {
        'v': 1,
        'projects': _projects.map((p) => p.toJson()).toList(),
        'sessions': _sessions.map((s) => s.toJson()).toList(),
        'status': _statusMap.map((k, v) => MapEntry(k, v.toJson())),
        'lastMessage': _lastMessage,
        'activity': _lastActivityByKey,
        'workspaceEnabled': _workspaceEnabled,
      };
      await prefs.setString(_cacheKey(profile.id), jsonEncode(j));
    } catch (e) {
      AppLogger.I.w(_tag, 'saveCache failed: $e');
    }
  }

  Future<void> _loadCache() async {
    final profile = _profile;
    if (profile == null) return;
    final key = _cacheKey(profile.id);
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['v'] != 1) {
        AppLogger.I.w(_tag, 'cache schema mismatch, dropping');
        await prefs.remove(key);
        return;
      }
      final projects = (j['projects'] as List? ?? [])
          .map((e) => ProjectModel.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      final sessions = (j['sessions'] as List? ?? [])
          .map((e) => SessionModel.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      final status = <String, SessionStatusValue>{};
      final statusRaw = j['status'] as Map? ?? {};
      for (final entry in statusRaw.entries) {
        status[entry.key] =
            SessionStatusValue.fromJson((entry.value as Map).cast<String, dynamic>());
      }
      final lastMsg = <String, String>{};
      final lmRaw = j['lastMessage'] as Map? ?? {};
      for (final entry in lmRaw.entries) {
        lastMsg[entry.key] = entry.value.toString();
      }
      // Activity is monotonic-max merged: a stale cache value must not
      // overwrite a larger value already set by SSE between `_loadCache` calls
      // or by an in-flight bootstrap. (Defensive — `connect` clears the map
      // before `_loadCache`, so in practice the merge is a straight fill.)
      final actRaw = j['activity'] as Map? ?? {};
      for (final entry in actRaw.entries) {
        final v = entry.value;
        final n = v is int ? v : (v is num ? v.toInt() : null);
        if (n == null) continue;
        final key = entry.key.toString();
        final cur = _lastActivityByKey[key] ?? 0;
        if (n > cur) _lastActivityByKey[key] = n;
      }
      // MA-2 guards: only fill when empty; use putIfAbsent for maps so SSE
      // real-time values are never overwritten by stale cache (defensive
      // for future call paths that might load cache after SSE starts).
      if (_projects.isEmpty) _projects = projects;
      if (_sessions.isEmpty) _sessions = sessions;
      for (final e in status.entries) {
        _statusMap.putIfAbsent(e.key, () => e.value);
      }
      for (final e in lastMsg.entries) {
        _lastMessage.putIfAbsent(e.key, () => e.value);
      }
      final wsRaw = j['workspaceEnabled'] as Map? ?? {};
      for (final entry in wsRaw.entries) {
        _workspaceEnabled.putIfAbsent(
            entry.key.toString(), () => entry.value == true);
      }
      if (_projects.isNotEmpty || _sessions.isNotEmpty) {
        _projectsFetched = true;
        notifyListeners();
      }
    } catch (e) {
      AppLogger.I.e(_tag, 'loadCache failed ($key): $e');
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(key);
      } catch (_) {}
    }
  }
}
