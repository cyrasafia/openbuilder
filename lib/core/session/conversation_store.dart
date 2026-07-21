import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/api/opencode_client.dart';
import '../../../domain/models.dart';
import '../attachments/attachment_pipeline.dart';
import '../logging/app_logger.dart';

const _tag = 'Conv';

/// Mutable, render-friendly part for the conversation view.
class DisplayPart {
  final String id;
  final String type; // text | reasoning | tool | agent | subtask | file | ...
  String? tool;
  String text;
  String? toolStatus;
  String? toolOutput;
  String? toolError;
  Map<String, dynamic>? toolInput;
  String? fileMime;
  String? fileUrl;
  String? filename;
  Uint8List? previewThumb;

  DisplayPart({
    required this.id,
    required this.type,
    this.tool,
    this.text = '',
    this.toolStatus,
    this.toolOutput,
    this.toolError,
    this.toolInput,
    this.fileMime,
    this.fileUrl,
    this.filename,
    this.previewThumb,
  });

  /// One-line summary of what the tool is doing (e.g. "bash: ls -la").
  String get toolSummary {
    if (tool == null) return '';
    final input = toolInput;
    if (input == null || input.isEmpty) return tool!;
    switch (tool) {
      case 'bash':
      case 'shell':
        final cmd = input['command']?.toString();
        if (cmd != null && cmd.isNotEmpty) {
          final firstLine = cmd.split('\n').first.trim();
          return firstLine.length > 80
              ? '$tool: ${firstLine.substring(0, 77)}...'
              : '$tool: $firstLine';
        }
        return tool!;
      case 'read':
      case 'write':
      case 'edit':
        final path = input['filePath']?.toString() ?? input['path']?.toString();
        if (path != null && path.isNotEmpty) {
          final name = path.split('/').last;
          return '$tool: $name';
        }
        return tool!;
      case 'list':
        final path = input['path']?.toString();
        if (path != null && path.isNotEmpty) {
          return '$tool: ${path.split('/').last}';
        }
        return tool!;
      case 'glob':
        final pattern = input['pattern']?.toString();
        if (pattern != null && pattern.isNotEmpty) {
          return '$tool: $pattern';
        }
        return tool!;
      case 'grep':
        final pattern = input['pattern']?.toString();
        if (pattern != null && pattern.isNotEmpty) {
          return '$tool: "$pattern"';
        }
        return tool!;
      case 'task':
        final desc = input['description']?.toString();
        if (desc != null && desc.isNotEmpty) return '$tool: $desc';
        return tool!;
      default:
        // Generic: show first key-value pair.
        if (input.isNotEmpty) {
          final firstKey = input.keys.first;
          final val = input[firstKey]?.toString() ?? '';
          if (val.isNotEmpty) {
            return '$tool: ${val.length > 60 ? '${val.substring(0, 57)}...' : val}';
          }
        }
        return tool!;
    }
  }

  factory DisplayPart.from(MessagePart p) {
    if (p.type == 'tool') {
      return DisplayPart(
        id: p.id,
        type: p.type,
        tool: p.tool,
        toolStatus: p.stateStatus,
        toolOutput: p.stateOutput,
        toolError: _extractToolError(p.state?['error']),
        toolInput: p.state?['input'] is Map
            ? (p.state!['input'] as Map).cast<String, dynamic>()
            : null,
      );
    }
    if (p.type == 'file') {
      return DisplayPart(
        id: p.id,
        type: 'file',
        fileMime: p.raw['mime']?.toString(),
        fileUrl: p.raw['url']?.toString() ?? '',
        filename: p.raw['filename']?.toString(),
      );
    }
    return DisplayPart(id: p.id, type: p.type, text: p.text ?? '');
  }
}

String? _extractToolError(dynamic raw) {
  if (raw == null) return null;
  if (raw is String) return raw.isNotEmpty ? raw : null;
  if (raw is Map) {
    final msg = raw['message']?.toString();
    if (msg != null && msg.isNotEmpty) return msg;
    final err = raw['error']?.toString();
    if (err != null && err.isNotEmpty) return err;
    final detail = raw.toString();
    return detail.isNotEmpty && detail != '{}' ? detail : null;
  }
  final s = raw.toString();
  return s.isNotEmpty && s != 'null' ? s : null;
}

class DisplayMessage {
  final MessageInfo info;
  final List<DisplayPart> parts = [];
  bool optimistic; // true for locally-inserted user messages pending server confirm
  DisplayMessage(this.info, {this.optimistic = false});
}

