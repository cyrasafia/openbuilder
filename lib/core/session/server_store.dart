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
/// global SSE stream `GET /api/event` (v2 contract; envelope `location.directory`
/// routes events client-side, session-scoped events route by `data.sessionID`).
class ServerStore extends ChangeNotifier {
  @visibleForTesting
  static Duration sseStopTimeout = const Duration(seconds: 2);

  OpencodeClient? client;
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
  @visibleForTesting
  static Duration healthProbeInterval = const Duration(seconds: 5);
  DateTime? _lastPreviewNotifyAt;
  static const _previewNotifyInterval = Duration(milliseconds: 120);
  DateTime? _lastActivityNotifyAt;
  Timer? _activityNotifyTimer;
  static const _activityTouchInterval = Duration(milliseconds: 2500);
  bool _busyProbeInFlight = false;
  ConnectionProfile? _profile;
  CacheStore? _cacheStore;

  static const kMaxRefreshInterval = Duration(seconds: 30);
  DateTime? _lastFullRefreshAt;

  String? _activeSessionId;
  bool _needsStaleMarking = false;
  String? _resumeReloadedSessionId;

  final Map<String, Permission> _pendingPermissions = {};

  final Map<String, FormInfo> _pendingForms = {};

  bool _backfillInFlight = false;

  bool _backfillDirty = false;

  final Map<String, DateTime> _recentlyResolvedForms = {};

  final Map<String, DateTime> _recentlyResolvedPermissions = {};
  static const _resolvedTtl = Duration(seconds: 60);

  List<ProjectModel> _projects = [];
  List<SessionModel> _sessions = [];
  final Map<String, SessionModel> _childSessions = {};
  static const _kMaxChildSessions = 64;
  final Map<String, SessionStatusValue> _statusMap = {};
  final Set<String> _ghostSessionIds = {};
  final Map<String, String> _lastMessage = {};
  final Map<String, int> _lastActivityByKey = {};
  final Map<String, bool> _workspaceEnabled = {};
  final Set<String> _deletingWorktrees = {};
  bool _projectsFetched = false;
  final LinkedHashMap<String, ConversationStore> _conversations =
      LinkedHashMap<String, ConversationStore>();
  static const _kMaxConversations = 20;

  final FileBrowsingStore fileBrowsing = FileBrowsingStore();

  final ValueNotifier<List<CommandInfo>> commandsNotifier =
      ValueNotifier(const []);

