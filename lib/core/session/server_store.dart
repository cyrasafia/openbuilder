import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../data/api/opencode_client.dart';
import '../../domain/models.dart';
import '../../l10n/gen/app_localizations.dart';
import '../connection/connection_profile.dart';
import '../connection/connection_store.dart';
import '../cache/cache_store.dart';
import '../logging/app_logger.dart';
import '../logging/perf_probe.dart';
import '../net/dio_factory.dart';
import '../net/net_error.dart';
import '../notifications/notification_service.dart';
import '../sse/sse_client.dart';
import 'conversation_store.dart';
import 'file_browsing_store.dart';

const _tag = 'Server';

/// Live, per-active-server state: projects / sessions / status / latest-message
/// preview, plus lazy per-session [ConversationStore] caches. Fed by the single
/// global SSE stream `GET /global/event` (specs §5, frontend §2.2).
class ServerStore extends ChangeNotifier {
  @visibleForTesting
  static Duration sseStopTimeout = const Duration(seconds: 2);

  OpencodeClient? client;
  /// Single global SSE stream: `GET /global/event` (GlobalBus, server ≥
  /// v1.0.66) carries every directory's events in one connection; the envelope
  /// `directory` routes/filters them client-side (`_onGlobalEvent` gate).
  /// Connection lifecycle is decoupled from the open-session set — see
  /// design-sse-global-event.md.
  SseClient? _sse;
  StreamSubscription<GlobalOpencodeEvent>? _sseSub;
  StreamSubscription<SseState>? _sseStateSub;
  final Map<String, String> _sseHeaders = {};
  Timer? _reconcileTimer;
  Timer? _previewNotifyTimer;
  Timer? _cacheSaveTimer;
  Timer? _healthProbeTimer;
  Future<void>? _pauseOperation;
  bool _foreground = true;
  int _healthProbeGeneration = 0;
  // Health probe interval while the global SSE is reconnecting. Each tick
  // is one cheap GET /global/health; on success the client is kicked out
  // of backoff. 5s bounds recovery detection (vs the 30s backoff ceiling)
  // while staying negligible for battery/traffic during long outages.
  @visibleForTesting
  static Duration healthProbeInterval = const Duration(seconds: 5);
  DateTime? _lastPreviewNotifyAt;
  static const _previewNotifyInterval = Duration(milliseconds: 120);
  ConnectionProfile? _profile;
  // Profile-scoped cache backend. Rebuilt on connect() per profile.id; null
  // after disconnect(). Shared with ConversationStore (conv cache lives under
  // the same per-profile directory).
  CacheStore? _cacheStore;

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

  /// Dedup guard: overlapping backfill runs (connect + reconcile, both tabs'
  /// periodic refresh) would race their snapshots — a slower older run must
  /// not overwrite a newer one's swap.
  bool _backfillInFlight = false;

  /// A trigger that arrived while [_backfillInFlight] — the run coalesces into
  /// exactly one re-run afterwards, so a late trigger isn't dropped until the
  /// next reconnect/resume/refresh.
  bool _backfillDirty = false;

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
  /// Sessions currently known to be ghosts (worktree directory gone). Tracked
  /// separately from `_statusMap` (where they settle to a plain `idle`) so a
  /// `ConversationStore` recreated after LRU eviction still gets the
  /// workspace-missing flag re-applied via [ensureConversation]. Pruned when
  /// a session reappears in an authoritative fetch, cleared on disconnect.
  final Set<String> _ghostSessionIds = {};
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

  /// File browsing snapshots + content cache (design-file-browser-collapse).
  final FileBrowsingStore fileBrowsing = FileBrowsingStore();

  final ValueNotifier<List<CommandInfo>> commandsNotifier =
      ValueNotifier(const []);

  /// JANK-5：预览变更独立通道。流式期间 `_notifyPreviewChanged` 只 bump 此
  /// notifier（120ms 节流），不再走全局 notifyListeners——只有会话列表的
  /// tile 需要跟预览刷新，项目 tab / 详情页 / AppBar 不该跟着每 120ms 重建。
  /// SessionsTab 的列表体改听此 notifier（连同 serverStore 本体）。
  final ValueNotifier<int> previewVersion = ValueNotifier(0);
  bool _commandsRefreshing = false;
  String? _commandsRefreshDir;
  bool get commandsRefreshing => _commandsRefreshing;
  /// The directory the current [commandsNotifier] value was resolved for.
  /// Degraded refreshes only retain the cache when it belongs to the *same*
  /// directory, so a failed fetch in project B never surfaces project A's
  /// commands (the notifier is a single global cache).
  String? _commandsCacheDir;
  /// Whether the current [commandsNotifier] value came from a fully-successful
  /// (non-degraded) fetch. Only a known-complete list is worth protecting from
  /// a transient blip; a degraded partial is never retained over a fresh fetch.
  bool _commandsCacheComplete = false;
  /// True when the most recent [refreshCommands] produced a degraded or
  /// incomplete result (the fetch errored, or the whole refresh threw).
  /// The conversation screen uses this to re-fetch on the next `/` input
  /// instead of giving up after one failed attempt.
  bool _commandsDegraded = false;
  bool get commandsDegraded => _commandsDegraded;
  /// Consecutive "suspicious empty" refreshes (`GET /command` returned 200-OK
  /// with zero entries — impossible for a healthy registry, which always
  /// carries the hardcoded init/review built-ins). Right after a network
  /// recovery the connection pool can serve a stale/empty response that does
  /// NOT throw, so without protection it would be trusted as genuine and wipe
  /// a known-good cache. We retain the cache while this streak is under
  /// [kMaxSuspiciousRetries]; once exhausted a persistent empty is treated as
  /// authoritative so the list can never be stuck stale forever.
  int _suspiciousEmptyStreak = 0;
  @visibleForTesting
  static const int kMaxSuspiciousRetries = 3;

  Future<void> refreshCommands({String? directory}) async {
    final c = client;
    if (c == null) return;
    if (_commandsRefreshing && _commandsRefreshDir == directory) return;
    _commandsRefreshing = true;
    _commandsRefreshDir = directory;
    try {
      // Single source: the v1 instance route `GET /command?directory=` — the
      // same per-directory registry that executes `POST /session/:id/command`,
      // covering built-in commands (init/review), config/plugin/MCP commands,
      // and the full skill set incl. external ~/.claude / ~/.agents dirs. Every
      // entry expands server-side ($ARGUMENTS/$N), so the client never needs
      // templates. The v2 `/api/command` + `/api/skill` endpoints are
      // deliberately not called: not GA yet, source-registry based (no external
      // skill scan, no skill merge), and they ignore the flat `?directory=`
      // query — always answering for the server's default location. `/config`
      // was only read for client-side template expansion, now redundant.
      final v1 =
          await _tryFetchCommands(c.getMergedCommands(directory: directory));

      // A healthy registry always contains the built-ins, so a 200-OK empty is
      // never genuine on its own — treat it as suspicious (transient), same as
      // a thrown request (degraded). Both retain a known-complete cache for the
      // same directory while the streak is under [kMaxSuspiciousRetries]; once
      // exhausted the empty is applied. Never retain a degraded partial over a
      // fresh result — fall through and apply that instead.
      final degraded = v1.failed;
      final suspiciousEmpty = !v1.failed && v1.value.isEmpty;
      final haveGoodCache = commandsNotifier.value.isNotEmpty &&
          _commandsCacheDir == directory &&
          _commandsCacheComplete;
      final withinStreak = _suspiciousEmptyStreak < kMaxSuspiciousRetries;
      if ((degraded || (suspiciousEmpty && withinStreak)) && haveGoodCache) {
        if (suspiciousEmpty) _suspiciousEmptyStreak++;
        _commandsDegraded = true;
        AppLogger.I.w(_tag,
            'commands refresh ${suspiciousEmpty ? 'suspicious-empty' : 'degraded'} '
            '(v1=${v1.value.length}/${v1.failed ? 'err' : 'ok'}); '
            'keeping cache of ${commandsNotifier.value.length} '
            '(streak $_suspiciousEmptyStreak)');
        return;
      }

      // A suspicious empty with no cache to protect still isn't authoritative —
      // mark degraded so the next `/` retries. Once the streak is exhausted the
      // empty is treated as genuine (not degraded).
      final trustEmpty = suspiciousEmpty && !withinStreak;
      if (suspiciousEmpty) {
        _suspiciousEmptyStreak++;
      } else {
        _suspiciousEmptyStreak = 0;
      }
      _commandsDegraded = degraded || (suspiciousEmpty && !trustEmpty);
      _commandsCacheDir = directory;
      _commandsCacheComplete = !degraded;
      AppLogger.I.i(_tag,
          'commands refreshed: v1=${v1.value.length}'
          '${degraded ? ' (degraded, no usable cache)' : ''}'
          '${suspiciousEmpty && !trustEmpty ? ' (suspicious-empty, no cache)' : ''}');
      commandsNotifier.value = v1.value;
    } catch (e) {
      _commandsDegraded = true;
      AppLogger.I.e(_tag, 'commands refresh failed: $e');
    } finally {
      _commandsRefreshing = false;
    }
  }