/// Metadata for a contiguous message range in `_messages`.
///
/// `_segments` is ordered newest→oldest; `segments[0]` is the bottom (reachable)
/// segment. Adjacent segments have a gap (unloaded messages) between them.
/// Only `segments[0]` is rendered ([renderableMessages]); `segments[1+]` are
/// in memory but unreachable until the gap is bridged by upward scrolling.
class _Segment {
  String oldestId;
  int oldestCreated;
  String? cursor; // anchors oldestId for paging further back; null = history start
  _Segment({required this.oldestId, required this.oldestCreated, this.cursor});
}

/// Per-session live state: messages (streaming), todos, permissions.
class ConversationStore extends ChangeNotifier {
  final String sessionId;
  final OpencodeClient client;

  /// 会话所属 directory，用于 question reply/reject 的路由参数（opencode
  /// question pending 按 directory 隔离到 instance，不带 directory 会 404）。
  /// 由 ServerStore.ensureConversation 从 sessionById(sid).directory 注入；
  /// 若 question.asked 早于 session 加载（SSE 竞态），初始为空，待 session
  /// 到达后由 ServerStore._upsertSession/_addSessions 经 [setDirectory] 回填。
  /// 公开但仅应由 [setDirectory] 修改。
  String directory;

  /// Reply/reject 命中 200 或 404 后触发，让 ServerStore 把该 id 登记进
  /// _recentlyResolved 集合，防止 backfill 在服务端列表清理前重注入。
  void Function(String questionId)? onQuestionResolved;
  void Function(String permissionId)? onPermissionResolved;

  ConversationStore(this.sessionId, this.client, {this.directory = ''});

  /// 回填 directory（仅当当前为空时填充，避免覆盖已注入的有效值）。
  void setDirectory(String dir) {
    if (dir.isNotEmpty && directory.isEmpty) {
      directory = dir;
    }
  }

  final List<DisplayMessage> _messages = [];
  final List<_Segment> _segments = [];
  List<Todo> _todos = [];
  final List<Permission> _permissions = [];
  final List<QuestionRequest> _questions = [];
  bool loading = false;
  bool loaded = false;
  String? error;
  Map<String, dynamic>? sessionError;
  String status = 'idle';
  /// Retry error message surfaced from `session.status` (retry variant).
  /// Cleared on any non-retry status transition. Distinct from
  /// [sessionError] (fed by the one-shot `session.error` SSE event) so the
  /// detail page can show whichever the server delivered.
  String? retryMessage;
  int? sessionUpdated;
  bool _loadingEarlier = false;
  bool _loadEarlierError = false;

  bool _stale = false;
  bool _reconciling = false;
  DateTime? _lastReloadAt;
  static const _reloadBackoff = Duration(seconds: 10);
  // Window size for reconcile + backward paging. ~7-12 mobile screens of
  // messages; balances first-open payload vs scroll-up fill latency.
  static const _kWindow = 100;

  Timer? _loadRetryTimer;
  int _loadRetryAttempt = 0;
  bool _disposed = false;
  Future<void> Function()? _backfillCallback;

  /// Set a callback to be invoked after a successful reconcile (including
  /// retries). Used by ServerStore to bridge _lastMessage on retry success
  /// (LPS-20). Cleared after first successful invocation.
  void setBackfillCallback(Future<void> Function()? cb) => _backfillCallback = cb;
  static const _loadInitialBackoff = Duration(seconds: 2);
  static const _loadMaxBackoff = Duration(seconds: 30);

  List<DisplayMessage> get messages => List.unmodifiable(_messages);
  List<Todo> get todos => List.unmodifiable(_todos);
  List<Permission> get permissions => List.unmodifiable(_permissions);
  List<QuestionRequest> get questions => List.unmodifiable(_questions);
  bool get busy => status == 'busy' || status == 'retry';
  bool get isRetry => status == 'retry';