  final ValueNotifier<int> previewVersion = ValueNotifier(0);
  bool _commandsRefreshing = false;
  String? _commandsRefreshDir;
  bool get commandsRefreshing => _commandsRefreshing;
  String? _commandsCacheDir;
  bool _commandsCacheComplete = false;
  bool _commandsDegraded = false;
  bool get commandsDegraded => _commandsDegraded;
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
      final fetched =
          await _tryFetchCommands(c.getMergedCommands(directory: directory));
      final degraded = fetched.failed;
      final suspiciousEmpty = !fetched.failed && fetched.value.isEmpty;
      final haveGoodCache = commandsNotifier.value.isNotEmpty &&
          _commandsCacheDir == directory &&
          _commandsCacheComplete;
      final withinStreak = _suspiciousEmptyStreak < kMaxSuspiciousRetries;
      if ((degraded || (suspiciousEmpty && withinStreak)) && haveGoodCache) {
        if (suspiciousEmpty) _suspiciousEmptyStreak++;
        _commandsDegraded = true;
        AppLogger.I.w(_tag,
            'commands refresh ${suspiciousEmpty ? 'suspicious-empty' : 'degraded'} '
            '(fetched=${fetched.value.length}/${fetched.failed ? 'err' : 'ok'}); '
            'keeping cache of ${commandsNotifier.value.length} '
            '(streak $_suspiciousEmptyStreak)');
        return;
      }

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
          'commands refreshed: fetched=${fetched.value.length}'
          '${degraded ? ' (degraded, no usable cache)' : ''}'
          '${suspiciousEmpty && !trustEmpty ? ' (suspicious-empty, no cache)' : ''}');
      commandsNotifier.value = fetched.value;
    } catch (e) {
      _commandsDegraded = true;
      AppLogger.I.e(_tag, 'commands refresh failed: $e');
    } finally {
      _commandsRefreshing = false;
    }
  }

  Future<({List<CommandInfo> value, bool failed})> _tryFetchCommands(
      Future<List<CommandInfo>> future) async {
    try {
      return (value: await future, failed: false);
    } catch (_) {
      return (value: const <CommandInfo>[], failed: true);
    }
  }

  bool connected = false;

  bool get sseConnected => _sse != null && _sseLive;

  bool get sseReconnecting => _sse != null && !_sseLive;

  bool isSessionSseConnected(String sessionId) {
    if (!_sseLive) return false;
    return sessionById(sessionId) != null;
  }
  bool _sseLive = false;
  bool _sseFailed = false;

  bool bootstrapFailed = false;

  bool _connecting = false;
  bool get connecting => _connecting;

  int _connectGeneration = 0;

  @visibleForTesting
  void setConnectingForTesting(bool v) {
    _connectGeneration++;
    _connecting = v;
    notifyListeners();
  }

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

  AppLocalizations? _loc;

  set activeLoc(AppLocalizations v) {
    if (_loc?.localeName == v.localeName) return;
    _loc = v;
    _recomputePreviews();
  }

  bool _reasoningVisibleInPreview = false;

  set reasoningVisibleInPreview(bool v) {
    if (_reasoningVisibleInPreview == v) return;
    _reasoningVisibleInPreview = v;
    _recomputePreviews();
  }

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

  int lastActivityForProject(String projectID) =>
      _lastActivityByKey[projectID] ?? 0;

  int lastActivityForGlobalDir(String directory) =>
      _lastActivityByKey['global\u0000$directory'] ?? 0;

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

  void _notifyPreviewChanged() {
    final now = DateTime.now();
    if (_lastPreviewNotifyAt == null ||
        now.difference(_lastPreviewNotifyAt!) >= _previewNotifyInterval) {
      _lastPreviewNotifyAt = now;
      _previewNotifyTimer?.cancel();
      _previewNotifyTimer = null;
      _bumpPreview();
    } else {
      _previewNotifyTimer ??= Timer(_previewNotifyInterval, () {
        _lastPreviewNotifyAt = DateTime.now();
        _previewNotifyTimer = null;
        _bumpPreview();
      });
    }
  }

  void _bumpPreview() => previewVersion.value++;

  bool hasPendingPermission(String sessionId) => _pendingPermissions.values
      .any((p) => _cardHostSessionId(p.sessionID) == sessionId);

  bool hasPendingQuestion(String sessionId) => _pendingForms.values
      .any((q) => _cardHostSessionId(q.sessionID) == sessionId);

  AgentIndicatorState agentIndicatorStateOf(String sessionId) {
    final permissionCount = _pendingPermissions.values
        .where((p) => _cardHostSessionId(p.sessionID) == sessionId)
        .length;
    final formCount = _pendingForms.values
        .where((q) => _cardHostSessionId(q.sessionID) == sessionId)
        .length;
    final pendingCount = permissionCount + formCount;
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

  Future<void> removeWorktree(
    String projectWorktree, {
    required String worktreeDir,
  }) async {
    if (_deletingWorktrees.contains(worktreeDir)) return;
    final c = client;
    if (c == null) throw const KnownError(FriendlyErrorKind.notConnected);
    final project = _projectByCanonical(projectWorktree);
    if (project == null) throw const KnownError(FriendlyErrorKind.notConnected);
    _deletingWorktrees.add(worktreeDir);
    notifyListeners();
    try {
      final sessions = await c.sessionsForDirectory(worktreeDir);
      await Future.wait(
        sessions.map(
          (s) => c.deleteSession(s.id).catchError((_) {
            AppLogger.I.w(_tag, 'deleteSession ${s.id} best-effort skipped');
          }),
        ),
      );
      await c.removeWorktree(project.id, worktreeDir);
      final idx = _projects.indexWhere((p) => p.canonical == projectWorktree);
      if (idx >= 0) {
        final p = _projects[idx];
        _projects[idx] = ProjectModel(
          id: p.id,
          canonical: p.canonical,
          vcs: p.vcs,
          name: p.name,
          icon: p.icon,
          commands: p.commands,
          sandboxes: p.sandboxes
              .where((d) => d != worktreeDir)
              .toList(growable: false),
          created: p.created,
          updated: p.updated,
          active: p.active,
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
    } catch (e) {
      throw OperationException('删除工作区', cause: e);
    } finally {
      _deletingWorktrees.remove(worktreeDir);
      notifyListeners();
    }
  }

  bool isWorktreeDeleting(String worktreeDir) =>
      _deletingWorktrees.contains(worktreeDir);

  ProjectModel? _projectByCanonical(String canonical) {
    for (final p in _projects) {
      if (p.canonical == canonical) return p;
    }
    return null;
  }

  void _inferWorkspaceForNewProjects() {
    final hasWorkspaceSession = <String>{};
    for (final s in _sessions) {
      final p = projectOf(s.projectID);
      if (p == null || p.id == 'global') continue;
      if (s.directory.isNotEmpty && s.directory != p.canonical) {
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
    final project = _projectByCanonical(projectDir);
    if (project == null) {
      throw const KnownError(FriendlyErrorKind.notConnected);
    }
    WorktreeInfo? wt;
    if (reconcileFirst) {
      wt = await _recoverAmbiguousWorktree(c, project);
    }
    if (wt == null) {
      try {
        wt = await c.createWorktree(project.id);
      } catch (e) {
        final kind = friendlyErrorRaw(e);
        if (kind == FriendlyErrorKind.timeout ||
            kind == FriendlyErrorKind.connect) {
          wt = await _recoverAmbiguousWorktree(c, project);
        }
        if (wt == null) throw OperationException('创建工作区', cause: e);
      }
    }
    final worktree = wt;
    final idx = _projects.indexWhere((p) => p.canonical == projectDir);
    if (idx >= 0 && !_projects[idx].sandboxes.contains(worktree.directory)) {
      final p = _projects[idx];
      _projects[idx] = ProjectModel(
        id: p.id,
        canonical: p.canonical,
        vcs: p.vcs,
        name: p.name,
        icon: p.icon,
        commands: p.commands,
        sandboxes: [...p.sandboxes, worktree.directory],
        created: p.created,
        updated: p.updated,
        active: p.active,
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

  Future<WorktreeInfo?> _recoverAmbiguousWorktree(
    OpencodeClient c,
    ProjectModel project,
  ) async {
    try {
      final remote = await c.worktrees(project.id);
      final known = <String>{
        project.canonical,
        ...project.sandboxes,
      };
      final candidates = remote
          .map((w) => w.directory)
          .where((d) => !known.contains(d))
          .toList();
      if (candidates.length != 1) return null;
      final dir = candidates.single;
      return WorktreeInfo(directory: dir);
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

  String worktreeDisplayOf(SessionModel s) {
    if (s.projectID == 'global') return '';
    if (!_hasMultipleWorktrees(s.projectID)) return '';
    final project = projectOf(s.projectID);
    if (project != null && s.directory == project.canonical) {
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
      _sse?.reconnectNow();
    }
  }

  void ensureSseForSession(String sessionId) {
    _sse?.reconnectNow();
  }

  ConversationStore? ensureConversation(String sid) {
    final existing = _conversations[sid];
    if (existing != null) return existing;
    final c = client;
    if (c == null) return null;
    final directory =
        sessionById(sid)?.directory ?? _childSessions[sid]?.directory ?? '';
    final conv = ConversationStore(sid, c,
        directory: directory, cacheStore: _cacheStore);
    conv.onQuestionResolved = _markFormResolved;
    conv.onPermissionResolved = _markPermissionResolved;
    _conversations[sid] = conv;
    final initStatus = statusOf(sid);
    conv.setStatus(initStatus.type, retryMessage: initStatus.message);
    conv.sessionUpdated = sessionById(sid)?.updated;
    if (_ghostSessionIds.contains(sid)) conv.markWorkspaceMissing();
    for (final p in _pendingPermissions.values) {
      if (_cardHostSessionId(p.sessionID) == sid) conv.onPermission(p);
    }
    for (final q in _pendingForms.values) {
      if (_cardHostSessionId(q.sessionID) == sid) conv.onForm(q);
    }
    unawaited(conv.loadDraftOnly());
    _evictConversations();
    return conv;
  }

  void loadChildSessionMessages(String sid) {
    final conv = ensureConversation(sid);
    if (conv == null) return;
    if (conv.messages.isNotEmpty) return;
    unawaited(conv.load());
  }

  void _backfillConversationDirectory(String sid, String directory) {
    if (directory.isEmpty) return;
    _conversations[sid]?.setDirectory(directory);
  }

  void _markFormResolved(String fid) {
    _recentlyResolvedForms[fid] = DateTime.now();
    _pendingForms.remove(fid);
    AppLogger.I.i(_tag, 'markFormResolved fid=$fid → guard for ${_resolvedTtl.inSeconds}s');
  }

  void _markPermissionResolved(String pid) {
    _recentlyResolvedPermissions[pid] = DateTime.now();
    _pendingPermissions.removeWhere((_, p) => p.id == pid);
    AppLogger.I.i(_tag, 'markPermissionResolved pid=$pid → guard for ${_resolvedTtl.inSeconds}s');
  }

  void _purgeExpiredResolved() {
    final now = DateTime.now();
    _recentlyResolvedForms.removeWhere(
        (_, t) => now.difference(t) > _resolvedTtl);
    _recentlyResolvedPermissions.removeWhere(
        (_, t) => now.difference(t) > _resolvedTtl);
  }

  void _evictConversations() {
    while (_conversations.length > _kMaxConversations) {
      String? victim;
      for (final sid in _conversations.keys) {
        final st = _statusMap[sid]?.type;
        final streaming =
            st == 'busy' || st == 'retry' || sid == _activeSessionId;
        if (streaming || isChildSession(sid)) continue;
        victim = sid;
        break;
      }
      if (victim == null) break;
      _conversations.remove(victim)?.dispose();
    }
  }

  ConversationStore? conversationForRead(String sessionId) =>
      _conversations[sessionId];

  ConversationStore? conversationFor(String sessionId, {bool force = false}) {
    final existing = _conversations[sessionId];
    if (existing != null) {
      _conversations.remove(sessionId);
      _conversations[sessionId] = existing;
      existing.sessionUpdated = sessionById(sessionId)?.updated;
      if (force) {
        unawaited(existing.reconcile()
            .then((_) => _backfillPreview(sessionId, existing)));
      } else if (!existing.loaded) {
        existing.setBackfillCallback(() => _backfillPreview(sessionId, existing));
        unawaited(existing.load()
            .then((_) => _backfillPreview(sessionId, existing)));
      } else if (existing.isStale) {
        unawaited(existing.reloadIfStale()
            .then((_) => _backfillPreview(sessionId, existing)));
      }
      return existing;
    }
    final conv = ensureConversation(sessionId);
    if (conv == null) return null;
    conv.setBackfillCallback(() => _backfillPreview(sessionId, conv));
    unawaited(conv.load()
        .then((_) => _backfillPreview(sessionId, conv)));
    return conv;
  }

  Future<void> connect(ConnectionProfile profile) async {
    if (_profile != null &&
        _profile!.id == profile.id &&
        _signature(_profile!) == _signature(profile) &&
        client != null &&
        connected) {
      return;
    }
    final generation = ++_connectGeneration;
    _connecting = true;
    bootstrapFailed = false;
    notifyListeners();
    AppLogger.I.i(_tag, 'connect ${profile.hostDisplay}');
    try {
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
      _childSessions.clear();
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
        connected = false;
        notifyListeners();
        return;
      }
      unawaited(_saveCache());
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

  Set<String> _eventDirectories() {
    final dirs = <String>{};
    for (final p in _projects) {
      if (p.canonical.isNotEmpty) dirs.add(p.canonical);
      for (final d in p.sandboxes) {
        if (d.isNotEmpty) dirs.add(d);
      }
    }
    for (final s in _sessions) {
      if (s.directory.isNotEmpty) dirs.add(s.directory);
    }
    return dirs;
  }

  bool _isGatedDirectory(String directory) {
    if (directory.isEmpty) return false;
    for (final p in _projects) {
      if (p.canonical == directory) return true;
      if (p.sandboxes.contains(directory)) return true;
    }
    for (final s in _sessions) {
      if (s.directory == directory) return true;
    }
    return false;
  }

  bool _isKnownSession(String sid) =>
      sessionById(sid) != null ||
      _childSessions.containsKey(sid) ||
      _conversations.containsKey(sid);

  void _startSse() {
    final existing = _sse;
    if (existing != null) {
      existing.reconnectNow();
      return;
    }
    final c = SseClient(baseUrl: _profile!.baseUrl, headers: _sseHeaders);
    _sse = c;
    _sseSub = c.events
        .listen(_onGlobalEvent);
    _sseStateSub = c.state.listen(_onSseState);
    c.start();
  }

  String _signature(ConnectionProfile p) =>
      '${p.baseUrl}|${p.authMethod.name}|${p.username}|${p.password}';

  ConnectionStore? _connectionStore;

  set connectionStore(ConnectionStore? value) => _connectionStore = value;

  void refreshSseAuth(ConnectionProfile profile) {
    _sseHeaders
      ..clear()
      ..addAll(authHeadersFor(profile));
  }

  List<ProjectModel> _filterSandboxes(
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) {
    return projects.map((p) {
      if (p.sandboxes.isEmpty || p.canonical.isEmpty) return p;
      final real = worktreesByDir[p.canonical];
      if (real == null || real.isEmpty) return p;
      final valid = real.toSet()..add(p.canonical);
      final filtered =
          p.sandboxes.where(valid.contains).toList(growable: false);
      if (filtered.length == p.sandboxes.length) return p;
      return ProjectModel(
        id: p.id,
        canonical: p.canonical,
        vcs: p.vcs,
        name: p.name,
        icon: p.icon,
        commands: p.commands,
        sandboxes: filtered,
        created: p.created,
        updated: p.updated,
        active: p.active,
      );
    }).toList();
  }

  Future<List<ProjectModel>> _reconcileSandboxes(
    List<ProjectModel> projects, {
    Map<String, List<String>>? worktreesByDir,
  }) async {
    final c = client;
    if (c == null) return projects;
    final map = worktreesByDir ?? <String, List<String>>{};
    await Future.wait(projects.map((p) async {
      if (p.sandboxes.isEmpty || p.canonical.isEmpty) return;
      try {
        final wts = await c.worktrees(p.id);
        map[p.canonical] =
            wts.map((w) => w.directory).toList(growable: false);
      } catch (_) {}
    }));
    return _filterSandboxes(projects, map);
  }

  void _markGhostSessions(Set<String> ids) {
    for (final id in ids) {
      _statusMap[id] = const SessionStatusValue('idle');
      _ghostSessionIds.add(id);
      _conversations[id]?.markWorkspaceMissing();
    }
  }

  void _unghostRecovered(List<SessionModel> sessions) {
    if (_ghostSessionIds.isEmpty) return;
    for (final s in sessions) {
      _ghostSessionIds.remove(s.id);
    }
  }

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
      final wt = worktreesByDir[p.canonical];
      if (wt == null || wt.isEmpty) continue;
      if (old.directory == p.canonical || wt.contains(old.directory)) continue;
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
      final sessions = await _fetchAllSessions();
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, projects, worktreesByDir);
      _projects = projects;
      _projectsFetched = true;
      _sessions = _mergeFetchedSessions(sessions);
      _markGhostSessions(ghostIds);
      final active = await _fetchActiveStatuses();
      if (active != null) {
        _mergeStatus(fresh: active, sessions: sessions);
        unawaited(_probeBusyMessageTimes());
      }
      _inferWorkspaceForNewProjects();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, SessionStatusValue>?> _fetchActiveStatuses() async {
    try {
      return await client!.activeSessions();
    } catch (_) {
      return null;
    }
  }

  void _mergeStatus({
    required Map<String, SessionStatusValue> fresh,
    required List<SessionModel> sessions,
  }) {
    final merged = Map.of(fresh);
    _statusMap.forEach((id, v) {
      if (v.type == 'retry' && fresh.containsKey(id)) {
        merged[id] = v;
      }
    });
    _statusMap
      ..clear()
      ..addAll(merged);
  }

  Future<List<SessionModel>> _fetchAllSessions() async {
    final list = await client!.sessions();
    final all = <String, SessionModel>{};
    _addSessions(all, list);
    return all.values.toList();
  }

  void _addSessions(Map<String, SessionModel> out, List<SessionModel> list) {
    for (final s in list) {
      _bumpLastActivity(s);
      if (s.archived != null) continue;
      if (s.parentID != null) {
        _upsertChildSession(s);
        continue;
      }
      out[s.id] = s;
      _backfillConversationDirectory(s.id, s.directory);
    }
  }

  int _reconcileScheduleCount = 0;

  @visibleForTesting
  int get reconcileScheduleCountForTesting => _reconcileScheduleCount;

  void _scheduleReconcile() {
    _reconcileScheduleCount++;
    _reconcileTimer?.cancel();
    _reconcileTimer = Timer(const Duration(milliseconds: 800), () {
      unawaited(_reconcile());
    });
  }

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
      final sessions = await _fetchAllSessions();
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, newProjects, worktreesByDir);
      newProjects = _filterSandboxes(newProjects, worktreesByDir);
      final active = await _fetchActiveStatuses();
      _projects = newProjects;
      _sessions = _mergeFetchedSessions(sessions);
      _markGhostSessions(ghostIds);
      if (active != null) {
        _mergeStatus(fresh: active, sessions: sessions);
        unawaited(_probeBusyMessageTimes());
      }
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
      final activeId = _activeSessionId;
      if (activeId != null) {
        unawaited(refreshCommands(directory: sessionById(activeId)?.directory));
      }
    } catch (_) {
      notifyListeners();
      return false;
    }
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
            _conversations[_cardHostSessionId(perm.sessionID)]
                ?.onPermission(perm);
            AppLogger.I.i(_tag, 'backfill permission re-inject sid=${perm.sessionID} pid=${perm.id} dir=$dir');
          }
        } catch (_) {
          failedDirs.add(dir);
        }
      }
      for (final entry in prev.entries) {
        final session =
            sessionById(entry.key) ?? _childSessions[entry.key];
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
      final changed = _pendingPermissions.length != next.length ||
          !_pendingPermissions.keys.toSet().containsAll(next.keys);
      _pendingPermissions
        ..clear()
        ..addAll(next);
      if (changed) {
        notifyListeners();
      }
      await _backfillForms();
    } finally {
      _backfillInFlight = false;
      if (_backfillDirty) {
        _backfillDirty = false;
        unawaited(_backfillPermissions());
      }
    }
  }

  Future<void> _backfillForms() async {
    final c = client;
    if (c == null) return;
    _purgeExpiredResolved();
    final prev = Map.of(_pendingForms);
    final dirs = _eventDirectories();
    final failedDirs = <String>{};
    final next = <String, FormInfo>{};
    for (final dir in dirs) {
      try {
        final pending = await c.listForms(directory: dir);
        for (final f in pending) {
          if (_recentlyResolvedForms.containsKey(f.id)) {
            AppLogger.I.i(_tag, 'backfill form skipped (recently resolved) sid=${f.sessionID} fid=${f.id} dir=$dir');
            continue;
          }
          next[f.id] = f;
          _conversations[_cardHostSessionId(f.sessionID)]?.onForm(f);
          AppLogger.I.i(_tag, 'backfill form re-inject sid=${f.sessionID} fid=${f.id} dir=$dir');
        }
      } catch (_) {
        failedDirs.add(dir);
      }
    }
    for (final entry in prev.entries) {
      final session =
          sessionById(entry.value.sessionID) ?? _childSessions[entry.value.sessionID];
      final dir = session?.directory ?? '';
      if (failedDirs.contains(dir) || dir.isEmpty || !dirs.contains(dir)) {
        if (_recentlyResolvedForms.containsKey(entry.key)) continue;
        next.putIfAbsent(entry.key, () => entry.value);
      }
    }
    _mergeWindowMutations(
        next: next,
        prev: prev,
        live: _pendingForms,
        idOf: (f) => f.id,
        isResolved: _recentlyResolvedForms.containsKey);
    final changed = _pendingForms.length != next.length ||
        !_pendingForms.keys.toSet().containsAll(next.keys);
    _pendingForms
      ..clear()
      ..addAll(next);
    if (changed) {
      notifyListeners();
    }
  }

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
    if (!s.connected && s.reconnecting) {
      _sseFailed = true;
    }
    if (s.reconnecting) {
      _startHealthProbe();
    } else if (s.connected) {
      _stopHealthProbe();
    }
    if (s.reconnecting) {
      _needsStaleMarking = true;
    }
    if (!s.reconnecting && s.connected && !wasLive) {
      _scheduleReconcile();
    }
    notifyListeners();
  }

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

  @visibleForTesting
  void onSseStateForTesting(SseState s) => _onSseState(s);

  @visibleForTesting
  void onEventForTesting(OpencodeEvent ev) => _onEvent(ev);

  @visibleForTesting
  void onGlobalEventForTesting(String directory, OpencodeEvent ev) =>
      _onGlobalEvent(GlobalOpencodeEvent(directory: directory, event: ev));

  @visibleForTesting
  bool isGatedDirectoryForTesting(String directory) =>
      _isGatedDirectory(directory);

  @visibleForTesting
  void addSessionsForTesting(Map<String, SessionModel> out, List<SessionModel> list) =>
      _addSessions(out, list);

  @visibleForTesting
  Future<void> loadCacheForTesting(ConnectionProfile profile) async {
    _profile = profile;
    _cacheStore = FileCacheStore(profile.id);
    await _loadCache();
  }

  @visibleForTesting
  void upsertSessionForTesting(SessionModel s) => _upsertSession(s);

  @visibleForTesting
  List<SessionModel> mergeFetchedSessionsForTesting(List<SessionModel> fetched) =>
      _mergeFetchedSessions(fetched);

  @visibleForTesting
  Future<void> probeBusyMessageTimesForTesting() => _probeBusyMessageTimes();

  @visibleForTesting
  void setProjectsForTesting(List<ProjectModel> projects) =>
      _projects = projects;

  @visibleForTesting
  void clearSessionsForTesting() => _sessions = [];

  @visibleForTesting
  Future<List<ProjectModel>> reconcileSandboxesForTesting(
          List<ProjectModel> projects) =>
      _reconcileSandboxes(projects);

  @visibleForTesting
  List<ProjectModel> filterSandboxesForTesting(
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) =>
      _filterSandboxes(projects, worktreesByDir);

  @visibleForTesting
  Set<String> detectGhostSessionIdsForTesting(
    List<SessionModel> oldSessions,
    List<SessionModel> newSessions,
    List<ProjectModel> projects,
    Map<String, List<String>> worktreesByDir,
  ) =>
      _detectGhostSessionIds(oldSessions, newSessions, projects, worktreesByDir);

  @visibleForTesting
  void markGhostSessionsForTesting(Set<String> ids) => _markGhostSessions(ids);

  @visibleForTesting
  void unghostRecoveredForTesting(List<SessionModel> sessions) =>
      _unghostRecovered(sessions);

  @visibleForTesting
  void mergeStatusForTesting({
    required Map<String, SessionStatusValue> fresh,
    required List<SessionModel> sessions,
    bool fetched = true,
  }) {
    if (!fetched) return;
    _mergeStatus(fresh: fresh, sessions: sessions);
  }

  @visibleForTesting
  Future<void> backfillQuestionsForTesting() => _backfillForms();

  @visibleForTesting
  Future<void> backfillPermissionsForTesting() => _backfillPermissions();

  @visibleForTesting
  void expireRecentlyResolvedForTesting() {
    _recentlyResolvedForms.clear();
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

  void _onGlobalEvent(GlobalOpencodeEvent gev) {
    final ev = gev.event;
    final directory = gev.directory;
    final sid = ev.properties['sessionID']?.toString();
    if (directory != 'global' && !_isGatedDirectory(directory)) {
      return;
    }
    if (directory == 'global' &&
        sid != null &&
        ev.type != 'server.connected' &&
        !_isKnownSession(sid)) {
      return;
    }
    _onEvent(ev);
  }

  void _onEvent(OpencodeEvent ev) {
    switch (ev.type) {
      case 'server.connected':
        AppLogger.I.i(_tag, 'server.connected');
        _scheduleReconcile();
        return;
      case 'session.created':
        final d = ev.properties;
        final sid = d['sessionID']?.toString();
        if (sid == null) break;
        final now = ev.created ?? DateTime.now().millisecondsSinceEpoch;
        _upsertSession(SessionModel(
          id: sid,
          projectID: d['projectID']?.toString() ?? '',
          directory: (d['location'] is Map)
              ? (d['location'] as Map)['directory']?.toString() ?? ''
              : '',
          title: d['title']?.toString() ?? 'Untitled',
          created: now,
          updated: now,
          parentID: d['parentID']?.toString(),
          agent: d['agent']?.toString(),
          model: d['model'] is Map
              ? ModelRef.fromJson((d['model'] as Map).cast<String, dynamic>())
              : null,
        ));
        break;
      case 'session.renamed':
        final sid = ev.properties['sessionID']?.toString();
        final title = ev.properties['title']?.toString();
        if (sid != null && title != null && title.isNotEmpty) {
          final s = sessionById(sid);
          if (s != null) {
            _upsertSession(s.copyWith(title: title));
          }
        }
        break;
      case 'session.deleted':
        final sid = ev.properties['sessionID']?.toString();
        if (sid != null) {
          _removeSession(sid);
          fileBrowsing.removeSessionData(sid);
        }
        break;
      case 'session.moved':
        _scheduleReconcile();
        break;
      case 'session.agent.selected':
      case 'session.model.selected':
        final sid = ev.properties['sessionID']?.toString();
        if (sid != null) unawaited(_refreshSessionMeta(sid));
        break;
      case 'session.metadata.updated':
      case 'session.permissions':
      case 'session.viewed':
      case 'session.forked':
      case 'session.instructions.updated':
        break;
      case 'session.execution.started':
        final sid1 = ev.properties['sessionID']?.toString();
        if (sid1 != null) {
          _touchActivity(sid1, ev.created);
          if (_statusMap[sid1]?.type == 'busy') return;
          _statusMap[sid1] = const SessionStatusValue('busy');
          _conversations[sid1]?.setStatus('busy');
          _scheduleCacheSave();
        }
        break;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        final sid2 = ev.properties['sessionID']?.toString();
        if (sid2 != null) {
          _touchActivity(sid2, ev.created);
          final wasBusy = _statusMap[sid2]?.type == 'busy' ||
              _statusMap[sid2]?.type == 'retry';
          final wasRetry = _statusMap[sid2]?.type == 'retry';
          _statusMap[sid2] = const SessionStatusValue('idle');
          _scheduleCacheSave();
          if (wasRetry) {
            _conversations[sid2]?.setStatus('idle');
          }
          if (wasBusy) {
            AppLogger.I.i(_tag, 'execution settled ${ev.type} $sid2');
            if (!isChildSession(sid2)) {
              unawaited(NotificationService.notifyRunComplete(
                      sessionById(sid2)?.title)
                  .catchError((_) {}));
            }
            final conv = _conversations[sid2];
            if (conv != null && conv.isStale) {
              unawaited(conv.reload());
            }
          }
        }
        break;
      case 'session.retry.scheduled':
        final sid3 = ev.properties['sessionID']?.toString();
        if (sid3 != null) {
          final error = ev.properties['error'];
          final message = error is Map ? error['message']?.toString() : null;
          if (_statusMap[sid3]?.type != 'retry') {
            _statusMap[sid3] = SessionStatusValue('retry', message: message);
            _scheduleCacheSave();
          }
          _conversations[sid3]?.onRetryScheduled(
              ev.properties['assistantMessageID']?.toString(),
              _i(ev.properties['attempt']),
              error is Map
                  ? error.cast<String, dynamic>()
                  : {'message': error?.toString() ?? ''});
        }
        break;
      case 'session.usage.updated':
      case 'session.usage.recorded':
        final sid4 = ev.properties['sessionID']?.toString();
        if (sid4 != null) {
          final s = sessionById(sid4);
          if (s != null) {
            _upsertSession(s.copyWith(cost: _d(ev.properties['cost'])));
            _touchActivity(sid4, ev.created);
          }
        }
        break;
      case 'session.step.started':
        final sid5 = ev.properties['sessionID']?.toString();
        final mid5 = ev.properties['assistantMessageID']?.toString();
        if (sid5 != null && mid5 != null) {
          final conv = ensureConversation(sid5);
          conv?.onStepStarted(
            mid5,
            agent: ev.properties['agent']?.toString(),
            model: ev.properties['model'] is Map
                ? ModelRef.fromJson(
                    (ev.properties['model'] as Map).cast<String, dynamic>())
                : null,
          );
          if (conv != null) _scheduleCacheSave();
        }
        if (sid5 != null) _touchActivity(sid5, ev.created);
        return;
      case 'session.text.delta':
      case 'session.reasoning.delta':
        final sid6 = ev.properties['sessionID']?.toString();
        final mid6 = ev.properties['assistantMessageID']?.toString();
        final ordinal6 = _i(ev.properties['ordinal']);
        final delta6 = ev.properties['delta']?.toString();
        if (sid6 != null && mid6 != null) {
          final conv = ensureConversation(sid6);
          if (conv != null) {
            if (ev.type == 'session.text.delta') {
              conv.onTextDelta(mid6, ordinal6, delta6 ?? '');
            } else {
              conv.onReasoningDelta(mid6, ordinal6, delta6 ?? '');
            }
            _updateStreamingPreview(sid6, conv);
          }
        }
        if (sid6 != null) _touchActivity(sid6, ev.created, throttled: true);
        return;
      case 'session.text.started':
      case 'session.text.ended':
      case 'session.reasoning.started':
      case 'session.reasoning.ended':
        final sid7 = ev.properties['sessionID']?.toString();
        final mid7 = ev.properties['assistantMessageID']?.toString();
        final ordinal7 = _i(ev.properties['ordinal']);
        final text7 = ev.properties['text']?.toString();
        if (sid7 != null && mid7 != null) {
          final conv = ensureConversation(sid7);
          if (conv != null) {
            switch (ev.type) {
              case 'session.text.started':
                conv.onTextStarted(mid7, ordinal7);
              case 'session.text.ended':
                conv.onTextEnded(mid7, ordinal7, text7 ?? '');
              case 'session.reasoning.started':
                conv.onReasoningStarted(mid7, ordinal7);
              case 'session.reasoning.ended':
                conv.onReasoningEnded(mid7, ordinal7, text7 ?? '');
            }
            _updateStreamingPreview(sid7, conv);
          }
        }
        if (sid7 != null) _touchActivity(sid7, ev.created);
        return;
      case 'session.tool.input.started':
      case 'session.tool.input.delta':
      case 'session.tool.input.ended':
      case 'session.tool.called':
      case 'session.tool.progress':
      case 'session.tool.success':
      case 'session.tool.failed':
        _onToolEvent(ev);
        return;
      case 'session.step.streamed':
        final sidS = ev.properties['sessionID']?.toString();
        if (sidS != null) _touchActivity(sidS, ev.created);
        return;
      case 'session.step.ended':
        final sid8 = ev.properties['sessionID']?.toString();
        final mid8 = ev.properties['assistantMessageID']?.toString();
        if (sid8 != null && mid8 != null) {
          final conv = ensureConversation(sid8);
          conv?.onStepEnded(
            mid8,
            finish: ev.properties['finish']?.toString(),
            rawFinish: ev.properties['rawFinish']?.toString(),
            cost: _d(ev.properties['cost']),
            tokens: ev.properties['tokens'] is Map
                ? Tokens.fromJson(
                    (ev.properties['tokens'] as Map).cast<String, dynamic>())
                : null,
          );
        }
        if (sid8 != null) _touchActivity(sid8, ev.created);
        return;
      case 'session.step.failed':
        final sid9 = ev.properties['sessionID']?.toString();
        final mid9 = ev.properties['assistantMessageID']?.toString();
        final err9 = ev.properties['error'];
        if (sid9 != null && mid9 != null) {
          final conv = ensureConversation(sid9);
          conv?.onStepFailed(
            mid9,
            err9 is Map
                ? err9.cast<String, dynamic>()
                : {'message': err9?.toString() ?? ''},
            finish: ev.properties['finish']?.toString(),
          );
        }
        if (sid9 != null) _touchActivity(sid9, ev.created);
        return;
      case 'session.message.content.updated':
        final sidA = ev.properties['sessionID']?.toString();
        final midA = ev.properties['messageID']?.toString();
        if (sidA != null && midA != null) {
          final conv = ensureConversation(sidA);
          if (conv != null) {
            conv.onMessageContentUpdated(midA, _parseContent(ev.properties['content']));
            _updateStreamingPreview(sidA, conv);
          }
        }
        if (sidA != null) _touchActivity(sidA, ev.created);
        return;
      case 'session.inbox.enqueued':
        final sidB = ev.properties['sessionID']?.toString();
        final inboxB = ev.properties['inboxID']?.toString();
        final itemB = ev.properties['item'];
        if (sidB != null && inboxB != null && itemB is Map) {
          final conv = ensureConversation(sidB);
          conv?.onInboxEnqueued(inboxB, itemB.cast<String, dynamic>(),
              created: ev.created);
          if (conv != null) {
            _lastMessage[sidB] = conv.lastMessagePreview(
                    hideReasoning: !_reasoningVisibleInPreview, loc: _loc) ??
                _lastMessage[sidB] ??
                '';
            _notifyPreviewChanged();
            _scheduleCacheSave();
          }
          _touchActivity(sidB, ev.created);
        }
        return;
      case 'session.inbox.delivered':
        final sidDelivered = ev.properties['sessionID']?.toString();
        if (sidDelivered != null) {
          _touchActivity(sidDelivered, ev.created);
        }
        return;
      case 'session.inbox.cancelled':
      case 'session.inbox.delivery.changed':
        return;
      case 'session.compaction.started':
      case 'session.compaction.delta':
      case 'session.compaction.ended':
      case 'session.compaction.failed':
      case 'session.compacted':
      case 'session.shell.started':
      case 'session.shell.ended':
      case 'session.synthetic':
      case 'session.skill.activated':
        return;
      case 'session.revert.staged':
      case 'session.revert.cleared':
      case 'session.revert.committed':
        final sidC = ev.properties['sessionID']?.toString();
        if (sidC != null) {
          final conv = _conversations[sidC];
          if (conv != null) {
            unawaited(conv.reload());
          }
        }
        break;
      case 'form.created':
        final formRaw = ev.properties['form'];
        if (formRaw is Map) {
          final f = FormInfo.fromJson(formRaw.cast<String, dynamic>());
          _pendingForms[f.id] = f;
          final host = _cardHostSessionId(f.sessionID);
          _conversations[host]?.onForm(f);
          AppLogger.I.i(_tag,
              'SSE form.created sid=${f.sessionID} fid=${f.id} host=$host');
          unawaited(NotificationService.notifyQuestion(
                  sessionById(host)?.title, f.title)
              .catchError((_) {}));
        }
        break;
      case 'form.replied':
      case 'form.cancelled':
        final fid = ev.properties['id']?.toString();
        final sidD = ev.properties['sessionID']?.toString();
        AppLogger.I.i(_tag, 'SSE ${ev.type} sid=$sidD fid=$fid');
        if (fid != null) {
          _markFormResolved(fid);
        }
        if (sidD != null && fid != null) {
          _conversations[_cardHostSessionId(sidD)]?.onFormReplied(fid);
        }
        break;
      case 'permission.asked':
        final p = Permission.fromJson(ev.properties);
        _pendingPermissions[p.sessionID] = p;
        final host = _cardHostSessionId(p.sessionID);
        _conversations[host]?.onPermission(p);
        AppLogger.I.i(_tag,
            'SSE permission.asked sid=${p.sessionID} pid=${p.id} host=$host');
        unawaited(NotificationService.notifyPermission(
                sessionById(host)?.title, p)
            .catchError((_) {}));
        break;
      case 'permission.replied':
        final sidE = ev.properties['sessionID']?.toString();
        final pid = ev.properties['requestID']?.toString();
        AppLogger.I.i(_tag, 'SSE permission.replied sid=$sidE pid=$pid');
        if (pid != null) {
          _markPermissionResolved(pid);
        }
        if (sidE != null && pid != null) {
          _conversations[_cardHostSessionId(sidE)]?.onPermissionReplied(pid);
        }
        break;
      case 'project.updated':
        final pj = ev.properties;
        if (pj['id'] != null) {
          final updated = ProjectModel.fromJson(pj.cast<String, dynamic>());
          final idx = _projects.indexWhere((x) => x.id == updated.id);
          if (idx >= 0) {
            _projects[idx] = updated;
          } else {
            _projects.add(updated);
          }
          _scheduleCacheSave();
        }
        break;
      case 'worktree.resolved':
      case 'worktree.updated':
      case 'worktree.ready':
      case 'worktree.failed':
        _scheduleReconcile();
        break;
      case 'command.updated':
      case 'agent.updated':
      case 'model.updated':
      case 'provider.updated':
      case 'skill.updated':
      case 'plugin.updated':
      case 'reference.updated':
      case 'integration.updated':
      case 'mcp.status.changed':
      case 'mcp.resources.changed':
      case 'websearch.updated':
      case 'catalog.updated':
        final activeId = _activeSessionId;
        if (activeId != null) {
          unawaited(refreshCommands(directory: sessionById(activeId)?.directory));
        }
        break;
      default:
        return;
    }
    PerfProbe.I.markEvent('sse-notify ${ev.type}');
    notifyListeners();
  }

  void _onToolEvent(OpencodeEvent ev) {
    final sid = ev.properties['sessionID']?.toString();
    final mid = ev.properties['assistantMessageID']?.toString();
    final callId = ev.properties['id']?.toString();
    if (sid == null || mid == null || callId == null) return;
    final conv = ensureConversation(sid);
    if (conv == null) return;
    switch (ev.type) {
      case 'session.tool.input.started':
        conv.onToolInputStarted(mid, callId, ev.properties['name']?.toString() ?? '');
      case 'session.tool.input.delta':
        conv.onToolInputDelta(mid, callId, ev.properties['delta']?.toString() ?? '');
      case 'session.tool.input.ended':
        conv.onToolInputEnded(mid, callId, ev.properties['text']?.toString() ?? '');
      case 'session.tool.called':
        final input = ev.properties['input'];
        conv.onToolCalled(
          mid,
          callId,
          input is Map ? input.cast<String, dynamic>() : null,
          ev.properties['executed'] == true,
        );
      case 'session.tool.progress':
        final meta = ev.properties['metadata'];
        conv.onToolProgress(
            mid, callId, meta is Map ? meta.cast<String, dynamic>() : null);
      case 'session.tool.success':
        conv.onToolSuccess(mid, callId, _parseToolContent(ev.properties['content']));
      case 'session.tool.failed':
        final err = ev.properties['error'];
        conv.onToolFailed(
          mid,
          callId,
          err is Map ? err.cast<String, dynamic>() : const {},
          content: _parseToolContent(ev.properties['content']),
        );
    }
    _updateStreamingPreview(sid, conv);
  }

  void _updateStreamingPreview(String sid, ConversationStore conv) {
    final pv = conv.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
    if (pv != null) {
      _lastMessage[sid] = pv;
      _notifyPreviewChanged();
    }
  }

  List<AssistantContent> _parseContent(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => AssistantContent.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  List<ToolContentItem> _parseToolContent(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => ToolContentItem.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  Future<void> _refreshSessionMeta(String sid) async {
    final c = client;
    if (c == null) return;
    try {
      final s = await c.sessionMeta(sid);
      _upsertSession(s);
    } catch (_) {}
  }

  Future<void> _backfillPreview(String sid, ConversationStore conv) async {
    final preview = conv.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
    if (preview != null) {
      _lastMessage[sid] = preview;
      _bumpPreview();
    }
  }

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

  SessionModel _withEffectiveActivity(SessionModel s, SessionModel? local) {
    var effective = s.updated;
    final idle = s.idle;
    if (idle != null && idle > effective) effective = idle;
    if (local != null && local.updated > effective) effective = local.updated;
    return effective == s.updated ? s : s.copyWith(updated: effective);
  }

  List<SessionModel> _mergeFetchedSessions(List<SessionModel> fetched) {
    final oldById = {for (final s in _sessions) s.id: s};
    return [
      for (final s in fetched) _withEffectiveActivity(s, oldById[s.id]),
    ];
  }

  void _touchActivity(String sid, int? at, {bool throttled = false}) {
    if (at == null) return;
    final s = sessionById(sid);
    if (s == null || at <= s.updated) return;
    if (throttled &&
        at - s.updated < _activityTouchInterval.inMilliseconds) {
      return;
    }
    _upsertSession(s.copyWith(updated: at));
    _notifyActivityThrottled();
  }

  void _notifyActivityThrottled() {
    final now = DateTime.now();
    if (_lastActivityNotifyAt == null ||
        now.difference(_lastActivityNotifyAt!) >= _activityTouchInterval) {
      _lastActivityNotifyAt = now;
      _activityNotifyTimer?.cancel();
      _activityNotifyTimer = null;
      notifyListeners();
    } else {
      _activityNotifyTimer ??= Timer(_activityTouchInterval, () {
        _lastActivityNotifyAt = DateTime.now();
        _activityNotifyTimer = null;
        notifyListeners();
      });
    }
  }

  Future<void> _probeBusyMessageTimes() async {
    final c = client;
    if (c == null || _busyProbeInFlight) return;
    final sids = _statusMap.entries
        .where((e) => e.value.type == 'busy' || e.value.type == 'retry')
        .map((e) => e.key)
        .where((sid) => sessionById(sid) != null)
        .toList();
    if (sids.isEmpty) return;
    _busyProbeInFlight = true;
    var touched = false;
    try {
      for (final sid in sids) {
        try {
          final at = await c.latestMessageAt(sid);
          final s = sessionById(sid);
          if (at != null && s != null && at > s.updated) {
            _upsertSession(s.copyWith(updated: at));
            touched = true;
          }
        } catch (_) {}
      }
    } finally {
      _busyProbeInFlight = false;
    }
    if (touched) _notifyActivityThrottled();
  }

  void _upsertSession(SessionModel raw) {
    final idx = _sessions.indexWhere((x) => x.id == raw.id);
    final s = _withEffectiveActivity(
        raw, idx == -1 ? null : _sessions[idx]);
    _bumpLastActivity(s);
    if (s.parentID != null) {
      _sessions.removeWhere((x) => x.id == s.id);
      if (s.archived != null) {
        final host = _cardHostSessionId(s.id);
        _childSessions.remove(s.id);
        _dropChildCards(s.id, host);
      } else {
        _upsertChildSession(s);
      }
      _scheduleCacheSave();
      return;
    }
    if (s.archived != null) {
      _sessions.removeWhere((x) => x.id == s.id);
      _childSessions.remove(s.id);
      _scheduleCacheSave();
      return;
    }
    if (idx == -1) {
      _sessions.add(s);
    } else {
      _sessions[idx] = s;
    }
    _scheduleCacheSave();
    _backfillConversationDirectory(s.id, s.directory);
  }

  void _upsertChildSession(SessionModel s) {
    final newlyRegistered = !_childSessions.containsKey(s.id);
    _childSessions.remove(s.id);
    _childSessions[s.id] = s;
    while (_childSessions.length > _kMaxChildSessions) {
      _childSessions.remove(_childSessions.keys.first);
    }
    _backfillConversationDirectory(s.id, s.directory);
    if (newlyRegistered) _adoptChildCards(s);
  }

  void _dropChildCards(String childId, String parentId) {
    final parent = _conversations[parentId];
    final pids = _pendingPermissions.values
        .where((p) => p.sessionID == childId)
        .map((p) => p.id)
        .toList();
    for (final pid in pids) {
      _pendingPermissions.removeWhere((_, p) => p.id == pid);
      parent?.onPermissionReplied(pid);
    }
    final fids = _pendingForms.values
        .where((f) => f.sessionID == childId)
        .map((f) => f.id)
        .toList();
    for (final fid in fids) {
      _pendingForms.remove(fid);
      parent?.onFormReplied(fid);
    }
  }

  void _adoptChildCards(SessionModel child) {
    final hostSid = _cardHostSessionId(child.id);
    final host = _conversations[hostSid];
    Permission? perm;
    for (final p in _pendingPermissions.values) {
      if (p.sessionID != child.id) continue;
      host?.onPermission(p);
      _conversations[child.id]?.onPermissionReplied(p.id);
      perm = p;
    }
    FormInfo? form;
    for (final entry in _pendingForms.values) {
      if (entry.sessionID != child.id) continue;
      host?.onForm(entry);
      _conversations[child.id]?.onFormReplied(entry.id);
      form = entry;
    }
    if (perm != null) {
      unawaited(NotificationService.notifyPermission(
              sessionById(hostSid)?.title, perm)
          .catchError((_) {}));
    }
    if (form != null) {
      unawaited(NotificationService.notifyQuestion(
              sessionById(hostSid)?.title, form.title)
          .catchError((_) {}));
    }
  }

  SessionModel? findChildSession(String parentSessionID,
      {String? description}) {
    final candidates = _childSessions.values
        .where((s) => s.parentID == parentSessionID)
        .toList();
    if (candidates.isEmpty) return null;
    if (description != null && description.isNotEmpty) {
      final matched = candidates
          .where((s) => s.title.startsWith(description))
          .toList();
      if (matched.isNotEmpty) {
        matched.sort((a, b) => b.created.compareTo(a.created));
        return matched.first;
      }
    }
    candidates.sort((a, b) => b.created.compareTo(a.created));
    return candidates.first;
  }

  bool isChildSession(String sessionId) =>
      _childSessions.containsKey(sessionId);

  String _cardHostSessionId(String sessionId) {
    var sid = sessionId;
    for (var depth = 0; depth < _kMaxChildSessions; depth++) {
      final child = _childSessions[sid];
      if (child == null) break;
      sid = child.parentID!;
    }
    return sid;
  }

  void _removeSession(String id) {
    final childHost =
        _childSessions.containsKey(id) ? _cardHostSessionId(id) : null;
    _sessions.removeWhere((s) => s.id == id);
    _childSessions.remove(id);
    if (childHost != null) _dropChildCards(id, childHost);
    _conversations.remove(id);
    _lastMessage.remove(id);
    _statusMap.remove(id);
    _ghostSessionIds.remove(id);
    final cs = _cacheStore;
    if (cs != null) unawaited(cs.remove('conv/$id'));
    _scheduleCacheSave();
  }

  Future<void> _teardown({bool flushCache = true}) async {
    await _stopSse(flushCache: flushCache);
    if (flushCache) {
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
    _childSessions.clear();
    _statusMap.clear();
    _ghostSessionIds.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _workspaceEnabled.clear();
    _pendingPermissions.clear();
    _pendingForms.clear();
    _recentlyResolvedForms.clear();
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
    _activityNotifyTimer?.cancel();
    _activityNotifyTimer = null;
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
      c.listModels(directory: directory),
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
      await active.persistDraft();
    }
    await _stopSse();
  }

  Future<void> resume() async {
    if (!connected || client == null || _profile == null) return;
    _foreground = true;
    AppLogger.I.i(_tag, 'resume');

    final activePause = _pauseOperation;
    if (activePause != null) await activePause;
    if (!_foreground || !connected || client == null || _profile == null) {
      return;
    }

    _sse?.reconnectNow();

    if (_sse == null) {
      await refreshListAndWorkingSse(force: true);
      return;
    }

    final stale = _lastFullRefreshAt == null ||
        DateTime.now().difference(_lastFullRefreshAt!) > kMaxRefreshInterval;
    if (stale) {
      await refreshListAndWorkingSse(force: false);
      return;
    }

    unawaited(_backfillPermissions());
    notifyListeners();
  }

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
      final actRaw = j['activity'] as Map? ?? {};
      for (final entry in actRaw.entries) {
        final v = entry.value;
        final n = v is int ? v : (v is num ? v.toInt() : null);
        if (n == null) continue;
        final key = entry.key.toString();
        final cur = _lastActivityByKey[key] ?? 0;
        if (n > cur) _lastActivityByKey[key] = n;
      }
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

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}