  /// Runs [future], capturing its result or the failure so a per-source fetch
  /// error is observable instead of silently turning into an empty list.
  Future<({List<CommandInfo> value, bool failed})> _tryFetchCommands(
      Future<List<CommandInfo>> future) async {
    try {
      return (value: await future, failed: false);
    } catch (_) {
      return (value: const <CommandInfo>[], failed: true);
    }
  }

  bool connected = false;

  /// Whether the global SSE stream is actively connected (for status indicator).
  bool get sseConnected => _sse != null && _sseLive;

  /// Whether the global SSE stream is in reconnecting state.
  bool get sseReconnecting => _sse != null && !_sseLive;

  /// Whether the session's events are being streamed. The single global stream
  /// covers every directory, so any known session is covered while connected.
  bool isSessionSseConnected(String sessionId) {
    if (!_sseLive) return false;
    return sessionById(sessionId) != null;
  }
  bool _sseLive = false;
  // Set true when the SSE enters reconnecting state (first-connect failure or
  // post-connect drop). Stays true after recovery — banner is controlled by
  // !_sseLive, not _sseFailed.
  bool _sseFailed = false;

  /// Whether the initial bootstrap failed (for showing error view + retry).
  bool bootstrapFailed = false;

  /// Whether a [connect] is in flight (bootstrap running). While true and no
  /// cache is loaded the list tabs show a loading indicator instead of the
  /// stale error/empty views: adding a server activates the profile before
  /// credentials exist, so a first connect fails (stale [bootstrapFailed])
  /// and the credentials save fires connect() again right before the list
  /// page mounts — without this flag that window flashes 连接失败/无会话.
  bool _connecting = false;
  bool get connecting => _connecting;

  /// Overlapping [connect]s are possible (connectionStore notifies once per
  /// update() and setActive() right after saving credentials); only the most
  /// recent one may clear [_connecting] when it settles.
  int _connectGeneration = 0;

  /// Test seam: force the connecting flag (drives the tab loading state
  /// without a real network bootstrap). Bumps the generation so a later
  /// in-flight connect cannot clear a test-set true.
  @visibleForTesting
  void setConnectingForTesting(bool v) {
    _connectGeneration++;
    _connecting = v;
    notifyListeners();
  }

  /// Whether to show the "network disconnected" banner.
  bool get showDisconnectBanner => _sseFailed && !_sseLive;

  List<ProjectModel> get projects => List.unmodifiable(_projects);
  List<SessionModel> get sessions => List.unmodifiable(_sessions);

  Iterable<SessionModel> sortedSessions() {
    final list = [..._sessions]..sort((a, b) => b.updated.compareTo(a.updated));
    return list;
  }

  SessionStatusValue statusOf(String id) =>
      _statusMap[id] ?? const SessionStatusValue('idle');

  String? lastMessageOf(String id) => _lastMessage[id];

  /// Active [AppLocalizations] pushed down from app_state (the store layer
  /// cannot import app_state, mirroring [reasoningVisibleInPreview]). Used to
  /// localize the session-list preview ("You: " prefix, attachment fallback)
  /// and the worktree label, which are produced here without a BuildContext.
  AppLocalizations? _loc;

  /// Set the active localization and recompute cached previews so the list
  /// follows a locale switch instead of showing stale-language text.
  set activeLoc(AppLocalizations v) {
    if (_loc?.localeName == v.localeName) return;
    _loc = v;
    _recomputePreviews();
  }

  /// Whether reasoning ("thinking") parts may surface as the session-list
  /// preview. Pushed down from the `showThinking` app setting (the store layer
  /// cannot import app_state) so the one-line preview tracks the detail view:
  /// when thinking is hidden in the detail page it must also be hidden here.
  bool _reasoningVisibleInPreview = false;

  set reasoningVisibleInPreview(bool v) {
    if (_reasoningVisibleInPreview == v) return;
    _reasoningVisibleInPreview = v;
    _recomputePreviews();
  }