  /// Messages for the detail view: only the bottom (reachable) segment,
  /// newest-first (for the reversed ListView). Messages above an unbridged
  /// gap ([_segments] 1+) are in memory but not rendered — they become
  /// reachable only after the gap is bridged by upward scrolling.
  List<DisplayMessage> get renderableMessages {
    if (_segments.isEmpty) return _messages.reversed.toList(growable: false);
    final seg = _segments.first;
    final result = <DisplayMessage>[];
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      result.add(m);
      if (m.info.id == seg.oldestId) break;
    }
    return result;
  }

  /// Whether older history can still be loaded (by scrolling up).
  bool get hasMore => _segments.firstOrNull?.cursor != null;

  /// Whether a backward page load is in progress.
  bool get loadingEarlier => _loadingEarlier;

  /// Whether the last backward page load failed (IR-R4). Cleared on next
  /// successful load or when a new attempt starts.
  bool get loadEarlierError => _loadEarlierError;

  /// One-line preview of the last message, aligned with what the detail view
  /// renders. Walks parts last→first, skipping hidden types, and returns the
  /// first non-empty summary (null when there is nothing to show).
  ///
  /// Single source of truth for the session-list preview so it tracks the
  /// detail view's last message during streaming — not only on completion
  /// (frontend §2.2 D1).
  String? lastMessagePreview() {
    if (_messages.isEmpty) return null;
    final last = _messages.last;
    var preview = '';
    for (var i = last.parts.length - 1; i >= 0; i--) {
      final dp = last.parts[i];
      if (_hidden.contains(dp.type)) continue;
      String pv;
      if (dp.type == 'tool') {
        pv = dp.toolSummary;
      } else if (dp.type == 'file') {
        pv = (dp.filename?.isNotEmpty ?? false) ? dp.filename! : '[附件]';
      } else {
        pv = dp.text.replaceAll('\n', ' ').trim();
      }
      if (pv.isNotEmpty) {
        preview = pv;
        break;
      }
    }
    if (preview.isEmpty) return null;
    return (last.info.role == 'user' ? '你: ' : '') + preview;
  }

  // ── Self-healing public API ──

  bool get isStale => _stale;
  void markStale() => _stale = true;

  @override
  void dispose() {
    _disposed = true;
    _loadRetryTimer?.cancel();
    super.dispose();
  }

  void cancelLoadRetry() {
    _loadRetryTimer?.cancel();
    _loadRetryTimer = null;
    loading = false;
  }

  /// Insert an optimistic user message immediately after sending, so the UI
  /// shows it without waiting for SSE/rest confirmation. Removed when the
  /// authoritative message list arrives (reload) or when a matching user
  /// message.updated event arrives.
  void addOptimisticUserMessage(String text,
      {List<AttachmentPreview>? attachments}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = DisplayMessage(
      MessageInfo(id: 'optimistic_$now', role: 'user', created: now),
      optimistic: true,
    );
    if (text.isNotEmpty) {
      msg.parts.add(DisplayPart(
        id: 'optimistic_part_$now',
        type: 'text',
        text: text,
      ));
    }
    if (attachments != null) {
      var i = 0;
      for (final a in attachments) {
        msg.parts.add(DisplayPart(
          id: 'optimistic_file_${now}_$i',
          type: 'file',
          fileMime: a.mime,
          fileUrl: a.dataUrl,
          filename: a.filename,
          previewThumb: a.previewThumb,
        ));
        i++;
      }
    }
    _messages.add(msg);
    _sort();
    notifyListeners();
  }

  /// Remove optimistic messages — called when authoritative data replaces
  /// the local guess (reload, onMessageUpdated with a real user message).
  void _pruneOptimistic() {
    _messages.removeWhere((m) => m.optimistic);
  }

  /// Public entry point for removing optimistic messages (e.g. send failure).
  void removeOptimisticMessages() {
    final had = _messages.any((m) => m.optimistic);
    _pruneOptimistic();
    if (had) notifyListeners();
  }

  Future<void> reloadIfStale() async {
    if (!_stale || _reconciling || loading) return;
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
    // Await _attemptLoad so the returned Future resolves after the reconcile
    // attempt (not immediately). All callers unawait this, so the UI still
    // gets the conv synchronously with loading=true; but chaining
    // `.then(_backfillPreview)` (E path, §6.6) now runs after reconcile merged
    // REST, reading the up-to-date _messages instead of the pre-reconcile state.
    await _attemptLoad();
  }

  Future<void> _attemptLoad() async {
    if (_disposed) return;
    if (loaded && !_stale) {
      _loadRetryTimer?.cancel();
      return;
    }
    if (_reconciling) {
      _scheduleLoadRetry(incrementAttempt: false);
      return;
    }
    // Cache preheat: instant display if session.updated matches cache.
    await _maybePreheatCache();
    if (_disposed) return;
    await reconcile();
    if (_disposed) return;
    if (_stale) {
      _scheduleLoadRetry();
    } else {
      _loadRetryAttempt = 0;
      _loadRetryTimer?.cancel();
      final cb = _backfillCallback;
      _backfillCallback = null;
      if (cb != null) await cb();
    }
    notifyListeners();
  }

  void _scheduleLoadRetry({bool incrementAttempt = true}) {
    _loadRetryTimer?.cancel();
    if (incrementAttempt) _loadRetryAttempt++;
    final exp = (_loadRetryAttempt - 1).clamp(0, 4);
    final secs = (_loadInitialBackoff.inSeconds << exp)
        .clamp(1, _loadMaxBackoff.inSeconds);
    _loadRetryTimer = Timer(Duration(seconds: secs), () {
      if (_disposed) return;
      _attemptLoad();
    });
  }

  /// 增量对账：拉最新 K 条尾部窗口（不全量），与本地按 id 合并（upsert）。
  /// 窗口与底部分段无重叠时形成断档（新 segments[0]，旧的移到 [1+]），
  /// 由用户上滚时 [loadOnePage] 分段衔接。失败回退：`_messages` 空才
  /// `_loadCache`，否则保 SSE 累积并标 stale。
  Future<void> reconcile() async {
    if (_reconciling) return; // 互斥
    _reconciling = true;
    _lastReloadAt = DateTime.now();
    AppLogger.I.d(_tag, 'reconcile start $sessionId');
    try {
      final page = await client.messagesPage(sessionId, limit: _kWindow);
      final entries = page.entries;
      AppLogger.I.d(_tag,
          'reconcile fetched ${entries.length} messages $sessionId hasCursor=${page.nextCursor != null}');
      // Infer session status from the last message — terminal finish values
      // ('stop'/'error') mean the session is idle. Preserved from reload so
      // self-healing paths (watchdog reconnect, manual refresh) still correct
      // a missed idle transition.
      if (entries.isNotEmpty) {
        final last = entries.last.info;
        if (last.role == 'assistant' &&
            (last.finish == 'stop' || last.finish == 'error')) {
          setStatus('idle');
        }
      }
      // Check overlap with segments[0] BEFORE upsert (upsert would insert
      // entries into _messages and make the check trivially true).
      final overlapped = _entriesOverlapSegment(entries, 0);
      // Window-range deletion (strict interior): handle revert.
      _applyWindowDeletion(entries);
      // Upsert: info=REST authoritative, parts field-level merge.
      _upsertEntries(entries);
      // Segment logic
      if (entries.isEmpty) {
        // No messages on server — segments unchanged (or stay empty).
      } else if (_segments.isEmpty || !overlapped) {
        // First reconcile OR no overlap with existing bottom segment →
        // entries become new segments[0], old segments shift down (gap forms).
        final oldest = entries.first.info;
        _segments.insert(
            0,
            _Segment(
                oldestId: oldest.id,
                oldestCreated: oldest.created ?? 0,
                cursor: page.nextCursor));
      }
      // else: overlapped → merge into existing segments[0], oldest/cursor
      // unchanged (window extended the newest side only).
      _sort();
      try {
        _todos = await client.todos(sessionId);
      } catch (_) {}
      loaded = true;
      error = null;
      _stale = false;
      loading = false;
      unawaited(_saveCache());
    } catch (e) {
      AppLogger.I.e(_tag, 'reconcile failed $sessionId: $e');
      error = '$e';
      _stale = true;
      if (_messages.isEmpty) {
        await _loadCache();
      }
    } finally {
      _reconciling = false;
    }
    if (!_disposed) notifyListeners();
  }

  /// 上滚触顶懒加载一页（K 条更早消息）。每次只拉一页；断档多次则
  /// 多次触发。本页与 segments[1] 重叠时衔接（合并分段），否则更新
  /// segments[0] 的 oldest + cursor。失败静默（用户可再次上滚重试）。
  /// Returns true if progress was made (entries loaded or cursor exhausted),
  /// false on failure or no-op. The caller uses this to stop the lazy-load
  /// chain on failure (IR-1: prevents request storms when offline).
  Future<bool> loadOnePage() async {
    if (_loadingEarlier) return false;
    if (_segments.isEmpty) return false;
    final seg = _segments.first;
    if (seg.cursor == null) return false;
    _loadingEarlier = true;
    _loadEarlierError = false;
    notifyListeners();
    try {
      final page =
          await client.messagesPage(sessionId, limit: _kWindow, before: seg.cursor);
      final entries = page.entries;
      AppLogger.I.d(_tag,
          'loadOnePage fetched ${entries.length} older messages $sessionId hasCursor=${page.nextCursor != null}');
      if (entries.isEmpty) {
        seg.cursor = null; // history exhausted
      } else {
        _applyWindowDeletion(entries);
        _upsertEntries(entries);
        final pageOldestCreated = entries.first.info.created ?? 0;
        // Bridge loop (IR-R2): a page might span multiple segments if gaps
        // are small. Merge all overlapped segments into segments[0].
        var bridged = false;
        while (_segments.length >= 2 &&
            _entriesOverlapSegment(entries, 1)) {
          bridged = true;
          final seg1 = _segments[1];
          if (pageOldestCreated < seg1.oldestCreated) {
            seg
              ..oldestId = entries.first.info.id
              ..oldestCreated = pageOldestCreated
              ..cursor = page.nextCursor;
          } else {
            seg
              ..oldestId = seg1.oldestId
              ..oldestCreated = seg1.oldestCreated
              ..cursor = seg1.cursor;
          }
          _segments.removeAt(1);
        }
        if (bridged) {
          // Clean up orphan segments fully subsumed by the expanded
          // segments[0] (IR-R2): their oldestCreated >= seg.oldestCreated
          // means their entire range is within segments[0].
          _segments.removeWhere(
              (s) => s != seg && s.oldestCreated >= seg.oldestCreated);
        } else {
          seg
            ..oldestId = entries.first.info.id
            ..oldestCreated = pageOldestCreated
            ..cursor = page.nextCursor;
        }
      }
      _sort();
      unawaited(_saveCache());
      return true;
    } catch (e) {
      AppLogger.I.e(_tag, 'loadOnePage failed $sessionId: $e');
      _loadEarlierError = true;
      return false;
    } finally {
      _loadingEarlier = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// Upsert REST entries into `_messages` by id. Existing → replace info
  /// (REST authoritative) + field-level part merge. New → convert + insert.
  void _upsertEntries(List<MessageEntry> entries) {
    for (final e in entries) {
      final existing = _findMessage(e.info.id);
      if (existing != null) {
        _messages.remove(existing);
        final recreated = DisplayMessage(e.info);
        recreated.parts.addAll(_mergeParts(e.parts, existing.parts));
        _messages.add(recreated);
      } else {
        _messages.add(_toDisplay(e));
      }
    }
  }

  /// Window-range deletion (strict interior): remove local non-optimistic
  /// messages whose created falls strictly inside the fetched window's
  /// (oldest, newest) but whose id is not in the window — they were deleted
  /// server-side (revert). Boundaries excluded to avoid equal-created edges.
  void _applyWindowDeletion(List<MessageEntry> entries) {
    if (entries.length < 2) return;
    final lo = entries.first.info.created;
    final hi = entries.last.info.created;
    if (lo == null || hi == null || lo >= hi) return;
    final ids = {for (final e in entries) e.info.id};
    _messages.removeWhere((m) =>
        !m.optimistic &&
        m.info.created != null &&
        m.info.created! > lo &&
        m.info.created! < hi &&
        !ids.contains(m.info.id));
  }

  /// Whether any fetched entry id already exists in `_messages` (non-optimistic).
  /// Used to detect overlap / bridge before upsert inserts the entries.
  /// Build the set of non-optimistic message ids belonging to the segment
  /// at [segIndex]. Segments partition `_messages` (sorted ascending): the
  /// walk from newest→oldest crosses segment boundaries at each segment's
  /// `oldestId`. Optimistic messages are always in segments[0].
  Set<String> _segmentIds(int segIndex) {
    if (segIndex < 0 || segIndex >= _segments.length) return {};
    final ids = <String>{};
    var currentSeg = 0;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.optimistic) {
        if (currentSeg == segIndex) ids.add(m.info.id);
        if (currentSeg < _segments.length &&
            m.info.id == _segments[currentSeg].oldestId) {
          currentSeg++;
        }
      }
    }
    return ids;
  }

  /// Whether any fetched entry id exists in the segment at [segIndex].
  /// Segment-scoped: reconcile checks segments[0], loadOnePage bridge
  /// checks segments[1] (IR-2).
  bool _entriesOverlapSegment(List<MessageEntry> entries, int segIndex) {
    final ids = _segmentIds(segIndex);
    for (final e in entries) {
      if (ids.contains(e.info.id)) return true;
    }
    return false;
  }

  /// 字段级 part 并集。REST 定义顺序 + 字段合并，SSE-only 追加尾。
  /// text 取更长；tool 的 status/output/input 取 SSE 非空者、否则留 REST。
  /// hidden 类型跳过（与 `_toDisplay` 一致）。
  List<DisplayPart> _mergeParts(
      List<MessagePart> rest, List<DisplayPart> sse) {
    final result = <DisplayPart>[];
    final sseById = {for (final p in sse) p.id: p};
    final seen = <String>{};
    for (final rp in rest) {
      if (_hidden.contains(rp.type)) continue;
      final sp = sseById[rp.id];
      if (sp != null) {
        seen.add(rp.id);
        final merged = DisplayPart.from(rp);
        if (sp.text.length > merged.text.length) merged.text = sp.text;
        if (sp.toolStatus != null) merged.toolStatus = sp.toolStatus;
        if (sp.toolOutput != null) merged.toolOutput = sp.toolOutput;
        if (sp.toolError != null) merged.toolError = sp.toolError;
        if (sp.toolInput != null) merged.toolInput = sp.toolInput;
        result.add(merged);
      } else {
        result.add(DisplayPart.from(rp));
      }
    }
    for (final sp in sse) {
      if (_hidden.contains(sp.type)) continue;
      if (!seen.contains(sp.id)) result.add(sp);
    }
    return result;
  }

  /// Force refresh (re-entrant safe). Delegates to [reconcile] (merge, no
  /// clear). Used by manual refresh + watchdog reconnect.
  Future<void> reload() async => reconcile();

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
                            'toolError': p.toolError,
                            'toolInput': p.toolInput, // MA-5: 补存
                          })
                      .toList(),
                })
            .toList(),
        'todos': _todos.map((t) => t.toJson()).toList(),
        'segments': _segments
            .map((s) => {
                  'oldestId': s.oldestId,
                  'oldestCreated': s.oldestCreated,
                  'cursor': s.cursor,
                })
            .toList(),
        'cachedSessionUpdated': sessionUpdated,
      };
      await prefs.setString(_cacheKey, jsonEncode(j));
    } catch (_) {}
  }

  Future<void> _loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      // MA-2: 若 async gap 期间已有 SSE 累积，不再用陈旧缓存覆盖。
      if (_messages.isNotEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      _loadCacheFromJson(j);
    } catch (_) {}
  }

  /// Restore `_messages` + `_segments` + `_todos` from a cache JSON map.
  /// Does NOT check the MA-2 guard (caller is responsible). Used by both
  /// offline fallback ([_loadCache]) and online preheat ([_maybePreheatCache]).
  void _loadCacheFromJson(Map<String, dynamic> j) {
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
          toolError: p2['toolError']?.toString(),
          toolInput: p2['toolInput'] is Map
              ? (p2['toolInput'] as Map).cast<String, dynamic>()
              : null, // MA-5: 补读 toolInput
        ));
      }
      _messages.add(dm);
    }
    final todos = j['todos'] as List? ?? [];
    _todos = todos
        .map((t) => Todo.fromJson((t as Map).cast<String, dynamic>()))
        .toList();
    final segs = j['segments'] as List? ?? [];
    _segments.clear();
    for (final s in segs) {
      final s2 = s as Map<String, dynamic>;
      _segments.add(_Segment(
        oldestId: s2['oldestId']?.toString() ?? '',
        oldestCreated: (s2['oldestCreated'] as num?)?.toInt() ?? 0,
        cursor: s2['cursor']?.toString(),
      ));
    }
    if (_messages.isNotEmpty) loaded = true;
  }

  /// Cache preheat: if `sessionUpdated` matches the cached value (no new
  /// messages since cache), restore cache instantly before reconcile. Avoids
  /// the loading spinner on restart when the session is unchanged. The
  /// subsequent reconcile will overlap-merge (no gap, no flash).
  Future<void> _maybePreheatCache() async {
    if (sessionUpdated == null || _messages.isNotEmpty || loaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final cached = j['cachedSessionUpdated'];
      if (cached != null && cached == sessionUpdated) {
        _loadCacheFromJson(j);
        if (_messages.isNotEmpty && !_disposed) notifyListeners();
      }
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

  void setStatus(String s, {String? retryMessage}) {
    final prevStatus = status;
    final prevRetry = this.retryMessage;
    status = s;
    if (s == 'retry') {
      // Preserve the last non-empty message across consecutive retry events:
      // the server may omit `message` on later attempts, but the session is
      // still retrying so the banner must not flicker off.
      final next = (retryMessage != null && retryMessage.isNotEmpty)
          ? retryMessage
          : prevRetry;
      this.retryMessage = next;
    } else {
      this.retryMessage = null;
    }
    if (prevStatus != status || prevRetry != this.retryMessage) {
      if (!_disposed) notifyListeners();
    }
  }

  void onSessionError(Map<String, dynamic> error) {
    sessionError = error;
    if (!_disposed) notifyListeners();
  }

  void clearSessionError() {
    if (sessionError == null) return;
    sessionError = null;
    if (!_disposed) notifyListeners();
  }

  void onMessageUpdated(MessageInfo info) {
    // When a real user message arrives from SSE, prune optimistic user
    // messages (the authoritative one replaces the local guess).
    if (info.role == 'user') {
      _pruneOptimistic();
      sessionError = null;
    }
    final existing = _findMessage(info.id);
    if (existing != null) {
      _messages.remove(existing);
      // Preserve retry error from existing message if the new info lacks one.
      // A retry part may arrive before message.updated, setting the error;
      // the subsequent message.updated would otherwise overwrite it to null.
      final resolvedInfo = (info.error == null && existing.info.error != null)
          ? MessageInfo(
              id: info.id,
              role: info.role,
              sessionID: info.sessionID,
              created: info.created,
              completed: info.completed,
              cost: info.cost,
              modelID: info.modelID,
              finish: info.finish,
              error: existing.info.error,
            )
          : info;
      final recreated = DisplayMessage(resolvedInfo);
      recreated.parts.addAll(existing.parts);
      _messages.add(recreated);
    } else {
      _messages.add(DisplayMessage(info));
    }
    _sort();
    AppLogger.I.d(_tag, 'onMessageUpdated id=${info.id} role=${info.role} created=${info.created} finish=${info.finish} → last=${_messages.last.info.id}(${_messages.last.info.role})');
    // 消息完成即异步落盘（off-screen conv 也覆盖，因 ensureConversation 会
    // 创建 conv）。非 per-token，频率低。
    if (info.role == 'user' || (info.finish != null && info.finish!.isNotEmpty)) {
      unawaited(_saveCache());
    }
    notifyListeners();
  }

  void onPartUpdated(Map<String, dynamic> partRaw, String? delta) {
    final p = MessagePart(partRaw);
    final mid = p.raw['messageID']?.toString();
    if (mid == null) return;
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    // Retry parts carry the API error but are hidden from the parts list.
    // Propagate the error to the parent message so the UI can display it.
    if (p.type == 'retry') {
      final retryError = p.raw['error'];
      if (retryError is Map && retryError.isNotEmpty && msg.info.error == null) {
        final old = msg.info;
        final newInfo = MessageInfo(
          id: old.id,
          role: old.role,
          sessionID: old.sessionID,
          created: old.created,
          completed: old.completed,
          cost: old.cost,
          modelID: old.modelID,
          finish: old.finish,
          error: retryError.cast<String, dynamic>(),
        );
        _messages.remove(msg);
        final newMsg = DisplayMessage(newInfo, optimistic: msg.optimistic);
        newMsg.parts.addAll(msg.parts);
        _messages.add(newMsg);
        _sort();
        notifyListeners();
      }
      return;
    }
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
        final toolError = _extractToolError(p.state?['error']);
        if (toolError != null) dp.toolError = toolError;
        if (p.state?['input'] is Map) {
          dp.toolInput = (p.state!['input'] as Map).cast<String, dynamic>();
        }
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
    AppLogger.I.i(_tag, 'onPermission pid=${p.id} sid=${p.sessionID} op=${idx == -1 ? "add" : "replace"} → count=${_permissions.length}');
    notifyListeners();
  }

  void onPermissionReplied(String permissionId) {
    AppLogger.I.i(_tag, 'onPermissionReplied pid=$permissionId → removed, count was=${_permissions.length}');
    _permissions.removeWhere((p) => p.id == permissionId);
    notifyListeners();
  }

  Future<void> respondPermission(Permission p, String response) async {
    AppLogger.I.i(_tag, 'respondPermission sid=$sessionId pid=${p.id} resp=$response dir=$directory');
    try {
      await client.respondPermission(sessionId, p.id, response);
      AppLogger.I.i(_tag, 'respondPermission POST ok pid=${p.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      AppLogger.I.e(_tag, 'respondPermission POST err pid=${p.id} status=$code body=${e.response?.data}');
      // 404 = already resolved (e.g. accepted on another device) — remove locally.
      if (code != 404) rethrow;
    }
    onPermissionResolved?.call(p.id);
    onPermissionReplied(p.id);
  }

  void onQuestion(QuestionRequest q) {
    final idx = _questions.indexWhere((x) => x.id == q.id);
    if (idx == -1) {
      _questions.add(q);
    } else {
      _questions[idx] = q;
    }
    AppLogger.I.i(_tag, 'onQuestion qid=${q.id} sid=${q.sessionID} op=${idx == -1 ? "add" : "replace"} → count=${_questions.length}');
    notifyListeners();
  }

  void onQuestionReplied(String questionId) {
    AppLogger.I.i(_tag, 'onQuestionReplied qid=$questionId → removed, count was=${_questions.length}');
    _questions.removeWhere((q) => q.id == questionId);
    notifyListeners();
  }

  Future<void> replyQuestion(QuestionRequest q, List<List<String>> answers) async {
    if (directory.isEmpty) {
      AppLogger.I.w(_tag, 'replyQuestion aborted: directory not ready qid=${q.id} sid=$sessionId');
      // 不发请求、不移除卡片；UI catch 弹 SnackBar，待 session 加载后重试。
      throw StateError('会话信息尚未加载完成，请稍后重试');
    }
    AppLogger.I.i(_tag, 'replyQuestion sid=$sessionId qid=${q.id} dir=$directory answers=$answers');
    try {
      await client.replyQuestion(q.id, directory, answers);
      AppLogger.I.i(_tag, 'replyQuestion POST ok qid=${q.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      AppLogger.I.e(_tag, 'replyQuestion POST err qid=${q.id} status=$code body=${e.response?.data}');
      if (code != 404) rethrow;
      AppLogger.I.i(_tag, 'replyQuestion 404 swallowed qid=${q.id}');
    }
    onQuestionResolved?.call(q.id);
    onQuestionReplied(q.id);
  }

  Future<void> rejectQuestion(QuestionRequest q) async {
    if (directory.isEmpty) {
      AppLogger.I.w(_tag, 'rejectQuestion aborted: directory not ready qid=${q.id} sid=$sessionId');
      throw StateError('会话信息尚未加载完成，请稍后重试');
    }
    AppLogger.I.i(_tag, 'rejectQuestion sid=$sessionId qid=${q.id} dir=$directory');
    try {
      await client.rejectQuestion(q.id, directory);
      AppLogger.I.i(_tag, 'rejectQuestion POST ok qid=${q.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      AppLogger.I.e(_tag, 'rejectQuestion POST err qid=${q.id} status=$code body=${e.response?.data}');
      if (code != 404) rethrow;
      AppLogger.I.i(_tag, 'rejectQuestion 404 swallowed qid=${q.id}');
    }
    onQuestionResolved?.call(q.id);
    onQuestionReplied(q.id);
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
    // Placeholder must sort after all existing messages: lastMessagePreview()
    // reads _messages.last, so the streaming assistant must be last. Don't use
    // DateTime.now() (client clock) — it can sort before a server-stamped user
    // message when the client lags the server, jumping the preview back to the
    // user message (design §1.6). message.updated later replaces this with the
    // server created, which always sorts after the user (server clock).
    final maxCreated = _messages.fold<int>(0, (a, m) {
      final c = m.info.created ?? 0;
      return c > a ? c : a;
    });
    final m = DisplayMessage(MessageInfo(
      id: id,
      role: 'assistant',
      created: maxCreated + 1,
    ));
    _messages.add(m);
    _sort();
    AppLogger.I.d(_tag, '_ensureMessage id=$id created=${maxCreated + 1} → last=${_messages.last.info.id}(${_messages.last.info.role})');
    return m;
  }

  void _sort() {
    _messages.sort((a, b) => (a.info.created ?? 0).compareTo(b.info.created ?? 0));
  }

  @visibleForTesting
  Future<void> saveCacheForTest() async => _saveCache();

  @visibleForTesting
  Future<void> loadCacheForTest() async => _loadCache();
}
