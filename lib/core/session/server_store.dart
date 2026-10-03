import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

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
  final Map<String, int> _contentWatermarks = {};
  final Set<String> _staleSessionIds = {};
  final Set<String> _livePreviewSids = {};
  int _sseEpoch = 0;
  int _lastDiffEpoch = -1;
  static const _kProbeStaleMargin = Duration(seconds: 5);

  bool isSessionStale(String sid) => _staleSessionIds.contains(sid);
  bool hasLivePreview(String sid) => _livePreviewSids.contains(sid);

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
  // childrenByParent 索引（design-subagent-background）：`sessionActivity` 与
  // 家族遍历（sessionActivity / childSessionsOf）据此避免每次线性扫描 `_childSessions`。
  final Map<String, List<String>> _childrenByParent = {};
  static const _kMaxChildSessions = 64;
  final Map<String, SessionStatusValue> _statusMap = {};
  final Set<String> _ghostSessionIds = {};
  final Map<String, String> _lastMessage = {};
  final Map<String, int> _lastActivityByKey = {};
  final Map<String, bool> _workspaceEnabled = {};
  final Map<String, List<String>> _worktreeDirs = {};
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

  /// 家族（family）聚合状态：自身 + 全部后代子会话。
  /// 子会话进行中时父会话据此展示为进行中；`retry` 优先于 `busy`。
  /// 仅在需要「家族进行中」语义的展示口径使用（design-subagent-background）。
  SessionStatusValue sessionActivity(String id) {
    var retry = false;
    var busy = false;
    final visited = <String>{};
    final stack = <String>[id];
    while (stack.isNotEmpty) {
      final sid = stack.removeLast();
      if (!visited.add(sid)) continue;
      final type = _statusMap[sid]?.type;
      if (type == 'retry') {
        retry = true;
      } else if (type == 'busy') {
        busy = true;
      }
      final children = _childrenByParent[sid];
      if (children != null) stack.addAll(children);
    }
    if (retry) return const SessionStatusValue('retry');
    if (busy) return const SessionStatusValue('busy');
    return const SessionStatusValue('idle');
  }

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
    return switch (sessionActivity(sessionId).type) {
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

  List<String> worktreeDirsOf(String projectId) =>
      _worktreeDirs[projectId] ?? const [];

  static List<String> _oldestFirstDirs(List<WorktreeInfo> wts) =>
      [for (final w in wts.reversed) w.directory];

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
      final updated = await activeClient.updateProject(
        projectId,
        name: name,
        updateIcon: updateIcon,
        iconUrl: iconUrl,
        iconOverride: iconOverride,
        iconColor: iconColor,
      );
      await _reconcileWorktrees([updated]);
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

  /// 删除 worktree + 定向本地清理；返回被保留的分支名（含未合并提交，
  /// 调用方提示用户），null = 无保留或不在管理范围。
  Future<String?> removeWorktree(
    String projectWorktree, {
    required String worktreeDir,
  }) async {
    if (_deletingWorktrees.contains(worktreeDir)) return null;
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
      final dirs = _worktreeDirs[project.id];
      if (dirs != null && dirs.contains(worktreeDir)) {
        _worktreeDirs[project.id] =
            dirs.where((d) => d != worktreeDir).toList(growable: false);
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
      // 分支清理（design-worktree-branch-sync §2.3）：v2 DELETE 不清分支。
      // 必须在 worktree DELETE 之后（cleanup 在项目 canonical 下操作）。
      // 已并入其他 ref → -D；未并入 → 保留 + 返回分支名（零静默丢失）。
      return await _cleanupWorktreeBranch(c, project, worktreeDir);
    } catch (e) {
      throw OperationException('删除工作区', cause: e);
    } finally {
      _deletingWorktrees.remove(worktreeDir);
      notifyListeners();
    }
  }

  bool isWorktreeDeleting(String worktreeDir) =>
      _deletingWorktrees.contains(worktreeDir);

  Future<void> reconcileProjectWorktrees(String projectId) async {
    final c = client;
    if (c == null) return;
    final project = projectOf(projectId);
    if (project == null || project.canonical.isEmpty) return;
    try {
      final wts = await c
          .worktrees(projectId)
          .timeout(const Duration(seconds: 3));
      final dirs = _oldestFirstDirs(wts);
      if (dirs.isEmpty) return;
      if (listEquals(_worktreeDirs[projectId], dirs)) return;
      _worktreeDirs[projectId] = dirs;
      _scheduleCacheSave();
      notifyListeners();
    } catch (_) {}
  }

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

  Future<SessionModel> createSession(
    String directory, {
    String? agent,
    ModelRef? model,
  }) async {
    final activeClient = client;
    if (activeClient == null) throw const KnownError(FriendlyErrorKind.notConnected);
    try {
      final session = await activeClient.createSession(
        directory,
        agent: agent,
        model: model,
      );
      _upsertSession(session);
      notifyListeners();
      return session;
    } catch (e) {
      throw OperationException('创建会话', cause: e);
    }
  }

  Future<void> archiveSession(String sessionId) async {
    final activeClient = client;
    if (activeClient == null) throw const KnownError(FriendlyErrorKind.notConnected);
    try {
      final meta = await activeClient.archiveSession(sessionId);
      _applyMetadataSnapshot(sessionId, meta);
      notifyListeners();
    } catch (e) {
      throw OperationException('归档会话', cause: e);
    }
  }

  Future<SessionModel> createSessionInNewWorktree(
    String projectDir, {
    bool reconcileFirst = false,
    String? agent,
    ModelRef? model,
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
    final dirs = [...worktreeDirsOf(project.id)];
    if (!dirs.contains(worktree.directory)) {
      dirs.add(worktree.directory);
      _worktreeDirs[project.id] = dirs;
      _scheduleCacheSave();
      notifyListeners();
    }
    // 分支挂载不阻塞会话创建（design-worktree-branch-sync §2.2：挂载延迟
    // 不得推迟创建流程返回）；失败降级 detached + 日志，不回滚创建。
    unawaited(_mountWorktreeBranch(c, worktree.directory));
    final SessionModel session;
    try {
      session = await c.createSession(
        worktree.directory,
        agent: agent,
        model: model,
      );
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
        ...worktreeDirsOf(project.id),
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

  /// 目录末段 = worktree 名。仅接受 server slug 字符集（[a-z0-9-]）：外部
  /// `git worktree add` 的目录名可含空格/元字符——未加引号拼进 shell 命令
  /// 有多 token 误删（branch -D 多参逐个删）与命令替换风险，且非本端创建
  /// 的 worktree 不属分支管理范围——不匹配返回 null，挂载/清理均跳过。
  String? _worktreeBranchBase(String directory) {
    final segs =
        directory.split('/').where((s) => s.isNotEmpty).toList(growable: false);
    if (segs.isEmpty) return null;
    final base = segs.last;
    return RegExp(r'^[a-z0-9][a-z0-9-]*$').hasMatch(base) ? base : null;
  }

  /// 挂载 `opencode/{worktree-name}` 分支（design-worktree-branch-sync §2.2）：
  /// `git switch -c` 单命令（跨 shell 可移植），exit 0 即成。失败先以
  /// show-ref 判撞名（历史残留同名分支）→ 换 `<name>-<rand>` 后缀重试 ≤2；
  /// 非撞名或 shell 通道异常（旧 v2 无 /api/shell/网络）→ 放弃，保持
  /// detached（server 默认态，日志留痕）——创建本身已成功，不回滚不报错。
  Future<void> _mountWorktreeBranch(OpencodeClient c, String directory) async {
    final base = _worktreeBranchBase(directory);
    if (base == null) return;
    final candidates = <String>['opencode/$base'];
    for (var i = 0; i < 2; i++) {
      final rand = Random().nextInt(1 << 24).toRadixString(36).padLeft(4, '0');
      candidates.add('opencode/$base-${rand.substring(rand.length - 4)}');
    }
    for (final branch in candidates) {
      try {
        // 本地 server 的 git switch 是毫秒级——5s 超时已远超正常耗时
        final created = await c.runShell('git switch -c $branch',
            cwd: directory, timeoutMs: 5000);
        if (created.exit == 0) return;
        // 撞名才重试：分支已存在；其他 git 失败重试无意义
        final probe = await c.runShell(
            'git show-ref --verify --quiet refs/heads/$branch',
            cwd: directory,
            timeoutMs: 5000);
        if (probe.exit != 0) break;
      } catch (_) {
        break; // shell 通道异常：降级 detached，不重试
      }
    }
    AppLogger.I.w(_tag, 'worktree 分支挂载失败，保持 detached: $directory');
  }

  /// 删除后分支清理（design-worktree-branch-sync §2.3）：v2 DELETE 不清分支。
  /// 在项目 canonical 下操作（worktree 目录已消失，不能 -C 进去）。
  /// show-ref 探存在 → for-each-ref --contains（排除自身）判是否已并入其他
  /// ref：已并入 → `branch -D` 清理返回 null；未并入 → 返回分支名（调用方
  /// 提示保留）。shell 通道异常 → 返回 null（宁残留不误删，也不误报保留）。
  /// 三个 shell 各 5s 超时（评审 WBS-1：清理串行在 deleting 态内，最坏
  /// 15s 收口；超时同走「宁残留不误删」降级）。
  Future<String?> _cleanupWorktreeBranch(
    OpencodeClient c,
    ProjectModel project,
    String directory,
  ) async {
    final base = _worktreeBranchBase(directory);
    if (base == null || project.canonical.isEmpty) return null;
    final branch = 'opencode/$base';
    try {
      final exists = await c.runShell(
          'git show-ref --verify --quiet refs/heads/$branch',
          cwd: project.canonical,
          timeoutMs: 5000);
      if (exists.exit != 0) return null; // 无同名分支——无事可做
      final contains = await c.runShell(
        // --format 值必须单引号：fish 把裸括号 %(refname) 解析为命令替换，
        // 单引号在 fish/POSIX shell 下均为字面量
        "git for-each-ref --contains refs/heads/$branch "
        "--format='%(refname)' refs/heads refs/remotes",
        cwd: project.canonical,
        timeoutMs: 5000,
      );
      // 竞态（show-ref 后分支被删）下 for-each-ref 报错——不误报「已保留」
      if (contains.exit != 0) return null;
      final mergedElsewhere = contains.output
          .split('\n')
          .map((line) => line.trim())
          .any((ref) => ref.isNotEmpty && ref != 'refs/heads/$branch');
      if (mergedElsewhere) {
        final del = await c.runShell('git branch -D $branch',
            cwd: project.canonical, timeoutMs: 5000);
        // -D 失败（如同名分支恰被另一 worktree 检出）→ 走保留路径兜底
        return del.exit == 0 ? null : branch;
      }
      return branch; // 未并入 → 保留（含未合并提交）
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
    conv.onContentSynced = onContentSynced;
    conv.isSessionStaleSession = isSessionStale;
    conv.seedSyncedUpdated(_contentWatermarks[sid] ?? 0);
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

  ConversationStore? conversationFor(String sessionId) {
    final existing = _conversations[sessionId];
    if (existing != null) {
      _conversations.remove(sessionId);
      _conversations[sessionId] = existing;
      existing.sessionUpdated = sessionById(sessionId)?.updated;
      if (!existing.loaded) {
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
      _childrenByParent.clear();
      _statusMap.clear();
      _ghostSessionIds.clear();
      _lastMessage.clear();
      _lastActivityByKey.clear();
      _workspaceEnabled.clear();
      _worktreeDirs.clear();
      _contentWatermarks.clear();
      _staleSessionIds.clear();
      _livePreviewSids.clear();
      _sseEpoch = 0;
      _lastDiffEpoch = -1;
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
      for (final d in worktreeDirsOf(p.id)) {
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
      if (worktreeDirsOf(p.id).contains(directory)) return true;
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

  Future<void> _reconcileWorktrees(
    List<ProjectModel> projects, {
    Map<String, List<String>>? worktreesByDir,
    Iterable<SessionModel>? sessions,
  }) async {
    final c = client;
    if (c == null) return;
    final map = worktreesByDir ?? <String, List<String>>{};
    final byId = {for (final p in projects) p.id: p};
    final foreignDirProjects = <String>{};
    for (final s in sessions ?? _sessions) {
      if (s.directory.isEmpty) continue;
      final p = byId[s.projectID];
      if (p == null || p.id == 'global') continue;
      if (s.directory != p.canonical) foreignDirProjects.add(p.id);
    }
    await Future.wait(projects.map((p) async {
      if (!p.workspaceCapable || p.canonical.isEmpty) return;
      if (_worktreeDirs[p.id]?.isNotEmpty != true &&
          !(_workspaceEnabled[p.id] ?? false) &&
          !foreignDirProjects.contains(p.id)) {
        return;
      }
      try {
        final wts = await c.worktrees(p.id);
        final dirs = _oldestFirstDirs(wts);
        if (dirs.isEmpty) return;
        _worktreeDirs[p.id] = dirs;
        map[p.canonical] = dirs;
      } catch (_) {}
    }));
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
      final sessions = await _fetchAllSessions();
      final projects = await client!.projects();
      await _reconcileWorktrees(projects,
          worktreesByDir: worktreesByDir, sessions: sessions);
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, projects, worktreesByDir);
      _projects = projects;
      _projectsFetched = true;
      _diffStaleSessions(sessions, full: true, busySids: _busySids());
      _sessions = _mergeFetchedSessions(sessions);
      _markGhostSessions(ghostIds);
      final active = await _fetchActiveStatuses();
      if (active != null) {
        _mergeStatus(fresh: active, sessions: sessions);
        unawaited(_probeBusyMessageTimes(allowStaleVerdict: true));
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

  static int _effectiveFresh(SessionModel s) =>
      s.updated > (s.idle ?? 0) ? s.updated : (s.idle ?? 0);

  Set<String> _busySids({Map<String, SessionStatusValue>? active}) {
    final out = <String>{
      for (final e in _statusMap.entries)
        if (e.value.type == 'busy' || e.value.type == 'retry') e.key,
    };
    if (active != null) out.addAll(active.keys);
    return out;
  }

  void _diffStaleSessions(List<SessionModel> fresh,
      {bool full = false, Set<String>? busySids}) {
    final freshIds = fresh.map((s) => s.id).toSet();
    for (final s in fresh) {
      final known = _contentWatermarks[s.id] ?? 0;
      if (_effectiveFresh(s) > known) {
        if (_staleSessionIds.add(s.id)) {
          _livePreviewSids.remove(s.id);
        }
      } else if (busySids == null || !busySids.contains(s.id)) {
        _staleSessionIds.remove(s.id);
      }
    }
    if (full) {
      _staleSessionIds.removeWhere((sid) => !freshIds.contains(sid));
      // 归档/删除/超出列表上限的会话：水位与预览标记兜底清理（_removeSession
      // 只覆盖硬删除；归档走 _upsertSession 的移除分支，watermark/live 标记会
      // 残留并随 server blob 持久化）。child 会话不在 fresh 列表中但仍在
      // _childSessions 里活跃，跳过其水位清理以免无谓 churn。
      for (final sid in _contentWatermarks.keys.toList()) {
        if (freshIds.contains(sid) || _childSessions.containsKey(sid)) continue;
        _contentWatermarks.remove(sid);
        _livePreviewSids.remove(sid);
      }
      _lastDiffEpoch = _sseEpoch;
    }
  }

  void onContentSynced(String sid, int updated, {required bool fromReconcile}) {
    if (!fromReconcile) {
      if (_staleSessionIds.contains(sid) || _lastDiffEpoch != _sseEpoch) {
        return;
      }
    }
    final cur = _contentWatermarks[sid] ?? 0;
    if (updated > cur) {
      _contentWatermarks[sid] = updated;
      _scheduleCacheSave();
    }
    if (fromReconcile) {
      final wasStale = _staleSessionIds.remove(sid);
      if (wasStale) _notifyPreviewChanged();
    }
  }

  Future<bool> ensureSessionFresh(String sid) async {
    if (_lastDiffEpoch == _sseEpoch) return _staleSessionIds.contains(sid);
    final c = client;
    final dir = sessionById(sid)?.directory;
    if (c == null || dir == null || dir.isEmpty) {
      return _staleSessionIds.contains(sid);
    }
    final fresh = await c.sessionsForDirectory(dir);
    for (final s in fresh) {
      _upsertSession(s);
    }
    SessionModel? me;
    for (final s in fresh) {
      if (s.id == sid) {
        me = s;
        break;
      }
    }
    _conversations[sid]?.sessionUpdated = me == null ? null : _effectiveFresh(me);
    _diffStaleSessions(fresh, busySids: _busySids());
    notifyListeners();
    return _staleSessionIds.contains(sid);
  }

  Future<void> reconcileConversation(String sid) async {
    final conv = _conversations[sid];
    if (conv == null) return;
    final s = sessionById(sid);
    if (s != null) {
      final target = _effectiveFresh(s);
      if (target > (conv.sessionUpdated ?? 0)) conv.sessionUpdated = target;
    }
    await conv.reconcile();
    await _backfillPreview(sid, conv);
  }

  Future<void> awaitReconcile(String sid) =>
      _conversations[sid]?.reconcileDone ?? Future.value();

  void _bumpSseEpochMarkBusy() {
    _sseEpoch++;
    for (final e in _statusMap.entries) {
      if (e.value.type == 'busy' || e.value.type == 'retry') {
        _staleSessionIds.add(e.key);
      }
    }
  }

  void _addSessions(Map<String, SessionModel> out, List<SessionModel> list) {
    for (final s in list) {
      _bumpLastActivity(s);
      if (s.isArchived) continue;
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

  Future<bool> refreshListAndWorkingSse(
      {bool force = false, bool reconcileWorktrees = false}) async {
    if (client == null) return false;
    PerfProbe.I.markEvent('refresh-start force=$force');
    try {
      if (force || _sse == null) {
        _startSse();
      }
      List<ProjectModel> newProjects;
      final worktreesByDir = <String, List<String>>{};
      if (force || !_projectsFetched) {
        newProjects = await client!.projects();
        await _reconcileWorktrees(newProjects, worktreesByDir: worktreesByDir);
      } else if (reconcileWorktrees) {
        await _reconcileWorktrees(_projects, worktreesByDir: worktreesByDir);
        newProjects = _projects;
      } else {
        newProjects = _projects;
      }
      _projectsFetched = true;
      final sessions = await _fetchAllSessions();
      _unghostRecovered(sessions);
      final ghostIds =
          _detectGhostSessionIds(_sessions, sessions, newProjects, worktreesByDir);
      final active = await _fetchActiveStatuses();
      _projects = newProjects;
      _diffStaleSessions(sessions,
          full: true, busySids: _busySids(active: active));
      _sessions = _mergeFetchedSessions(sessions);
      _markGhostSessions(ghostIds);
      if (active != null) {
        _mergeStatus(fresh: active, sessions: sessions);
        unawaited(_probeBusyMessageTimes(
            allowStaleVerdict: _sseLive || force));
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
    if (activeConv != null && !activeConv.loaded) {
      unawaited(activeConv.load()
          .then((_) => _backfillPreview(activeId!, activeConv)));
    }
    unawaited(_backfillPermissions());
    PerfProbe.I.markEvent('refresh-done');
    notifyListeners();
    return true;
  }

  Future<void> _reconcile() async {
    if (client == null) return;
    await refreshListAndWorkingSse(force: false, reconcileWorktrees: true);
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
      _bumpSseEpochMarkBusy();
      _startHealthProbe();
    } else if (s.connected) {
      _stopHealthProbe();
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
  void resetForTesting() {
    _conversations.clear();
    _sessions = [];
    _childSessions.clear();
    _childrenByParent.clear();
    _statusMap.clear();
    _pendingPermissions.clear();
    _pendingForms.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _contentWatermarks.clear();
    _staleSessionIds.clear();
    _ghostSessionIds.clear();
    _livePreviewSids.clear();
  }

  @visibleForTesting
  Future<void> reconcileWorktreesForTesting(
    List<ProjectModel> projects, {
    Iterable<SessionModel>? sessions,
  }) =>
      _reconcileWorktrees(projects, sessions: sessions);

  @visibleForTesting
  void setWorktreeDirsForTesting(String projectId, List<String> dirs) =>
      _worktreeDirs[projectId] = dirs;

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

  @visibleForTesting
  void diffStaleForTesting(List<SessionModel> fresh,
          {bool full = false, Set<String>? busySids}) =>
      _diffStaleSessions(fresh, full: full, busySids: busySids);

  @visibleForTesting
  void onContentSyncedForTesting(String sid, int updated,
          {required bool fromReconcile}) =>
      onContentSynced(sid, updated, fromReconcile: fromReconcile);

  @visibleForTesting
  void bumpSseEpochForTesting() => _bumpSseEpochMarkBusy();

  @visibleForTesting
  void consumeEpochForTesting() {
    _lastDiffEpoch = _sseEpoch;
  }

  @visibleForTesting
  int? watermarkOf(String sid) => _contentWatermarks[sid];

  @visibleForTesting
  void probeBusyForTesting({bool allowStaleVerdict = false}) =>
      _probeBusyMessageTimes(allowStaleVerdict: allowStaleVerdict);

  @visibleForTesting
  void injectConversationForTesting(String sid, ConversationStore conv) {
    _conversations[sid] = conv;
  }

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
    if (sid != null &&
        ev.created != null &&
        ev.type.startsWith('session.')) {
      onContentSynced(sid, ev.created!, fromReconcile: false);
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
        final sidM = ev.properties['sessionID']?.toString();
        final metaM = ev.properties['metadata'];
        if (sidM != null && metaM is Map) {
          _applyMetadataSnapshot(sidM, metaM);
        }
        break;
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
          // 子会话不在 _sessions，_touchActivity 会早退——显式通知列表/Tab
          // 指示器，使父会话的「家族进行中」聚合即时生效。
          if (isChildSession(sid1)) _notifyActivityThrottled();
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
          _statusMap[sid2] = const SessionStatusValue('idle');
          _conversations[sid2]?.setStatus('idle');
          if (isChildSession(sid2)) _notifyActivityThrottled();
          _scheduleCacheSave();
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
            // 子会话直接进入 retry 时也刷新父会话列表/Tab 的「家族进行中」聚合。
            if (isChildSession(sid3)) _notifyActivityThrottled();
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
            _livePreviewSids.add(sidB);
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
      case 'session.synthetic':
        final sidSyn = ev.properties['sessionID']?.toString();
        final evId = ev.id ?? '';
        if (sidSyn != null && evId.isNotEmpty) {
          final metaSyn = ev.properties['metadata'];
          ensureConversation(sidSyn)?.onSynthetic(SyntheticMessage(
            id: evId.replaceFirst(RegExp(r'^evt_'), 'msg_'),
            raw: ev.properties,
            metadata: metaSyn is Map ? metaSyn.cast<String, dynamic>() : null,
            created: ev.created ?? DateTime.now().millisecondsSinceEpoch,
            text: ev.properties['text']?.toString() ?? '',
            description: ev.properties['description']?.toString(),
          ));
        }
        return;
      case 'session.compaction.started':
      case 'session.compaction.delta':
      case 'session.compaction.ended':
      case 'session.compaction.failed':
      case 'session.compacted':
      case 'session.shell.started':
      case 'session.shell.ended':
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
      _livePreviewSids.add(sid);
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
      notifyListeners();
    } catch (_) {}
  }

  Future<void> _backfillPreview(String sid, ConversationStore conv) async {
    final preview = conv.lastMessagePreview(
        hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
    if (preview != null) {
      _lastMessage[sid] = preview;
      _livePreviewSids.add(sid);
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
      _livePreviewSids.add(sid);
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

  Future<void> _probeBusyMessageTimes({bool allowStaleVerdict = false}) async {
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
          final summary = allowStaleVerdict
              ? await c.latestMessageSummary(sid)
              : LatestMessageSummary(at: await c.latestMessageAt(sid));
          final at = summary.at;
          final s = sessionById(sid);
          if (at != null && s != null && at > s.updated) {
            _upsertSession(s.copyWith(updated: at));
            touched = true;
          }
          if (!allowStaleVerdict || summary.message == null) continue;
          final wm = _contentWatermarks[sid] ?? 0;
          if (at != null &&
              at - wm > _kProbeStaleMargin.inMilliseconds &&
              _staleSessionIds.add(sid)) {
            AppLogger.I.d(_tag, 'probe marked stale $sid at=$at wm=$wm');
          }
          if (isSessionStale(sid)) {
            final pv = sessionMessagePreviewText(summary.message!,
                hideReasoning: !_reasoningVisibleInPreview, loc: _loc);
            if (pv != null && pv.isNotEmpty) {
              _lastMessage[sid] = pv;
              _livePreviewSids.add(sid);
              touched = true;
            }
          }
        } catch (_) {}
      }
    } finally {
      _busyProbeInFlight = false;
    }
    if (touched) _notifyActivityThrottled();
  }

  void _applyMetadataSnapshot(String sid, Map meta) {
    final s = sessionById(sid) ?? _childSessions[sid];
    final v = meta['archivedAt'];
    if (s == null) {
      if (v == null) unawaited(_refreshSessionMeta(sid));
      return;
    }
    _upsertSession(s.withMetadataArchivedAt(v is num ? v.toInt() : null));
  }

  void _upsertSession(SessionModel raw) {
    final idx = _sessions.indexWhere((x) => x.id == raw.id);
    final s = _withEffectiveActivity(
        raw, idx == -1 ? null : _sessions[idx]);
    _bumpLastActivity(s);
    if (s.parentID != null) {
      _sessions.removeWhere((x) => x.id == s.id);
      if (s.isArchived) {
        final host = _cardHostSessionId(s.id);
        _unindexChild(s.id, s.parentID);
        _childSessions.remove(s.id);
        _dropChildCards(s.id, host);
      } else {
        _upsertChildSession(s);
      }
      _scheduleCacheSave();
      return;
    }
    if (s.isArchived) {
      _sessions.removeWhere((x) => x.id == s.id);
      _unindexChild(s.id, s.parentID);
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

  void _indexChild(String id, String? parentID) {
    if (parentID == null) return;
    final list = _childrenByParent.putIfAbsent(parentID, () => []);
    if (!list.contains(id)) list.add(id);
  }

  void _unindexChild(String id, String? parentID) {
    if (parentID == null) return;
    final list = _childrenByParent[parentID];
    if (list == null) return;
    list.remove(id);
    if (list.isEmpty) _childrenByParent.remove(parentID);
  }

  void _upsertChildSession(SessionModel s) {
    final newlyRegistered = !_childSessions.containsKey(s.id);
    final previous = _childSessions.remove(s.id);
    if (previous != null && previous.parentID != s.parentID) {
      _unindexChild(s.id, previous.parentID);
    }
    _childSessions[s.id] = s;
    _indexChild(s.id, s.parentID);
    _evictExcessChildSessions(keepId: s.id);
    _backfillConversationDirectory(s.id, s.directory);
    if (newlyRegistered) {
      _adoptChildCards(s);
      _conversations[s.parentID]?.onChildSessionRegistered(s);
    }
  }

  /// 子会话 LRU 上限淘汰。历史上限之外还须满足：**不淘汰刚插入的会话**、
  /// **不淘汰正在运行（busy/retry）的会话**——否则正在进行中的后台任务会
  /// 被一次 reconcile 淘汰出索引，任务条随即消失（design-subagent-background
  /// D1）。优先淘汰已有终态 outcome 的旧会话，其次才是无 outcome 的闲置会话。
  void _evictExcessChildSessions({required String keepId}) {
    var guard = 0;
    while (_childSessions.length > _kMaxChildSessions &&
        guard++ < _kMaxChildSessions) {
      String? victimId;
      var victimSettled = false;
      var victimUpdated = 0;
      var victimCreated = 0;
      for (final e in _childSessions.entries) {
        if (e.key == keepId) continue;
        final t = _statusMap[e.key]?.type;
        if (t == 'busy' || t == 'retry') continue;
        final settled = e.value.outcome != null;
        final better = victimId == null ||
            (settled && !victimSettled) ||
            (settled == victimSettled &&
                (e.value.updated < victimUpdated ||
                    (e.value.updated == victimUpdated &&
                        e.value.created < victimCreated)));
        if (better) {
          victimId = e.key;
          victimSettled = settled;
          victimUpdated = e.value.updated;
          victimCreated = e.value.created;
        }
      }
      if (victimId == null) break;
      final evicted = _childSessions.remove(victimId);
      _unindexChild(victimId, evicted?.parentID);
      _statusMap.remove(victimId);
    }
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

  /// 某会话的直接子会话，按创建时间升序（后台任务条 / 详情用）。
  List<SessionModel> childSessionsOf(String parentId) {
    final out = <SessionModel>[];
    for (final childId in _childrenByParent[parentId] ?? const <String>[]) {
      final child = _childSessions[childId];
      if (child != null) out.add(child);
    }
    out.sort((a, b) => a.created.compareTo(b.created));
    return out;
  }

  /// 某会话正在运行的直系子会话（`_statusMap` busy/retry）。
  List<SessionModel> runningChildSessionsOf(String parentId) =>
      childSessionsOf(parentId)
          .where((c) {
            final t = _statusMap[c.id]?.type;
            return t == 'busy' || t == 'retry';
          })
          .toList(growable: false);

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
    _unindexChild(id, _childSessions[id]?.parentID);
    _childSessions.remove(id);
    if (childHost != null) _dropChildCards(id, childHost);
    _conversations.remove(id);
    _lastMessage.remove(id);
    _statusMap.remove(id);
    _ghostSessionIds.remove(id);
    _contentWatermarks.remove(id);
    _livePreviewSids.remove(id);
    _staleSessionIds.remove(id);
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
    _childrenByParent.clear();
    _statusMap.clear();
    _ghostSessionIds.clear();
    _lastMessage.clear();
    _lastActivityByKey.clear();
    _workspaceEnabled.clear();
    _worktreeDirs.clear();
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
  @visibleForTesting
  static const int kAgentsModelsEmptyRetries = 2;
  @visibleForTesting
  static Duration agentsModelsEmptyRetryDelay =
      const Duration(milliseconds: 600);
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
    fut = _fetchAgentsAndModels(c, directory).then((entry) {
      if (identical(c, client) &&
          epoch == _agentsModelsEpoch &&
          entry.$1.isNotEmpty &&
          entry.$2.isNotEmpty) {
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

  Future<(List<AgentInfo>, List<ModelInfo>)> _fetchAgentsAndModels(
    OpencodeClient c,
    String? directory,
  ) async {
    var entry = await _fetchAgentsAndModelsOnce(c, directory);
    var attempt = 0;
    while ((entry.$1.isEmpty || entry.$2.isEmpty) &&
        attempt < kAgentsModelsEmptyRetries) {
      if (!identical(c, client)) break;
      attempt++;
      await Future<void>.delayed(agentsModelsEmptyRetryDelay);
      entry = await _fetchAgentsAndModelsOnce(c, directory);
    }
    return entry;
  }

  Future<(List<AgentInfo>, List<ModelInfo>)> _fetchAgentsAndModelsOnce(
    OpencodeClient c,
    String? directory,
  ) async {
    final results = await Future.wait([
      c.listAgents(directory: directory),
      c.listModels(directory: directory),
    ]);
    return (
      results[0] as List<AgentInfo>,
      results[1] as List<ModelInfo>,
    );
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
      await refreshListAndWorkingSse(force: false, reconcileWorktrees: true);
      return;
    }

    unawaited(_backfillPermissions());
    notifyListeners();
  }

  Future<void> _stopSse({bool flushCache = true}) async {
    _reconcileTimer?.cancel();
    _reconcileTimer = null;
    _stopHealthProbe();
    if (_sse != null) {
      _bumpSseEpochMarkBusy();
    }
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
        'worktreeDirs': _worktreeDirs,
        'syncWatermarks': _contentWatermarks,
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
      final wmRaw = j['syncWatermarks'] as Map?;
      if (wmRaw != null) {
        for (final entry in wmRaw.entries) {
          final v = entry.value;
          final n = v is int ? v : (v is num ? v.toInt() : null);
          if (n == null || n <= 0) continue;
          _contentWatermarks[entry.key.toString()] = n;
        }
      } else {
        for (final s in sessions) {
          final seed = _effectiveFresh(s);
          if (seed > 0) _contentWatermarks[s.id] = seed;
        }
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
      final wtRaw = j['worktreeDirs'] as Map? ?? {};
      for (final entry in wtRaw.entries) {
        final dirs = entry.value;
        if (dirs is! List) continue;
        _worktreeDirs.putIfAbsent(entry.key.toString(),
            () => dirs.map((e) => e.toString()).toList(growable: false));
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
