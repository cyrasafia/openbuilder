import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../data/api/opencode_client.dart';
import '../../../domain/models.dart';
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
  Map<String, dynamic>? toolInput;

  DisplayPart({
    required this.id,
    required this.type,
    this.tool,
    this.text = '',
    this.toolStatus,
    this.toolOutput,
    this.toolInput,
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
        toolInput: p.state?['input'] is Map
            ? (p.state!['input'] as Map).cast<String, dynamic>()
            : null,
      );
    }
    return DisplayPart(id: p.id, type: p.type, text: p.text ?? '');
  }
}

class DisplayMessage {
  final MessageInfo info;
  final List<DisplayPart> parts = [];
  bool optimistic; // true for locally-inserted user messages pending server confirm
  DisplayMessage(this.info, {this.optimistic = false});
}

/// Per-session live state: messages (streaming), todos, permissions.
class ConversationStore extends ChangeNotifier {
  final String sessionId;
  final OpencodeClient client;

  ConversationStore(this.sessionId, this.client);

  final List<DisplayMessage> _messages = [];
  List<Todo> _todos = [];
  final List<Permission> _permissions = [];
  final List<QuestionRequest> _questions = [];
  bool loading = false;
  bool loaded = false;
  String? error;
  Map<String, dynamic>? sessionError;
  String status = 'idle';

  bool _stale = false;
  bool _reconciling = false;
  DateTime? _lastReloadAt;
  static const _reloadBackoff = Duration(seconds: 10);

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
      final pv = dp.type == 'tool'
          ? dp.toolSummary
          : dp.text.replaceAll('\n', ' ').trim();
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
  void addOptimisticUserMessage(String text) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = DisplayMessage(
      MessageInfo(id: 'optimistic_$now', role: 'user', created: now),
      optimistic: true,
    );
    msg.parts.add(DisplayPart(
      id: 'optimistic_part_$now',
      type: 'text',
      text: text,
    ));
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

  /// 对账合并：拉 REST 权威历史，与 SSE 累积的 `_messages` 按 id 做 part 级
  /// 并集合并（不 clear），消除清空竞争。失败回退：`_messages` 空才
  /// `_loadCache`，否则保 SSE 累积并标 stale。
  Future<void> reconcile() async {
    if (_reconciling) return; // 互斥
    _reconciling = true;
    _lastReloadAt = DateTime.now();
    AppLogger.I.d(_tag, 'reconcile start $sessionId');
    try {
      final entries = await client.messages(sessionId);
      AppLogger.I.d(_tag, 'reconcile fetched ${entries.length} messages $sessionId');
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
      // 1. 索引：REST 按 id、当前 SSE 累积按 id（跳过 optimistic）
      final restById = {for (final e in entries) e.info.id: e};
      final sseById = <String, DisplayMessage>{
        for (final m in _messages) if (!m.optimistic) m.info.id: m
      };
      // 2. REST 定义历史 + 顺序；同时存在则字段级合并 parts
      final result = <DisplayMessage>[];
      for (final e in entries) {
        final sse = sseById[e.info.id];
        if (sse != null && sse.parts.isNotEmpty) {
          final merged = DisplayMessage(e.info);
          merged.parts.addAll(_mergeParts(e.parts, sse.parts));
          result.add(merged);
        } else {
          result.add(_toDisplay(e));
        }
      }
      // 3. 追加 SSE-only（订阅后新建、REST 快照还没有的消息）
      for (final m in _messages) {
        if (m.optimistic) continue;
        if (!restById.containsKey(m.info.id)) result.add(m);
      }
      _messages
        ..clear()
        ..addAll(result);
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
      // Set error so first-load failure surfaces in the UI ("加载失败");
      // background reconcile failures on a conv with messages stay hidden
      // (UI gates on messages.isEmpty) and clear on next success.
      error = '$e';
      _stale = true;
      // Only restore from cache if we have no data at all — if SSE has been
      // delivering messages (_messages is non-empty), that data is always more
      // current than the cache. Overwriting it with stale cache causes data
      // loss when switching sessions on flaky networks.
      if (_messages.isEmpty) {
        await _loadCache();
      }
      // 否则保留 SSE 累积，标 stale 下次重试
    } finally {
      _reconciling = false;
    }
    if (!_disposed) notifyListeners();
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
                            'toolInput': p.toolInput, // MA-5: 补存
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
      // MA-2: 若 async gap 期间已有 SSE 累积，不再用陈旧缓存覆盖。
      if (_messages.isNotEmpty) return;
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
    if (!_disposed) notifyListeners();
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
      final recreated = DisplayMessage(info);
      recreated.parts.addAll(existing.parts);
      _messages.add(recreated);
    } else {
      _messages.add(DisplayMessage(info));
    }
    _sort();
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
    notifyListeners();
  }

  void onPermissionReplied(String permissionId) {
    _permissions.removeWhere((p) => p.id == permissionId);
    notifyListeners();
  }

  Future<void> respondPermission(Permission p, String response) async {
    try {
      await client.respondPermission(sessionId, p.id, response);
    } on DioException catch (e) {
      // 404 = already resolved (e.g. accepted on another device) — remove locally.
      if (e.response?.statusCode != 404) rethrow;
    }
    onPermissionReplied(p.id);
  }

  void onQuestion(QuestionRequest q) {
    final idx = _questions.indexWhere((x) => x.id == q.id);
    if (idx == -1) {
      _questions.add(q);
    } else {
      _questions[idx] = q;
    }
    notifyListeners();
  }

  void onQuestionReplied(String questionId) {
    _questions.removeWhere((q) => q.id == questionId);
    notifyListeners();
  }

  Future<void> replyQuestion(QuestionRequest q, List<List<String>> answers) async {
    try {
      await client.replyQuestion(q.id, answers);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
    }
    onQuestionReplied(q.id);
  }

  Future<void> rejectQuestion(QuestionRequest q) async {
    try {
      await client.rejectQuestion(q.id);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
    }
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
    return m;
  }

  void _sort() {
    _messages.sort((a, b) => (a.info.created ?? 0).compareTo(b.info.created ?? 0));
  }
}