  /// Recompute every loaded conversation's preview under the current setting.
  /// Sessions not yet loaded are corrected on demand by `_backfillPreview`
  /// (which also respects this flag), consistent with the incremental-reconcile
  /// design where the cache is a self-correcting fallback.
  void _recomputePreviews() {
    if (_conversations.isEmpty) return;
    for (final entry in _conversations.entries) {
      final pv = entry.value
          .lastMessagePreview(
              hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
      if (pv != null) {
        _lastMessage[entry.key] = pv;
      } else {
        _lastMessage.remove(entry.key);
      }
    }
    _notifyPreviewChanged();
    _scheduleCacheSave();
  }

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
      _bumpPreview();
    } else {
      // Ensure a trailing notify so the final streaming state is reflected.
      _previewNotifyTimer ??= Timer(_previewNotifyInterval, () {
        _lastPreviewNotifyAt = DateTime.now();
        _previewNotifyTimer = null;
        _bumpPreview();
      });
    }
  }

  void _bumpPreview() => previewVersion.value++;

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
    if (activeClient == null) throw const KnownError(FriendlyErrorKind.notConnected);
    try {
      final updated = (await _reconcileSandboxes([
        await activeClient.updateProject(
          projectId,
          name: name,
          updateIcon: updateIcon,
          iconUrl: iconUrl,
          iconOverride: iconOverride,
          iconColor: iconColor,
        ),
      ])).single;
      final idx = _projects.indexWhere((p) => p.id == projectId);
      if (idx >= 0) {
        _projects[idx] = updated;
      } else {
        _projects.add(updated);
      }
      _scheduleCacheSave();
      notifyListeners();
      return updated;
    } catch (e) {
      throw OperationException('保存项目', cause: e);
    }
  }

  /// `DELETE /experimental/worktree` — delete a worktree and do targeted local
  /// cleanup in one step. Before deletion, every session in the worktree
  /// directory is deleted server-side: the server keys sessions by directory
  /// path only, so recreating a same-named worktree reuses the path and would
  /// otherwise resurrect the old sessions (including archived ones). After
  /// the server confirms deletion, the worktree is removed from the project's
  /// `sandboxes`, all sessions in that directory are dropped from `_sessions`
  /// (plus their conversation / preview / status caches), and the directory
  /// falls out of the global stream's event gate — all without a full
  /// `refresh()`. Callers should `await` this so the UI behind a confirmation
  /// dialog is already in its final state when the dialog closes.
  Future<void> removeWorktree(
    String projectWorktree, {
    required String worktreeDir,
  }) async {
    final c = client;
    if (c == null) throw const KnownError(FriendlyErrorKind.notConnected);
    try {
      final sessions = await c.sessionsForDirectory(worktreeDir);
      await Future.wait(
        sessions.map(
          (s) => c.deleteSession(s.id, directory: worktreeDir),
        ),
      );
      await c.removeWorktree(projectWorktree, worktreeDir: worktreeDir);
    } catch (e) {
      throw OperationException('删除工作区', cause: e);
    }
    final idx = _projects.indexWhere((p) => p.worktree == projectWorktree);
    if (idx >= 0) {
      final p = _projects[idx];
      _projects[idx] = ProjectModel(
        id: p.id,
        worktree: p.worktree,
        vcs: p.vcs,
        name: p.name,
        icon: p.icon,
        commands: p.commands,
        sandboxes: p.sandboxes
            .where((d) => d != worktreeDir)
            .toList(growable: false),
        created: p.created,
      );
    }
    final removedIds = _sessions
        .where((s) => s.directory == worktreeDir)
        .map((s) => s.id)
        .toSet();
    _sessions.removeWhere((s) => s.directory == worktreeDir);
    for (final sid in removedIds) {
      _conversations.remove(sid);
      _lastMessage.remove(sid);
      _statusMap.remove(sid);
    }
    _scheduleCacheSave();
    notifyListeners();
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
    if (activeClient == null) throw const KnownError(FriendlyErrorKind.notConnected);
    try {
      final session = await activeClient.createSession(directory);
      _upsertSession(session);
      notifyListeners();
      return session;
    } catch (e) {
      throw OperationException('创建会话', cause: e);
    }
  }

  Future<SessionModel> createSessionInNewWorktree(
    String projectDir, {
    bool reconcileFirst = false,
  }) async {
    final c = client;
    if (c == null) throw const KnownError(FriendlyErrorKind.notConnected);
    WorktreeResult? wt;
    if (reconcileFirst) {
      wt = await _recoverAmbiguousWorktree(c, projectDir);
    }
    if (wt == null) {
      try {
        wt = await c.createWorktree(projectDir);
      } catch (e) {
        final kind = friendlyErrorRaw(e);
        if (kind == FriendlyErrorKind.timeout ||
            kind == FriendlyErrorKind.connect) {
          wt = await _recoverAmbiguousWorktree(c, projectDir);
        }
        if (wt == null) throw OperationException('创建工作区', cause: e);
      }
    }
    final worktree = wt;
    final idx = _projects.indexWhere((p) => p.worktree == projectDir);
    if (idx >= 0 && !_projects[idx].sandboxes.contains(worktree.directory)) {
      final p = _projects[idx];
      _projects[idx] = ProjectModel(
        id: p.id,
        worktree: p.worktree,
        vcs: p.vcs,
        name: p.name,
        icon: p.icon,
        commands: p.commands,
        sandboxes: [...p.sandboxes, worktree.directory],
        created: p.created,
      );
      _scheduleCacheSave();
      notifyListeners();
    }
    final SessionModel session;
    try {
      session = await c.createSession(worktree.directory);
    } catch (e) {
      throw SessionInWorktreeException(
        '创建会话',
        cause: e,
        worktreeDirectory: worktree.directory,
      );
    }
    _upsertSession(session);
    _scheduleCacheSave();
    notifyListeners();
    return session;
  }

  Future<WorktreeResult?> _recoverAmbiguousWorktree(
    OpencodeClient c,
    String projectDir,
  ) async {
    try {
      final remote = await c.worktrees(projectDir);
      final idx = _projects.indexWhere((p) => p.worktree == projectDir);
      final known = <String>{
        projectDir,
        if (idx >= 0) ..._projects[idx].sandboxes,
      };
      final candidates = remote.where((d) => !known.contains(d)).toList();
      if (candidates.length != 1) return null;
      final dir = candidates.single;
      return WorktreeResult(name: dir.split('/').last, directory: dir);
    } catch (_) {
      return null;
    }
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
    if (!_hasMultipleWorktrees(s.projectID)) return '';
    final project = projectOf(s.projectID);
    if (project != null && s.directory == project.worktree) {
      return _loc?.projectMainWorkspace ?? 'main';
    }
    return s.dirName;
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
    if (sid != null) {
      // Opening a conversation wakes the stream out of reconnect backoff —
      // parity with the old per-directory `_startSse(required: true)` kick,
      // so live updates don't wait out the exponential sleep (or the next
      // health probe) while the user is looking at this session.
      _sse?.reconnectNow();
    }
  }

  /// Wake the global SSE stream out of reconnect backoff on user interaction
  /// (send message / permission / question cards) — same kick the old
  /// per-directory `ensureSseForSession` provided, now connection-wide.
  void ensureSseForSession(String sessionId) {
    _sse?.reconnectNow();
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
    final conv = ConversationStore(sid, c,
        directory: directory, cacheStore: _cacheStore);
    conv.onQuestionResolved = _markQuestionResolved;
    conv.onPermissionResolved = _markPermissionResolved;
    _conversations[sid] = conv;
    final initStatus = statusOf(sid);
    conv.setStatus(initStatus.type, retryMessage: initStatus.message);
    conv.sessionUpdated = sessionById(sid)?.updated;
    // Re-apply ghost state after an LRU eviction: the flag lives on the
    // ConversationStore instance, which was dropped; the set survives.
    if (_ghostSessionIds.contains(sid)) conv.markWorkspaceMissing();
    // Inject any pending permission/question known from SSE/REST backfill.
    final pending = _pendingPermissions[sid];
    if (pending != null) conv.onPermission(pending);
    for (final q in _pendingQuestions.values) {
      if (q.sessionID == sid) conv.onQuestion(q);
    }
    unawaited(conv.loadDraftOnly()); // CD-1/13：构造后异步读草稿（唯一草稿读路径）
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
    final generation = ++_connectGeneration;
    _connecting = true;
    // A retry is in flight — drop the stale failure so the UI shows the
    // loading state instead of the previous attempt's error view.
    bootstrapFailed = false;
    notifyListeners();
    AppLogger.I.i(_tag, 'connect ${profile.hostDisplay}');
    try {
      // Flush pending cache save for the OUTGOING profile before switching
      // _profile — _stopSse's flush runs AFTER reassignment and would write
      // old profile data to the new profile's key (cross-profile leak).
      if (_cacheSaveTimer != null) {
        _cacheSaveTimer!.cancel();
        _cacheSaveTimer = null;
        await _saveCache();
      }
      _profile = profile;
      _cacheStore = FileCacheStore(profile.id);
      await _teardown(flushCache: false);
      _projects = [];
      _sessions = [];
      _statusMap.clear();
      _ghostSessionIds.clear();
      _lastMessage.clear();
      _lastActivityByKey.clear();
      _workspaceEnabled.clear();
      _projectsFetched = false;
      commandsNotifier.value = const [];
      _commandsDegraded = false;
      _commandsCacheDir = null;
      _commandsCacheComplete = false;
      _suspiciousEmptyStreak = 0;
      // Load cached data first for instant offline UI, then _bootstrap refreshes.
      await _loadCache();
      final dio = dioFor(profile, store: _connectionStore);
      _agentsModelsCache.clear();
      _agentsModelsInFlight.clear();
      _agentsModelsFetchedAt.clear();
      client = OpencodeClient(dio);
      refreshSseAuth(profile);
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
      // One global stream covers every directory.
      _startSse();
      _lastFullRefreshAt = DateTime.now();
      connected = true;
      unawaited(_backfillPermissions());
      notifyListeners();
    } catch (e) {
      AppLogger.I.e(_tag, 'connect failed ${profile.hostDisplay}: $e');
      client = null;
      bootstrapFailed = true;
      connected = false;
      notifyListeners();
    } finally {
      if (generation == _connectGeneration) {
        _connecting = false;
        notifyListeners();
      }
    }
  }

  /// Directory universe: every project's worktree ∪ its sandboxes ∪ every
  /// known session directory. Shared source for the SSE event gate
  /// (`_isGatedDirectory`) and REST fan-out (permission/question backfill).
  Set<String> _eventDirectories() {
    final dirs = <String>{};
    for (final p in _projects) {
      if (p.worktree.isNotEmpty) dirs.add(p.worktree);
      for (final d in p.sandboxes) {
        if (d.isNotEmpty) dirs.add(d);
      }
    }
    for (final s in _sessions) {
      if (s.directory.isNotEmpty) dirs.add(s.directory);
    }
    return dirs;
  }

  /// Gate for the single global stream: accept events whose envelope directory
  /// belongs to this client's universe. The stream carries EVERY project's
  /// events on the server; without this filter unknown directories would
  /// pollute `_sessions` / `_statusMap` / `_conversations`.
  bool _isGatedDirectory(String directory) {
    // Keep in lockstep with `_eventDirectories()` (same universe, same
    // empty-string exclusion).
    if (directory.isEmpty) return false;
    for (final p in _projects) {
      if (p.worktree == directory) return true;
      if (p.sandboxes.contains(directory)) return true;
    }
    for (final s in _sessions) {
      if (s.directory == directory) return true;
    }
    return false;
  }

  void _startSse() {
    final existing = _sse;
    if (existing != null) {
      // Wake the client if it's sleeping in reconnect backoff (e.g., resume
      // after background Doze) — no reason to wait out the exponential sleep.
      existing.reconnectNow();
      return;
    }
    final c = SseClient(baseUrl: _profile!.baseUrl, headers: _sseHeaders);
    _sse = c;
    _sseSub = c.events
        .listen(_onGlobalEvent); // SSE errors handled by _onSseState reconnect
    _sseStateSub = c.state.listen(_onSseState);
    c.start();
  }

  String _signature(ConnectionProfile p) =>
      '${p.baseUrl}|${p.authMethod.name}|${p.username}|${p.password}';

  /// ConnectionStore reference for auth-token lifecycle (interceptor
  /// persistence + authBroken). Assigned by app wiring (cannot import
  /// app_state); null in unit tests.
  ConnectionStore? _connectionStore;

  set connectionStore(ConnectionStore? value) => _connectionStore = value;

  /// Rebuild `_sseHeaders` IN PLACE: SseClient instances hold this map by
  /// reference and spread it on every (re)connect, so a rotated token is
  /// picked up by the existing reconnect path without new machinery.
  void refreshSseAuth(ConnectionProfile profile) {
    _sseHeaders
      ..clear()
      ..addAll(authHeadersFor(profile));
  }

  /// Pure sandboxes filter: intersect each project's `sandboxes` with its
  /// already-fetched worktree list (server-side sandboxes ∩ real git
  /// worktrees). Fail-open per project: a missing or empty list keeps the
  /// unfiltered sandboxes — the endpoint returns 200 `[]` for degraded
  /// states (deleted main dir, unregistered repo) where wiping every
  /// sandbox would be wrong. The main worktree itself is always kept.
  List<ProjectModel> _filterSandboxes(
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) {
    return projects.map((p) {
      if (p.sandboxes.isEmpty || p.worktree.isEmpty) return p;
      final real = worktreesByDir[p.worktree];
      if (real == null || real.isEmpty) return p;
      final valid = real.toSet()..add(p.worktree);
      final filtered =
          p.sandboxes.where(valid.contains).toList(growable: false);
      if (filtered.length == p.sandboxes.length) return p;
      return ProjectModel(
        id: p.id,
        worktree: p.worktree,
        vcs: p.vcs,
        name: p.name,
        icon: p.icon,
        commands: p.commands,
        sandboxes: filtered,
        created: p.created,
      );
    }).toList();
  }

  /// `GET /project` returns the persisted `sandboxes` list verbatim; entries
  /// whose directory vanished outside `DELETE /experimental/worktree`
  /// (manual `git worktree remove` / `rm`, failed creations) linger as
  /// ghosts. Fetch `GET /experimental/worktree` per project and apply
  /// `_filterSandboxes` right after fetch so ghost workspaces never reach
  /// the picker. Fail-open per project: a fetch error keeps the unfiltered
  /// list. Successful fetches are recorded in [worktreesByDir] (keyed by
  /// main worktree) so `_sessionsForProject` can reuse them instead of
  /// fetching the same endpoint twice on the bootstrap critical path.
  Future<List<ProjectModel>> _reconcileSandboxes(
    List<ProjectModel> projects, {
    Map<String, List<String>>? worktreesByDir,
  }) async {
    final c = client;
    if (c == null) return projects;
    final map = worktreesByDir ?? <String, List<String>>{};
    await Future.wait(projects.map((p) async {
      if (p.sandboxes.isEmpty || p.worktree.isEmpty) return;
      try {
        map[p.worktree] = await c.worktrees(p.worktree);
      } catch (_) {}
    }));
    return _filterSandboxes(projects, map);
  }

  /// Mark ghost sessions' open conversations as unusable and settle their
  /// cached status to idle — the directory is never status-fetched again, so
  /// a stale `busy` would otherwise persist forever (stop button rendered
  /// next to the workspace-missing banner, abort always failing).
  void _markGhostSessions(Set<String> ids) {
    for (final id in ids) {
      _statusMap[id] = const SessionStatusValue('idle');
      _ghostSessionIds.add(id);
      _conversations[id]?.markWorkspaceMissing();
    }
  }

  /// Drop ghost tracking for sessions that reappeared in an authoritative
  /// list (worktree re-created at the same path, or a transiently incomplete
  /// worktree list had caused a false positive). Live conversations are
  /// un-flagged by the per-conv loop in `refreshListAndWorkingSse`.
  void _unghostRecovered(List<SessionModel> sessions) {
    if (_ghostSessionIds.isEmpty) return;
    for (final s in sessions) {
      _ghostSessionIds.remove(s.id);
    }
  }

  /// Sessions that existed before a refresh but vanished from the fresh
  /// authoritative list AND whose directory is no longer reachable — not in
  /// the project's main worktree nor its fetched worktree list. Such a
  /// directory is a ghost sandbox (deleted outside the DELETE endpoint);
  /// the session is unusable (no SSE coverage, git/snapshot broken).
  /// Fail-open: projects with a missing/empty worktree list are skipped, as
  /// are `global` sessions (fetched without directory coverage).
  Set<String> _detectGhostSessionIds(
    List<SessionModel> oldSessions,
    List<SessionModel> newSessions,
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) {
    final newIds = newSessions.map((s) => s.id).toSet();
    final byId = {for (final p in projects) p.id: p};
    final out = <String>{};
    for (final old in oldSessions) {
      if (newIds.contains(old.id)) continue;
      if (old.directory.isEmpty) continue;
      final p = byId[old.projectID];
      if (p == null || p.id == 'global') continue;
      final wt = worktreesByDir[p.worktree];
      if (wt == null || wt.isEmpty) continue;
      if (old.directory == p.worktree || wt.contains(old.directory)) continue;
      out.add(old.id);
    }
    return out;
  }

  Future<bool> _bootstrap() async {
    try {
      final worktreesByDir = <String, List<String>>{};
      final projects = await _reconcileSandboxes(
        await client!.projects(),
        worktreesByDir: worktreesByDir,
      );
      final sessions = await _fetchAllSessions(
          projects: projects, worktreesByDir: worktreesByDir);
      final fetchedDirs = <String>{};
      final status = await _fetchAllStatuses(
          projects: projects, sessions: sessions, fetchedDirs: fetchedDirs);
      // Ghost detection also runs here (not just in refreshListAndWorkingSse):
      // `_sessions` still holds the cache loaded by `_loadCache`, which may
      // contain sessions whose worktree vanished while the app was away.
      // Without this they stay sendable until the first reconcile arrives.
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, projects, worktreesByDir);
      _projects = projects;
      _projectsFetched = true;
      _sessions = sessions;
      _markGhostSessions(ghostIds);
      _mergeStatus(fresh: status, sessions: sessions, fetchedDirs: fetchedDirs);
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
  ///
  /// [fetchedDirs], when non-null, records every directory fetched without
  /// throwing. The caller uses it to tell which sessions received a fresh,
  /// authoritative status (so the merge can keep the cached value for sessions
  /// whose directory fetch failed — see [_mergeStatus]).
  Future<Map<String, SessionStatusValue>> _fetchAllStatuses({
    required List<ProjectModel> projects,
    List<SessionModel> sessions = const [],
    Set<String>? fetchedDirs,
  }) async {
    final dirs = <String>{};
    for (final p in projects) {
      if (p.worktree.isNotEmpty) dirs.add(p.worktree);
    }
    for (final s in sessions) {
      if (s.directory.isNotEmpty) dirs.add(s.directory);
    }
    final out = <String, SessionStatusValue>{};
    await Future.wait(dirs.map((dir) async {
      try {
        final r = await client!.sessionStatus(directory: dir);
        out.addAll(r);
        fetchedDirs?.add(dir);
      } catch (_) {}
    }));
    return out;
  }

  /// Merge freshly-fetched status into the in-memory status cache.
  ///
  /// `_statusMap` is a pure in-memory cache (never persisted): it survives a
  /// background pause so the UI shows the pre-leave status the instant the app
  /// resumes, then is updated once the REST fetch returns ("优先展示离开前的
  /// 缓存状态，获取到最新状态后再更新").
  ///
  /// Sessions whose directory was fetched successfully are authoritative —
  /// their fresh value wins, and absence from [fresh] ⇒ idle. Sessions in a
  /// directory whose fetch FAILED keep their cached status, so a flaky resume
  /// never wipes a known busy/retry indicator to idle (the regression behind
  /// cdb0872 / SS-1).
  void _mergeStatus({
    required Map<String, SessionStatusValue> fresh,
    required List<SessionModel> sessions,
    required Set<String> fetchedDirs,
  }) {
    final covered = <String>{};
    for (final s in sessions) {
      if (fetchedDirs.contains(s.directory)) covered.add(s.id);
    }
    final merged = <String, SessionStatusValue>{};
    _statusMap.forEach((id, v) {
      if (!covered.contains(id)) merged[id] = v;
    });
    merged.addAll(fresh);
    _statusMap
      ..clear()
      ..addAll(merged);
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
  Future<List<SessionModel>> _fetchAllSessions({
    List<ProjectModel>? projects,
    Map<String, List<String>>? worktreesByDir,
  }) async {
    final ps = projects ?? _projects;
    final futures = <Future<List<SessionModel>>>[];
    for (final p in ps) {
      if (p.id == 'global') {
        futures.add(client!.sessions());
      } else {
        futures.add(_sessionsForProject(p, worktreesByDir));
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
  /// the main worktree and every worktree in parallel. [worktreesByDir], when
  /// it already covers the project's main worktree (populated by
  /// `_reconcileSandboxes` on the same refresh), skips the duplicate
  /// `GET /experimental/worktree` round-trip; cache-miss fetches are recorded
  /// back into it so the ghost filter/detection can reuse the result.
  Future<List<SessionModel>> _sessionsForProject(
    ProjectModel p, [
    Map<String, List<String>>? worktreesByDir,
  ]) async {
    var worktrees = worktreesByDir?[p.worktree];
    if (worktrees == null) {
      worktrees = await _safeWorktrees(p.worktree);
      worktreesByDir?[p.worktree] = worktrees;
    }
    final dirs = [p.worktree, ...worktrees]
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
  int _reconcileScheduleCount = 0;

  /// Number of times [_scheduleReconcile] was entered (for asserting the
  /// transition-only scheduling guard, not debounced firings).
  @visibleForTesting
  int get reconcileScheduleCountForTesting => _reconcileScheduleCount;

  void _scheduleReconcile() {
    _reconcileScheduleCount++;
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_reconcile());
    });
  }

  /// Unified refresh entry point: REST fetch (+ ensure the global SSE runs).
  ///
  /// `force: true` — also (re)start the global SSE. Used when the stream is
  ///   missing (resume after pause, refresh recovering a failed connection).
  /// `force: false` — REST refresh only; running SSE untouched.
  Future<bool> refreshListAndWorkingSse({bool force = false}) async {
    if (client == null) return false;
    PerfProbe.I.markEvent('refresh-start force=$force');
    try {
      if (force || _sse == null) {
        _startSse();
      }
      List<ProjectModel> newProjects;
      final worktreesByDir = <String, List<String>>{};
      if (force || !_projectsFetched) {
        newProjects = await _reconcileSandboxes(
          await client!.projects(),
          worktreesByDir: worktreesByDir,
        );
      } else {
        newProjects = _projects;
      }
      _projectsFetched = true;
      final sessions = await _fetchAllSessions(
          projects: newProjects, worktreesByDir: worktreesByDir);
      // Ghost cleanup using data the session fetch already paid for: drop
      // sandbox entries whose directory no longer exists, and mark open
      // conversations whose session just proved unreachable (no SSE
      // coverage → replies would never render).
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, newProjects, worktreesByDir);
      // On the force path `_reconcileSandboxes` already filtered with the same
      // map (idempotent no-op here); on the reconcile path this is the pass
      // that actually cleans in-memory sandboxes using data the session fetch
      // already paid for.
      newProjects = _filterSandboxes(newProjects, worktreesByDir);
      final fetchedDirs = <String>{};
      final status = await _fetchAllStatuses(
          projects: newProjects, sessions: sessions, fetchedDirs: fetchedDirs);
      _projects = newProjects;
      _sessions = sessions;
      _markGhostSessions(ghostIds);
      _mergeStatus(fresh: status, sessions: sessions, fetchedDirs: fetchedDirs);
      _inferWorkspaceForNewProjects();
      for (final conv in _conversations.values) {
        final s = statusOf(conv.sessionId);
        conv.setStatus(s.type, retryMessage: s.message);
        final fresh = sessionById(conv.sessionId);
        conv.sessionUpdated = fresh?.updated;
        if (fresh != null) conv.clearWorkspaceMissing();
      }
      _lastFullRefreshAt = DateTime.now();
      connected = true;
      _scheduleCacheSave();
      // server.connected → reconcile → here: re-pull commands so a transient
      // empty (network-recovery blip) gets overwritten, mirroring desktop's
      // bootstrap re-run on server.connected.
      final activeId = _activeSessionId;
      if (activeId != null) {
        unawaited(refreshCommands(directory: sessionById(activeId)?.directory));
      }
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
    PerfProbe.I.markEvent('refresh-done');
    notifyListeners();
    return true;
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
    if (_backfillInFlight) {
      _backfillDirty = true;
      return;
    }
    _backfillInFlight = true;
    try {
      _purgeExpiredResolved();
      final prev = Map.of(_pendingPermissions);
      // R-Perm-3: fetch per all event directories (includes sandbox worktrees),
      // not just main project worktrees, so sandbox session permissions are
      // covered.
      final dirs = _eventDirectories();
      final failedDirs = <String>{};
      final next = <String, Permission>{};
      for (final dir in dirs) {
        try {
          final pending = await c.pendingPermissions(dir);
          for (final perm in pending) {
            if (_recentlyResolvedPermissions.containsKey(perm.id)) {
              AppLogger.I.i(_tag, 'backfill permission skipped (recently resolved) sid=${perm.sessionID} pid=${perm.id} dir=$dir');
              continue;
            }
            next[perm.sessionID] = perm;
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
          next.putIfAbsent(entry.key, () => entry.value);
        }
      }
      _mergeWindowMutations(
          next: next,
          prev: prev,
          live: _pendingPermissions,
          idOf: (p) => p.id,
          isResolved: _recentlyResolvedPermissions.containsKey);
      // R-Perm-1: notify if the permission map changed so list shield updates.
      final changed = _pendingPermissions.length != next.length ||
          !_pendingPermissions.keys.toSet().containsAll(next.keys);
      // The live map is only replaced synchronously here — clearing up front and
      // refilling per REST response would expose a half-empty snapshot to any
      // notify during the window (indicator flicker paused ↔ working).
      _pendingPermissions
        ..clear()
        ..addAll(next);
      if (changed) {
        notifyListeners();
      }
      await _backfillQuestions();
    } finally {
      _backfillInFlight = false;
      if (_backfillDirty) {
        _backfillDirty = false;
        unawaited(_backfillPermissions());
      }
    }
  }

  /// Fetch pending questions via REST, same pattern as permissions.
  Future<void> _backfillQuestions() async {
    final c = client;
    if (c == null) return;
    _purgeExpiredResolved();
    final prev = Map.of(_pendingQuestions);
    final dirs = _eventDirectories();
    final failedDirs = <String>{};
    final next = <String, QuestionRequest>{};
    for (final dir in dirs) {
      try {
        final pending = await c.listQuestions(directory: dir);
        for (final q in pending) {
          if (_recentlyResolvedQuestions.containsKey(q.id)) {
            AppLogger.I.i(_tag, 'backfill question skipped (recently resolved) sid=${q.sessionID} qid=${q.id} dir=$dir');
            continue;
          }
          next[q.id] = q;
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
        next.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _mergeWindowMutations(
        next: next,
        prev: prev,
        live: _pendingQuestions,
        idOf: (q) => q.id,
        isResolved: _recentlyResolvedQuestions.containsKey);
    final changed = _pendingQuestions.length != next.length ||
        !_pendingQuestions.keys.toSet().containsAll(next.keys);
    _pendingQuestions
      ..clear()
      ..addAll(next);
    if (changed) {
      notifyListeners();
    }
  }

  /// Fold mutations that hit [live] while an async rebuild was in flight into
  /// [next]: entries added or replaced by SSE are newer than the REST snapshot
  /// and win; entries removed from [live] (replied / locally resolved) must not
  /// be resurrected by a stale snapshot. [isResolved] is re-applied after the
  /// merge so a card asked and resolved entirely inside the window — its echo
  /// already recorded into [next] by the REST loop — is dropped too.
  void _mergeWindowMutations<V>(
      {required Map<String, V> next,
      required Map<String, V> prev,
      required Map<String, V> live,
      required String Function(V) idOf,
      required bool Function(String id) isResolved}) {
    final prevIds = prev.values.map(idOf).toSet();
    final liveIds = live.values.map(idOf).toSet();
    next.removeWhere(
        (_, v) => prevIds.contains(idOf(v)) && !liveIds.contains(idOf(v)));
    live.forEach((key, v) {
      final old = prev[key];
      if (old == null || idOf(old) != idOf(v)) next[key] = v;
    });
    next.removeWhere((_, v) => isResolved(idOf(v)));
  }

  void _onSseState(SseState s) {
    final wasLive = _sseLive;
    _sseLive = s.connected;
    // Mark "failed" whenever the stream enters reconnecting state.
    // On a normal start the first state event is connected:true (no
    // reconnecting), so the banner stays suppressed. On a no-network
    // start the first event is reconnecting:true — the banner shows.
    // On a post-connect drop, the reconnecting event also fires — same.
    if (!s.connected && s.reconnecting) {
      _sseFailed = true;
    }
    // While the stream is reconnecting (server might be unreachable), probe
    // /global/health every 5s. A successful probe proves reachability long
    // before the exponential backoff (up to 30s) would fire, so we kick the
    // client out of its sleep immediately. The connected state stops the
    // probe (authoritative reachability signal).
    if (s.reconnecting) {
      _startHealthProbe();
    } else if (s.connected) {
      _stopHealthProbe();
    }
    if (s.reconnecting) {
      _needsStaleMarking = true;
    }
    // Schedule reconcile ONLY on the not-live → live transition. The client
    // emits connected state on EVERY data frame; scheduling per frame would
    // reset the 800ms debounce on every token of any active stream, deferring
    // the post-disconnect reconcile indefinitely while the server is busy.
    // Reconcile is the sole recovery path for the disconnect window
    // (design-sse-global-event.md §1.3), so it must fire on reconnect
    // regardless of stream traffic.
    if (!s.reconnecting && s.connected && !wasLive) {
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
      _sse?.reconnectNow();
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
  /// private), BYPASSING the directory gate. Lets tests assert the
  /// `message.part.updated` case's `break`->`return` (LPS-1) throttle behavior
  /// through the real event route (including the switch's trailing notify)
  /// without seeding projects/sessions for the gate.
  @visibleForTesting
  void onEventForTesting(OpencodeEvent ev) => _onEvent(ev);

  /// Test seam driving an event through the real global-stream route
  /// [_onGlobalEvent] INCLUDING the directory gate.
  @visibleForTesting
  void onGlobalEventForTesting(String directory, OpencodeEvent ev) =>
      _onGlobalEvent(GlobalOpencodeEvent(directory: directory, event: ev));

  /// Test seam exposing the gate for direct assertions.
  @visibleForTesting
  bool isGatedDirectoryForTesting(String directory) =>
      _isGatedDirectory(directory);

  /// Test seam to drive SSE lifecycle states into [_onSseState]. Used by
  /// health-probe tests to simulate reconnecting/connected.
  @visibleForTesting
  void onSseStateForTesting(SseState s) => _onSseState(s);

  /// Test seam for the REST bulk-fetch path [addSessionsForTesting] merges a
  /// list of sessions into a per-id map exactly as `_fetchAllSessions` does,
  /// bumping `_lastActivityByKey` before the archived/parent filter. Used by
  /// PA-4 to lock that ordering invariant on the REST path (not just SSE).
  @visibleForTesting
  void addSessionsForTesting(Map<String, SessionModel> out, List<SessionModel> list) =>
      _addSessions(out, list);

  /// Test seam for the cache round-trip path. Sets `_profile` + `_cacheStore`
  /// (required by `_loadCache`) and loads cache. Used by PA-R2 to assert that
  /// an `activity` blob is restored, and that a stale cached value does NOT
  /// overwrite a fresher in-memory value (the monotonic-max merge in
  /// `_loadCache`).
  @visibleForTesting
  Future<void> loadCacheForTesting(ConnectionProfile profile) async {
    _profile = profile;
    _cacheStore = FileCacheStore(profile.id);
    await _loadCache();
  }

  /// Test seam: drive `_upsertSession` to populate `_sessions` (needed by
  /// `_eventDirectories` / `sessionById`) without going through SSE.
  @visibleForTesting
  void upsertSessionForTesting(SessionModel s) => _upsertSession(s);

  /// Test seam: set `_projects` directly (needed by `removeWorktree` which
  /// looks up the project by worktree path).
  @visibleForTesting
  void setProjectsForTesting(List<ProjectModel> projects) =>
      _projects = projects;

  /// Test seam: drive the post-fetch ghost filtering of `sandboxes`
  /// (see `_reconcileSandboxes`) without a full connect()/bootstrap.
  @visibleForTesting
  Future<List<ProjectModel>> reconcileSandboxesForTesting(
          List<ProjectModel> projects) =>
      _reconcileSandboxes(projects);

  /// Test seam: drive `_sessionsForProject` to verify `worktreesByDir`
  /// reuse (skipping the duplicate `GET /experimental/worktree`).
  @visibleForTesting
  Future<List<SessionModel>> sessionsForProjectForTesting(
    ProjectModel p, [
    Map<String, List<String>>? worktreesByDir,
  ]) =>
      _sessionsForProject(p, worktreesByDir);

  /// Test seam: pure sandboxes filter over pre-fetched worktree lists.
  @visibleForTesting
  List<ProjectModel> filterSandboxesForTesting(
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) =>
      _filterSandboxes(projects, worktreesByDir);

  /// Test seam: pure detection of sessions whose directory became
  /// unreachable (ghost sandbox) across a refresh.
  @visibleForTesting
  Set<String> detectGhostSessionIdsForTesting(
    List<SessionModel> oldSessions,
    List<SessionModel> newSessions,
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) =>
      _detectGhostSessionIds(oldSessions, newSessions, projects, worktreesByDir);

  /// Test seam: drive ghost tracking (mark / un-ghost) to verify the flag
  /// survives conversation eviction via `_ghostSessionIds`.
  @visibleForTesting
  void markGhostSessionsForTesting(Set<String> ids) => _markGhostSessions(ids);

  @visibleForTesting
  void unghostRecoveredForTesting(List<SessionModel> sessions) =>
      _unghostRecovered(sessions);

  /// Test seam for the in-memory status-cache merge. Seeds `_statusMap` first
  /// via `session.status` events, then call this to assert the resume-time
  /// merge: fresh values win for fetched dirs, cached values survive for dirs
  /// whose fetch failed.
  @visibleForTesting
  void mergeStatusForTesting({
    required Map<String, SessionStatusValue> fresh,
    required List<SessionModel> sessions,
    required Set<String> fetchedDirs,
  }) =>
      _mergeStatus(fresh: fresh, sessions: sessions, fetchedDirs: fetchedDirs);

  /// Test seam: drive `_backfillQuestions` directly to verify the
  /// `_recentlyResolvedQuestions` guard skips recently-resolved ids.
  @visibleForTesting
  Future<void> backfillQuestionsForTesting() => _backfillQuestions();

  /// Test seam: drive `_backfillPermissions` directly (atomic-swap regression:
  /// the live map must stay populated while the REST fetches are in flight).
  @visibleForTesting
  Future<void> backfillPermissionsForTesting() => _backfillPermissions();

  /// Test seam: simulate TTL expiry by clearing the resolved-guard sets.
  /// Used to verify the "re-surface if still pending server-side" path
  /// (关键设计决策 4).
  @visibleForTesting
  void expireRecentlyResolvedForTesting() {
    _recentlyResolvedQuestions.clear();
    _recentlyResolvedPermissions.clear();
  }

  @visibleForTesting
  void installSseForTesting(SseClient sse) {
    _sse = sse;
  }

  @visibleForTesting
  bool get hasSseForTesting => _sse != null;

  @visibleForTesting
  Future<void> stopSseForTesting() => _stopSse(flushCache: false);

  /// Global-stream entry point: gate by envelope directory, then route into
  /// [_onEvent]. `'global'` frames (`server.connected` / `server.heartbeat`)
  /// bypass the gate — they carry no directory and drive connection state.
  void _onGlobalEvent(GlobalOpencodeEvent gev) {
    final directory = gev.directory;
    if (directory != 'global' && !_isGatedDirectory(directory)) return;
    _onEvent(gev.event);
  }

  void _onEvent(OpencodeEvent ev) {
    switch (ev.type) {
      case 'server.heartbeat':
        // No-op: heartbeat carries no data and should not trigger a global
        // notifyListeners() — every ListenableBuilder(serverStore) would
        // rebuild (AppBar ×3, body, tabs) for no reason. Just keep the SSE
        // connection alive (already handled by the transport layer).
        return;
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
            unawaited(NotificationService.notifyRunComplete(
                    sessionById(sid)?.title)
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
        if (info is Map) {
          final sid = (info['id'] ?? '').toString();
          _removeSession(sid);
          fileBrowsing.removeSessionData(sid);
        }
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
        }
        break;
      case 'message.updated':
        final msgInfo = ev.properties['info'];
        final msgSid = msgInfo is Map ? msgInfo['sessionID']?.toString() : null;
        if (msgSid != null) fileBrowsing.invalidateContentForSession(msgSid);
        unawaited(_onMessageUpdated(ev.properties));
        return;
      case 'message.part.delta':
        // Streaming token delta. Route to the conversation's onPartUpdated
        // (same as message.part.updated) but early-return: the detail page is
        // driven by conv.notifyListeners() and the list preview by
        // _notifyPreviewChanged() (120ms throttle). A global notifyListeners()
        // here would rebuild every ListenableBuilder(serverStore) per token.
        final dPart = ev.properties['part'];
        final dSid = dPart is Map ? dPart['sessionID']?.toString() : null;
        final dDelta = ev.properties['delta']?.toString();
        final dPtype = dPart is Map ? dPart['type']?.toString() : null;
        if (dSid != null) fileBrowsing.invalidateContentForSession(dSid);
        if (dSid != null && dPart is Map) {
          final conv = ensureConversation(dSid);
          if (conv != null) {
            conv.onPartUpdated(dPart.cast(), dDelta);
            if (dPtype == 'tool' || dPtype == 'text' || dPtype == 'reasoning') {
              final pv = conv.lastMessagePreview(
                  hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
              if (pv != null) {
                _lastMessage[dSid] = pv;
                _notifyPreviewChanged();
                _scheduleCacheSave();
              }
            }
          }
        }
        return;
      case 'file.watcher.updated':
        // File system change notification — no app state to update. Would
        // trigger a global notifyListeners() for no reason (every tab + AppBar
        // rebuilds). fileBrowsing invalidates lazily on next content fetch.
        return;
      case 'pty.updated':
        // Terminal PTY state change — not consumed by the app. Same rationale
        // as file.watcher.updated: no global rebuild needed.
        return;
      case 'message.part.updated':
        final part = ev.properties['part'];
        final sid = part is Map ? part['sessionID']?.toString() : null;
        final delta = ev.properties['delta']?.toString();
        final ptype = part is Map ? part['type']?.toString() : null;
        if (sid != null) fileBrowsing.invalidateContentForSession(sid);
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
              final pv = conv.lastMessagePreview(
                  hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
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
        unawaited(NotificationService.notifyPermission(
                sessionById(p.sessionID)?.title, p)
            .catchError((_) {}));
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
          // Register the resolved guard too (not just live-map removal): a
          // reply made by another client must not be resurrected by the next
          // backfill's REST snapshot (same mechanism as the local reply path).
          _markPermissionResolved(pid);
          _conversations[sid]?.onPermissionReplied(pid);
        }
        break;
      case 'question.asked':
      case 'question.v2.asked':
        final qr = QuestionRequest.fromJson(ev.properties);
        _pendingQuestions[qr.id] = qr;
        _conversations[qr.sessionID]?.onQuestion(qr);
        AppLogger.I.i(_tag, 'SSE question.asked sid=${qr.sessionID} qid=${qr.id}');
        unawaited(NotificationService.notifyQuestion(
                sessionById(qr.sessionID)?.title,
                qr.questions.firstOrNull?.header)
            .catchError((_) {}));
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
          // Same as permission.replied: register the resolved guard so a
          // cross-client reply isn't resurrected by the next backfill.
          _markQuestionResolved(qid);
        }
        if (sid != null && qid != null) {
          _conversations[sid]?.onQuestionReplied(qid);
        }
        break;
      case 'catalog.updated':
      case 'mcp.tools.changed':
        // Command/skill catalog or MCP tools changed on the server — re-pull
        // so new/deleted slash commands reflect without waiting for the next
        // `/` input (mirrors desktop's command.updated / mcp.status.changed →
        // bootstrap re-run). Uses the active session's directory; refreshCommands
        // guards against duplicate in-flight refreshes for the same directory.
        final activeId = _activeSessionId;
        if (activeId != null) {
          unawaited(refreshCommands(directory: sessionById(activeId)?.directory));
        }
        break;
    }
    PerfProbe.I.markEvent('sse-notify ${ev.type}');
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
    PerfProbe.I.markEvent('msg-updated-notify $sid');
    notifyListeners();
    // List preview: refresh on every message event — user msg, in-flight
    // assistant (finish empty), and completed assistant (finish non-empty).
    // Covers the "no part event, only message.updated" edge (e.g. empty or
    // reasoning-only assistant messages). Part events keep the preview live
    // during streaming; this keeps it correct at message boundaries.
    final local = conv?.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
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
    final preview = conv.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
    if (preview != null) {
      _lastMessage[sid] = preview;
      _bumpPreview();
    }
  }

  /// Reflect the latest preview from the given conversation into the list cache.
  /// Used after optimistic user-message insertion so the list shows it without
  /// waiting for the message.updated(user) SSE event.
  void reflectPreviewFrom(String sid) {
    final conv = _conversations[sid];
    if (conv == null) return;
    final pv = conv.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
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
  }

  void _removeSession(String id) {
    _sessions.removeWhere((s) => s.id == id);
    _conversations.remove(id);
    _lastMessage.remove(id);
    _statusMap.remove(id);
    _ghostSessionIds.remove(id);
    final cs = _cacheStore;
    if (cs != null) unawaited(cs.remove('conv/$id'));
    // Intentionally keeps `_lastActivityByKey` — activity is monotonic across
    // deletes too. Removing the entry here would sink the project if its last
    // observed session is hard-deleted (PA-5 locks this invariant). The entry
    // is stale only in the sense of "session no longer exists server-side",
    // which doesn't affect sort correctness for the remaining sessions.
    _scheduleCacheSave();
  }

  Future<void> _teardown({bool flushCache = true}) async {
    await _stopSse(flushCache: flushCache);
    if (flushCache) {
      // CD-24：与 _stopSse 的 flushCache 门控对齐（切 profile 走 flushCache:false，
      // 不 flush 旧 profile 的 conv_<sid> 键，避免跨 profile 草稿污染）。
      // CD-25：Future.wait 并行，缩短销毁窗口。先 persist 再 dispose（CD-3 卫生）。
      await Future.wait(
        _conversations.values.map((c) => c.persistDraft()),
      );
    }
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
    _ghostSessionIds.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _workspaceEnabled.clear();
    _pendingPermissions.clear();
    _pendingQuestions.clear();
    _recentlyResolvedQuestions.clear();
    _recentlyResolvedPermissions.clear();
    commandsNotifier.value = const [];
    _commandsDegraded = false;
    _commandsCacheDir = null;
    _commandsCacheComplete = false;
    _suspiciousEmptyStreak = 0;
    client = null;
    _profile = null;
    _cacheStore = null;
    _agentsModelsCache.clear();
    _agentsModelsInFlight.clear();
    _agentsModelsFetchedAt.clear();
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
    commandsNotifier.dispose();
    previewVersion.dispose();
    super.dispose();
  }

  static const _agentsModelsTtl = Duration(seconds: 30);
  final _agentsModelsCache =
      <String, Future<(List<AgentInfo>, List<ModelInfo>)>>{};
  final _agentsModelsInFlight =
      <String, Future<(List<AgentInfo>, List<ModelInfo>)>>{};
  final _agentsModelsFetchedAt = <String, DateTime>{};
  int _agentsModelsEpoch = 0;

  Future<(List<AgentInfo>, List<ModelInfo>)> fetchAgentsAndModels({
    String? directory,
  }) {
    final c = client;
    if (c == null) {
      throw StateError('server not connected');
    }
    final key = directory ?? '';
    final cached = _agentsModelsCache[key];
    if (cached != null &&
        _agentsModelsFetchedAt[key] != null &&
        DateTime.now().difference(_agentsModelsFetchedAt[key]!) <
            _agentsModelsTtl) {
      return cached;
    }
    return _agentsModelsInFlight[key] ??= _startAgentsModelsFetch(
      c,
      key,
      directory,
    );
  }

  Future<(List<AgentInfo>, List<ModelInfo>)> _startAgentsModelsFetch(
    OpencodeClient c,
    String key,
    String? directory,
  ) {
    late final Future<(List<AgentInfo>, List<ModelInfo>)> fut;
    final epoch = _agentsModelsEpoch;
    fut = Future.wait([
      c.listAgents(directory: directory),
      c.listConfigProviders(directory: directory),
    ]).then((results) {
      final entry = (
        results[0] as List<AgentInfo>,
        results[1] as List<ModelInfo>,
      );
      if (identical(c, client) && epoch == _agentsModelsEpoch) {
        _agentsModelsCache[key] = Future.value(entry);
        _agentsModelsFetchedAt[key] = DateTime.now();
      }
      return entry;
    }).whenComplete(() {
      if (identical(_agentsModelsInFlight[key], fut)) {
        _agentsModelsInFlight.remove(key);
      }
    });
    return fut;
  }

  /// Manual refresh (from pull-to-refresh). Returns true on success.
  /// Never throws — all network errors are swallowed and surfaced via
  /// the return value so RefreshIndicator / onRefresh callers stay safe.
  Future<bool> refresh() async {
    if (client == null) return false;
    try {
      final ok = await refreshListAndWorkingSse(force: true);
      if (ok) {
        _agentsModelsEpoch++;
        _agentsModelsCache.clear();
        _agentsModelsFetchedAt.clear();
      }
      return ok;
    } catch (e) {
      AppLogger.I.e(_tag, 'refresh failed: $e');
      return false;
    }
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
    // CD-25/29：persistDraft 织入返回的 operation Future 链（去重 guard 之后），
    // 使 `await pause()` 拿到落盘保证。仅 flush 活动会话（唯一可能有未落盘输入者）。
    final operation = _pauseWork();
    _pauseOperation = operation;
    return operation.whenComplete(() {
      if (identical(_pauseOperation, operation)) _pauseOperation = null;
    });
  }

  Future<void> _pauseWork() async {
    final active =
        (_activeSessionId != null) ? _conversations[_activeSessionId] : null;
    if (active != null) {
      await active.persistDraft(); // CD-25：仅活动会话，1 次磁盘写
    }
    await _stopSse();
  }

  /// Called when the app returns to foreground. Decision logic:
  /// - No stream → SSE was torn down by pause → full refresh.
  /// - Has stream but last refresh >30s ago → refresh.
  /// - Has stream and recent refresh → just backfill permissions.
  Future<void> resume() async {
    if (!connected || client == null || _profile == null) return;
    _foreground = true;
    AppLogger.I.i(_tag, 'resume');

    final activePause = _pauseOperation;
    if (activePause != null) await activePause;
    if (!_foreground || !connected || client == null || _profile == null) {
      return;
    }

    // Wake the SSE client sleeping in reconnect backoff (earned under
    // background/Doze suspended-network conditions). The app is now in the
    // foreground with the network available — reconnect immediately instead
    // of waiting out the exponential sleep (up to 30s).
    _sse?.reconnectNow();

    // No stream: SSE was torn down (pause timer fired). Full refresh.
    if (_sse == null) {
      await refreshListAndWorkingSse(force: true);
      return;
    }

    // Stream present but data is stale.
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

  /// Stop the global SSE connection without clearing cached data (used by pause).
  Future<void> _stopSse({bool flushCache = true}) async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _stopHealthProbe();
    final eventSub = _sseSub;
    final stateSub = _sseStateSub;
    final client = _sse;
    _sseSub = null;
    _sseStateSub = null;
    _sse = null;
    _sseLive = false;
    _sseFailed = false;
    final stops = <Future<void>>[
      if (eventSub != null) eventSub.cancel(),
      if (stateSub != null) stateSub.cancel(),
      if (client != null) client.stop(),
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

  void _scheduleCacheSave() {
    if (_profile == null) return;
    _cacheSaveTimer?.cancel();
    _cacheSaveTimer = Timer(const Duration(seconds: 2), () => _saveCache());
  }

  Future<void> _saveCache() async {
    final cs = _cacheStore;
    if (cs == null) return;
    try {
      final j = {
        'v': 1,
        'projects': _projects.map((p) => p.toJson()).toList(),
        'sessions': _sessions.map((s) => s.toJson()).toList(),
        // Status is intentionally NOT persisted: it is time-sensitive and a
        // stale on-disk value (e.g. a session that finished hours ago) would
        // paint a false busy/retry indicator on cold start. It lives only in
        // the in-memory `_statusMap` cache, which survives a background pause
        // and is refreshed on connect/resume.
        'lastMessage': _lastMessage,
        'activity': _lastActivityByKey,
        'workspaceEnabled': _workspaceEnabled,
      };
      await cs.write('server', jsonEncode(j));
    } catch (e) {
      AppLogger.I.w(_tag, 'saveCache failed: $e');
    }
  }

  Future<void> _loadCache() async {
    final cs = _cacheStore;
    if (cs == null) return;
    try {
      final raw = await cs.read('server');
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      if (j['v'] != 1) {
        AppLogger.I.w(_tag, 'cache schema mismatch, dropping');
        await cs.remove('server');
        return;
      }
      final projects = (j['projects'] as List? ?? [])
          .map((e) => ProjectModel.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
      final sessions = (j['sessions'] as List? ?? [])
          .map((e) => SessionModel.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
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
      AppLogger.I.e(_tag, 'loadCache failed: $e');
      try {
        await cs.remove('server');
      } catch (_) {}
    }
  }
}
