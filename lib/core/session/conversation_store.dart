import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../data/api/opencode_client.dart';
import '../../../domain/models.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../attachments/attachment_pipeline.dart';
import '../attachments/file_ref.dart';
import '../cache/cache_store.dart';
import '../logging/app_logger.dart';
import '../logging/perf_probe.dart';
import '../net/net_error.dart';

const _tag = 'Conv';

class DisplayPart {
  final String id;
  final String type; // text | reasoning | tool | file
  String? tool;
  String text;
  String? toolStatus;
  String? toolTitle;
  String? toolOutput;
  String? toolError;
  Map<String, dynamic>? toolInput;
  Map<String, dynamic>? toolMetadata;
  String? fileMime;
  String? fileUrl;
  String? filename;
  String? command;
  Uint8List? previewThumb;
  Map<String, dynamic>? source;

  DisplayPart({
    required this.id,
    required this.type,
    this.tool,
    this.text = '',
    this.toolStatus,
    this.toolTitle,
    this.toolOutput,
    this.toolError,
    this.toolInput,
    this.toolMetadata,
    this.fileMime,
    this.fileUrl,
    this.filename,
    this.command,
    this.previewThumb,
    this.source,
  });

  String get toolSummary {
    if (tool == null) return '';
    final input = toolInput;
    if (input == null || input.isEmpty) return tool!;
    switch (tool) {
      case 'bash':
      case 'shell':
      case 'execute':
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
}

String? _toolContentText(List<ToolContentItem> content) {
  final buf = StringBuffer();
  for (final c in content) {
    if (c.text.isNotEmpty) buf.write(c.text);
  }
  final s = buf.toString();
  return s.isEmpty ? null : s;
}

class DisplayMessage {
  final String id;
  final String type; // v2 kind: user | assistant | system | synthetic | skill | shell | compaction | idle | agent-switched | model-switched | location-switched
  bool optimistic;
  final List<DisplayPart> parts = [];
  int created;
  int? completed;
  String? agent;
  String? modelID;
  String? modelProvider;
  String? finish;
  double cost;
  Map<String, dynamic>? error;
  String? text;
  String? description;
  String? shellCommand;
  String? shellStatus;
  String? shellOutput;
  int? shellExit;
  String? outcome;
  String? compactionStatus;
  String? previousLabel;
  String? currentLabel;

  DisplayMessage({
    required this.id,
    required this.type,
    this.optimistic = false,
    required this.created,
    this.completed,
    this.agent,
    this.modelID,
    this.modelProvider,
    this.finish,
    this.cost = 0,
    this.error,
    this.text,
    this.description,
    this.shellCommand,
    this.shellStatus,
    this.shellOutput,
    this.shellExit,
    this.outcome,
    this.compactionStatus,
    this.previousLabel,
    this.currentLabel,
  });

  bool get isUser => type == 'user';
  bool get isAssistant => type == 'assistant';
}

class _Segment {
  String oldestId;
  int oldestCreated;
  String? cursor;
  _Segment({required this.oldestId, required this.oldestCreated, this.cursor});
}

class ConversationStore extends ChangeNotifier {
  final String sessionId;
  final OpencodeClient client;

  String directory;

  void Function(String formId)? onQuestionResolved;
  void Function(String permissionId)? onPermissionResolved;

  final CacheStore? cacheStore;

  ConversationStore(this.sessionId, this.client,
      {this.directory = '', this.cacheStore});

  void setDirectory(String dir) {
    if (dir.isNotEmpty && directory.isEmpty) {
      directory = dir;
    }
  }

  final List<DisplayMessage> _messages = [];
  final List<_Segment> _segments = [];
  List<Todo> _todos = [];
  final List<Permission> _permissions = [];
  final List<FormInfo> _forms = [];
  bool loading = false;
  bool loaded = false;
  Object? error;
  String status = 'idle';
  String? retryMessage;
  bool workspaceMissing = false;
  int? sessionUpdated;
  bool _loadingEarlier = false;
  bool _loadEarlierError = false;

  bool _stale = false;
  bool _reconciling = false;
  DateTime? _lastReloadAt;
  static const _reloadBackoff = Duration(seconds: 10);
  static const _kWindow = 100;

  Timer? _loadRetryTimer;
  int _loadRetryAttempt = 0;
  bool _disposed = false;
  Future<void> Function()? _backfillCallback;

  String _draftText = '';
  bool _draftShell = false;
  bool _draftLoaded = false;
  String get draftText => _draftText;
  bool get draftShell => _draftShell;
  bool get draftLoaded => _draftLoaded;

  void setBackfillCallback(Future<void> Function()? cb) => _backfillCallback = cb;
  static const _loadInitialBackoff = Duration(seconds: 2);
  static const _loadMaxBackoff = Duration(seconds: 30);

  List<DisplayMessage> get messages => List.unmodifiable(_messages);
  List<Todo> get todos => List.unmodifiable(_todos);
  List<Permission> get permissions => List.unmodifiable(_permissions);
  List<FormInfo> get forms => List.unmodifiable(_forms);
  bool get busy => status == 'busy' || status == 'retry';
  bool get isRetry => status == 'retry';

  int _messagesVersion = 0;
  int _renderableVersion = -1;
  List<DisplayMessage> _renderableCache = const [];

  bool _fullInvalidationPending = false;
  final Set<String> _contentInvalidations = {};

  void _touchMessages([Set<String>? changedIds]) {
    _messagesVersion++;
    if (changedIds == null) {
      _fullInvalidationPending = true;
      _contentInvalidations.clear();
    } else if (!_fullInvalidationPending) {
      _contentInvalidations.addAll(changedIds);
    }
  }

  Set<String>? consumeContentInvalidations() {
    if (_fullInvalidationPending) {
      _fullInvalidationPending = false;
      _contentInvalidations.clear();
      return null;
    }
    if (_contentInvalidations.isEmpty) return const <String>{};
    final s = Set.of(_contentInvalidations);
    _contentInvalidations.clear();
    return s;
  }

  int get messagesVersion => _messagesVersion;

  static const _hiddenKinds = {
    'idle',
    'compaction',
    'location-switched',
  };

  List<DisplayMessage> get renderableMessages {
    if (_renderableVersion == _messagesVersion) return _renderableCache;
    final List<DisplayMessage> result;
    if (_segments.isEmpty) {
      result = _messages.reversed
          .where((m) => !_isEmptyUser(m) && !_hiddenKinds.contains(m.type))
          .toList(growable: false);
    } else {
      final seg = _segments.first;
      final list = <DisplayMessage>[];
      for (var i = _messages.length - 1; i >= 0; i--) {
        final m = _messages[i];
        if (!_isEmptyUser(m) && !_hiddenKinds.contains(m.type)) list.add(m);
        if (m.id == seg.oldestId) break;
      }
      result = list;
    }
    _renderableCache = result;
    _renderableVersion = _messagesVersion;
    return result;
  }

  bool get hasMore => _segments.firstOrNull?.cursor != null;

  bool get loadingEarlier => _loadingEarlier;

  bool get loadEarlierError => _loadEarlierError;

  String? lastMessagePreview({bool hideReasoning = false, AppLocalizations? loc}) {
    if (_messages.isEmpty) return null;
    DisplayMessage? last;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (_hiddenKinds.contains(m.type)) continue;
      if (m.type == 'idle') continue;
      last = m;
      break;
    }
    if (last == null) return null;
    var preview = '';
    if (last.type == 'user' || last.type == 'assistant') {
      for (var i = last.parts.length - 1; i >= 0; i--) {
        final dp = last.parts[i];
        if (hideReasoning && dp.type == 'reasoning') continue;
        String pv;
        if (dp.type == 'tool') {
          pv = dp.toolSummary;
        } else if (dp.type == 'file') {
          final name = dp.filename ?? '';
          pv = name.isNotEmpty ? name : (loc?.attachmentFallback ?? '');
        } else if (dp.type == 'text' || dp.type == 'reasoning') {
          pv = dp.text.replaceAll('\n', ' ').trim();
        } else {
          continue;
        }
        if (pv.isNotEmpty) {
          preview = pv;
          break;
        }
      }
    } else {
      preview = (last.text ?? last.shellCommand ?? last.description ?? '')
          .replaceAll('\n', ' ')
          .trim();
    }
    if (preview.isEmpty) return null;
    final prefix = last.type == 'user' ? (loc?.previewYouPrefix ?? '') : '';
    return prefix + preview;
  }

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

  void addOptimisticUserMessage(String text,
      {List<AttachmentPreview>? attachments, List<FileRef>? fileRefs}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final msg = DisplayMessage(
      id: 'optimistic_$now',
      type: 'user',
      optimistic: true,
      created: now,
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
    if (fileRefs != null) {
      var i = 0;
      for (final r in fileRefs) {
        msg.parts.add(DisplayPart(
          id: 'optimistic_ref_${now}_$i',
          type: 'file',
          filename: r.filename,
          fileUrl: 'file://${r.absolute}',
          source: {
            'type': 'file',
            'path': r.path,
            'text': {'value': '', 'start': 0, 'end': 0},
          },
        ));
        i++;
      }
    }
    _messages.add(msg);
    _sort(const <String>{});
    notifyListeners();
  }

  void _pruneOptimistic() {
    _touchMessages(const <String>{});
    _messages.removeWhere((m) => m.optimistic);
  }

  void removeOptimisticMessages() {
    final had = _messages.any((m) => m.optimistic);
    _pruneOptimistic();
    if (had) notifyListeners();
  }

  static const optimisticPartPrefix = 'optimistic_';

  static bool _isPlaceholderPart(DisplayPart p) =>
      p.id.startsWith(optimisticPartPrefix);

  DisplayMessage? _firstOptimisticUser() {
    for (var i = 0; i < _messages.length; i++) {
      final m = _messages[i];
      if (m.optimistic && m.type == 'user') return m;
    }
    return null;
  }

  void _bridgeOptimisticParts(DisplayMessage m, List<DisplayPart> optParts) {
    if (optParts.isEmpty) return;
    final realByType = <String, int>{};
    for (final p in m.parts) {
      if (!_isPlaceholderPart(p)) {
        realByType[p.type] = (realByType[p.type] ?? 0) + 1;
      }
    }
    final covered = <String, int>{};
    for (final op in optParts) {
      final real = realByType[op.type] ?? 0;
      final seen = covered[op.type] ?? 0;
      if (seen < real) {
        covered[op.type] = seen + 1;
        continue;
      }
      if (!m.parts.any((p) => p.id == op.id)) m.parts.add(op);
    }
  }

  Future<void> reloadIfStale() async {
    if (!_stale || _reconciling || loading) return;
    if (_lastReloadAt != null &&
        DateTime.now().difference(_lastReloadAt!) < _reloadBackoff) {
      return;
    }
    await reload();
  }

  static bool _isEmptyUser(DisplayMessage m) {
    if (m.optimistic || m.type != 'user') return false;
    for (final p in m.parts) {
      if (p.type == 'file') return false;
      if (p.type == 'text' && p.text.trim().isNotEmpty) return false;
    }
    return true;
  }

  Future<void> load() async {
    if (loaded || loading) return;
    loading = true;
    notifyListeners();
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

  Future<void> reconcile() async {
    if (_reconciling) return;
    _reconciling = true;
    _lastReloadAt = DateTime.now();
    PerfProbe.I.markEvent('reconcile-start $sessionId');
    AppLogger.I.d(_tag, 'reconcile start $sessionId');
    try {
      final page = await client.messagesPageCompute(sessionId, limit: _kWindow);
      final entries = page.entries;
      AppLogger.I.d(_tag,
          'reconcile fetched ${entries.length} messages $sessionId hasCursor=${page.olderCursor != null}');
      if (entries.isNotEmpty) {
        final last = entries.last;
        if (last is IdleMessage) {
          setStatus('idle');
        } else if (last is AssistantMessage &&
            (last.finish == 'stop' || last.finish == 'error')) {
          setStatus('idle');
        }
      }
      final overlapped = _entriesOverlapSegment(entries, 0);
      _applyWindowDeletion(entries);
      _upsertEntries(entries);
      if (entries.isEmpty) {
      } else if (_segments.isEmpty || !overlapped) {
        final oldest = entries.first;
        _segments.insert(
            0,
            _Segment(
                oldestId: oldest.id,
                oldestCreated: oldest.created,
                cursor: page.olderCursor));
      }
      _sort(const <String>{});
      _recomputeTodos();
      loaded = true;
      error = null;
      _stale = false;
      loading = false;
      unawaited(_saveCache());
    } catch (e) {
      AppLogger.I.e(_tag, 'reconcile failed $sessionId: $e');
      error = e;
      _stale = true;
      if (_messages.isEmpty) {
        await _loadCache();
      }
    } finally {
      _reconciling = false;
    }
    PerfProbe.I.markEvent('reconcile-done $sessionId');
    if (!_disposed) notifyListeners();
  }

  Future<bool> loadOnePage() async {
    if (_loadingEarlier) return false;
    if (_segments.isEmpty) return false;
    final seg = _segments.first;
    if (seg.cursor == null) return false;
    _loadingEarlier = true;
    _loadEarlierError = false;
    notifyListeners();
    try {
      final page = await client.messagesPageCompute(
          sessionId, limit: _kWindow, cursor: seg.cursor);
      final entries = page.entries;
      AppLogger.I.d(_tag,
          'loadOnePage fetched ${entries.length} older messages $sessionId hasCursor=${page.olderCursor != null}');
      if (entries.isEmpty) {
        seg.cursor = null;
      } else {
        _applyWindowDeletion(entries);
        _upsertEntries(entries);
        final pageOldestCreated = entries.first.created;
        var bridged = false;
        while (_segments.length >= 2 &&
            _entriesOverlapSegment(entries, 1)) {
          bridged = true;
          final seg1 = _segments[1];
          if (pageOldestCreated < seg1.oldestCreated) {
            seg
              ..oldestId = entries.first.id
              ..oldestCreated = pageOldestCreated
              ..cursor = page.olderCursor;
          } else {
            seg
              ..oldestId = seg1.oldestId
              ..oldestCreated = seg1.oldestCreated
              ..cursor = seg1.cursor;
          }
          _segments.removeAt(1);
        }
        if (bridged) {
          _segments.removeWhere(
              (s) => s != seg && s.oldestCreated >= seg.oldestCreated);
        } else {
          seg
            ..oldestId = entries.first.id
            ..oldestCreated = pageOldestCreated
            ..cursor = page.olderCursor;
        }
      }
      _sort(const <String>{});
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

  void _upsertEntries(List<SessionMessage> entries) {
    if (entries.isEmpty) return;
    final changed = <String>{};
    for (final e in entries) {
      final existing = _findMessage(e.id);
      if (existing != null) {
        _messages.remove(existing);
        final recreated = _toDisplay(e);
        if (recreated == null) continue;
        recreated.parts.addAll(_mergeParts(recreated.parts, existing.parts));
        if (_isEmptyUser(recreated)) continue;
        _messages.add(recreated);
        if (!_sameMessage(existing, recreated)) {
          changed.add(e.id);
        }
      } else {
        final d = _toDisplay(e);
        if (d == null) continue;
        if (_isEmptyUser(d)) continue;
        if (e is UserMessage) _replaceOldestOptimisticUser(d);
        _messages.add(d);
        changed.add(e.id);
      }
    }
    _touchMessages(changed);
  }

  void _replaceOldestOptimisticUser(DisplayMessage authoritative) {
    final opt = _firstOptimisticUser();
    if (opt == null) return;
    _bridgeOptimisticParts(authoritative, List<DisplayPart>.of(opt.parts));
    _messages.remove(opt);
  }

  void _applyWindowDeletion(List<SessionMessage> entries) {
    if (entries.length < 2) return;
    final lo = entries.first.created;
    final hi = entries.last.created;
    if (lo >= hi) return;
    final ids = {for (final e in entries) e.id};
    _touchMessages(const <String>{});
    _messages.removeWhere((m) =>
        !m.optimistic &&
        m.created > lo &&
        m.created < hi &&
        !ids.contains(m.id));
  }

  static bool _sameMessage(DisplayMessage a, DisplayMessage b) =>
      a.id == b.id &&
      a.type == b.type &&
      a.created == b.created &&
      a.completed == b.completed &&
      a.cost == b.cost &&
      a.modelID == b.modelID &&
      a.finish == b.finish &&
      mapEquals(a.error, b.error) &&
      a.text == b.text &&
      _sameParts(a.parts, b.parts);

  static bool _samePart(DisplayPart a, DisplayPart b) =>
      a.id == b.id &&
      a.type == b.type &&
      a.tool == b.tool &&
      a.text == b.text &&
      a.toolStatus == b.toolStatus &&
      a.toolOutput == b.toolOutput &&
      a.toolError == b.toolError &&
      mapEquals(a.toolInput, b.toolInput) &&
      a.command == b.command &&
      a.fileMime == b.fileMime &&
      a.fileUrl == b.fileUrl &&
      a.filename == b.filename &&
      mapEquals(a.source, b.source);

  static bool _sameParts(List<DisplayPart> a, List<DisplayPart> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_samePart(a[i], b[i])) return false;
    }
    return true;
  }

  Set<String> _segmentIds(int segIndex) {
    if (segIndex < 0 || segIndex >= _segments.length) return {};
    final ids = <String>{};
    var currentSeg = 0;
    for (var i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (!m.optimistic) {
        if (currentSeg == segIndex) ids.add(m.id);
        if (currentSeg < _segments.length &&
            m.id == _segments[currentSeg].oldestId) {
          currentSeg++;
        }
      }
    }
    return ids;
  }

  bool _entriesOverlapSegment(List<SessionMessage> entries, int segIndex) {
    final ids = _segmentIds(segIndex);
    for (final e in entries) {
      if (ids.contains(e.id)) return true;
    }
    return false;
  }

  List<DisplayPart> _mergeParts(
      List<DisplayPart> rest, List<DisplayPart> sse) {
    final result = <DisplayPart>[];
    final sseById = {for (final p in sse) p.id: p};
    final seen = <String>{};
    for (final rp in rest) {
      final sp = sseById[rp.id];
      if (sp != null) {
        seen.add(rp.id);
        final merged = _clonePart(rp);
        if (sp.text.length > merged.text.length) merged.text = sp.text;
        if (sp.toolStatus != null) merged.toolStatus = sp.toolStatus;
        if (sp.toolTitle != null) merged.toolTitle = sp.toolTitle;
        if (sp.toolOutput != null) merged.toolOutput = sp.toolOutput;
        if (sp.toolError != null) merged.toolError = sp.toolError;
        if (sp.toolInput != null) merged.toolInput = sp.toolInput;
        if (sp.toolMetadata != null) merged.toolMetadata = sp.toolMetadata;
        result.add(merged);
      } else {
        result.add(rp);
      }
    }
    for (final sp in sse) {
      if (seen.contains(sp.id)) continue;
      if (_isPlaceholderPart(sp) &&
          result.any((r) => r.type == sp.type && !_isPlaceholderPart(r))) {
        continue;
      }
      result.add(sp);
    }
    return result;
  }

  static DisplayPart _clonePart(DisplayPart p) => DisplayPart(
        id: p.id,
        type: p.type,
        tool: p.tool,
        text: p.text,
        toolStatus: p.toolStatus,
        toolTitle: p.toolTitle,
        toolOutput: p.toolOutput,
        toolError: p.toolError,
        toolInput: p.toolInput,
        toolMetadata: p.toolMetadata,
        fileMime: p.fileMime,
        fileUrl: p.fileUrl,
        filename: p.filename,
        command: p.command,
        previewThumb: p.previewThumb,
        source: p.source,
      );

  Future<void> reload() async => reconcile();

  String get _cacheKey => 'conv/$sessionId';

  Future<void> _saveCache() async {
    final cs = cacheStore;
    if (cs == null) return;
    try {
      final j = {
        'v': 2,
        'messages': _messages
            .map((m) => _messageToJson(m))
            .toList(),
        'segments': _segments
            .map((s) => {
                  'oldestId': s.oldestId,
                  'oldestCreated': s.oldestCreated,
                  'cursor': s.cursor,
                })
            .toList(),
        'cachedSessionUpdated': sessionUpdated,
        'draft': _draftText,
        'draftShell': _draftShell,
      };
      final encoded = await compute(jsonEncode, j);
      await cs.write(_cacheKey, encoded);
    } catch (e) {
      AppLogger.I.e(_tag, 'saveCache failed: $e');
    }
  }

  Map<String, dynamic> _messageToJson(DisplayMessage m) {
    if (m.optimistic) {
      return {
        'id': m.id,
        'type': 'user',
        'time': {'created': m.created},
        'text': '',
        'optimistic': true,
      };
    }
    final raw = <String, dynamic>{
      'id': m.id,
      'type': m.type,
      'time': {
        'created': m.created,
        if (m.completed != null) 'completed': m.completed,
      },
    };
    switch (m.type) {
      case 'user':
        raw['text'] = _partText(m, 'text');
        final files = <Map<String, dynamic>>[];
        for (final p in m.parts) {
          if (p.type != 'file') continue;
          files.add({
            'uri': p.fileUrl ?? '',
            if (p.filename != null) 'name': p.filename,
          });
        }
        if (files.isNotEmpty) raw['files'] = files;
        break;
      case 'assistant':
        raw['agent'] = m.agent ?? '';
        if (m.modelID != null) {
          raw['model'] = {
            'id': m.modelID,
            'providerID': m.modelProvider ?? '',
          };
        }
        raw['content'] = m.parts.map((p) => _partToJson(p)).toList();
        if (m.finish != null) raw['finish'] = m.finish;
        if (m.cost != 0) raw['cost'] = m.cost;
        if (m.error != null) raw['error'] = m.error;
        break;
      case 'shell':
        raw['shellID'] = '';
        raw['command'] = m.shellCommand ?? '';
        raw['status'] = m.shellStatus ?? 'running';
        if (m.shellExit != null) raw['exit'] = m.shellExit;
        if (m.shellOutput != null && m.shellOutput!.isNotEmpty) {
          raw['output'] = {
            'output': m.shellOutput,
            'cursor': 0,
            'size': m.shellOutput!.length,
            'truncated': false,
          };
        }
        break;
      default:
        if (m.text != null) raw['text'] = m.text;
        if (m.description != null) raw['description'] = m.description;
        if (m.type == 'idle' && m.outcome != null) {
          raw['outcome'] = m.outcome;
        }
    }
    return raw;
  }

  static String _partText(DisplayMessage m, String type) {
    for (final p in m.parts) {
      if (p.type == type && p.text.isNotEmpty) return p.text;
    }
    return '';
  }

  Map<String, dynamic> _partToJson(DisplayPart p) {
    if (p.type == 'tool') {
      final state = <String, dynamic>{
        'status': p.toolStatus ?? 'running',
        if (p.toolInput != null) 'input': p.toolInput,
        if (p.toolMetadata != null) 'metadata': p.toolMetadata,
      };
      if (p.toolStatus == 'completed' || p.toolStatus == 'error') {
        state['content'] = [
          {'type': 'text', 'text': p.toolOutput ?? ''}
        ];
      }
      if (p.toolStatus == 'error' && p.toolError != null) {
        state['error'] = {'type': 'error', 'message': p.toolError};
      }
      return {
        'type': 'tool',
        'id': p.id,
        'name': p.tool ?? '',
        'state': state,
      };
    }
    return {
      'type': p.type,
      'text': p.text,
    };
  }

  Future<void> _loadCache() async {
    final cs = cacheStore;
    if (cs == null) return;
    try {
      final raw = await cs.read(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      if (_messages.isNotEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final v = j['v'];
      if (v != null && v != 2) return;
      _loadCacheFromJson(j, terminal: true);
    } catch (e) {
      AppLogger.I.e(_tag, 'loadCache failed: $e');
    }
  }

  void _loadCacheFromJson(Map<String, dynamic> j, {bool terminal = false}) {
    _touchMessages();
    final msgs = j['messages'] as List? ?? [];
    _messages.clear();
    for (final m in msgs) {
      final m2 = m as Map<String, dynamic>;
      if (m2['optimistic'] == true) continue;
      var raw = m2;
      if (terminal &&
          m2['type'] == 'assistant' &&
          (m2['finish'] == null || (m2['finish'] as String).isEmpty)) {
        raw = Map<String, dynamic>.of(m2);
        raw['finish'] = 'stop';
      }
      final sm = SessionMessage.fromJson(raw);
      final d = _toDisplay(sm);
      if (d == null) continue;
      _messages.add(d);
    }
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
    _recomputeTodos();
    if (_messages.isNotEmpty) loaded = true;
  }

  Future<void> _maybePreheatCache() async {
    if (sessionUpdated == null || _messages.isNotEmpty || loaded) return;
    final cs = cacheStore;
    if (cs == null) return;
    try {
      final raw = await cs.read(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final v = j['v'];
      if (v != null && v != 2) return;
      final cached = j['cachedSessionUpdated'];
      if (cached != null && cached == sessionUpdated) {
        _loadCacheFromJson(j);
        if (_messages.isNotEmpty && !_disposed) notifyListeners();
      }
    } catch (e) {
      AppLogger.I.w(_tag, 'preheatCache failed: $e');
    }
  }

  void setDraft(String text, {bool shell = false}) {
    _draftText = text;
    _draftShell = shell;
  }

  Future<void> persistDraft() => _saveCache();

  Future<void> loadDraftOnly() async {
    if (_draftLoaded) return;
    final cs = cacheStore;
    try {
      if (cs != null) {
        final raw = await cs.read(_cacheKey);
        if (raw != null && raw.isNotEmpty) {
          final j = jsonDecode(raw) as Map<String, dynamic>;
          _draftText = (j['draft'] ?? '').toString();
          _draftShell = j['draftShell'] == true;
        }
      }
    } catch (e) {
      AppLogger.I.w(_tag, 'loadDraft failed: $e');
    }
    _draftLoaded = true;
    if (!_disposed) notifyListeners();
  }

  DisplayMessage? _toDisplay(SessionMessage e) {
    switch (e) {
      case UserMessage():
        final m = DisplayMessage(
          id: e.id,
          type: 'user',
          created: e.created,
          text: e.text,
        );
        m.parts.add(DisplayPart(
          id: '${e.id}_text',
          type: 'text',
          text: e.text,
        ));
        var i = 0;
        for (final f in e.files) {
          final uri = f.uri;
          String? mime;
          if (uri.startsWith('data:')) {
            final seg = uri.substring(5).split(',').first.split(';').first;
            mime = seg.isEmpty ? null : seg;
          }
          m.parts.add(DisplayPart(
            id: '${e.id}_file_$i',
            type: 'file',
            fileMime: mime,
            fileUrl: uri,
            filename: f.name,
          ));
          i++;
        }
        return m;
      case AssistantMessage():
        final m = DisplayMessage(
          id: e.id,
          type: 'assistant',
          created: e.created,
          completed: e.completed,
          agent: e.agent,
          modelID: e.model?.id,
          modelProvider: e.model?.providerID,
          finish: e.finish,
          cost: e.cost,
          error: e.error?.toJson(),
        );
        var ti = 0;
        var ri = 0;
        for (final c in e.content) {
          switch (c) {
            case TextContent():
              m.parts.add(DisplayPart(
                id: '${e.id}_t${ti++}',
                type: 'text',
                text: c.text,
              ));
            case ReasoningContent():
              m.parts.add(DisplayPart(
                id: '${e.id}_r${ri++}',
                type: 'reasoning',
                text: c.text,
              ));
            case ToolContent():
              m.parts.add(_toolPart('${e.id}_tool_${c.id}', c));
          }
        }
        return m;
      case ShellMessage():
        return DisplayMessage(
          id: e.id,
          type: 'shell',
          created: e.created,
          completed: e.completed,
          shellCommand: e.command,
          shellStatus: e.status,
          shellExit: e.exit,
          shellOutput: e.output,
        );
      case SyntheticMessage():
        return DisplayMessage(
          id: e.id,
          type: 'synthetic',
          created: e.created,
          text: e.text,
          description: e.description,
        );
      case SystemMessage():
        return DisplayMessage(
          id: e.id,
          type: 'system',
          created: e.created,
          text: e.text,
          description: e.description,
        );
      case SkillMessage():
        return DisplayMessage(
          id: e.id,
          type: 'skill',
          created: e.created,
          text: e.text,
          description: e.name,
        );
      case CompactionMessage():
        return DisplayMessage(
          id: e.id,
          type: 'compaction',
          created: e.created,
          compactionStatus: e.status,
          text: e.text,
        );
      case IdleMessage():
        return DisplayMessage(
          id: e.id,
          type: 'idle',
          created: e.created,
          outcome: e.outcome,
        );
      case AgentSwitchedMessage():
        return DisplayMessage(
          id: e.id,
          type: 'agent-switched',
          created: e.created,
          previousLabel: e.previous,
          currentLabel: e.agent,
        );
      case ModelSwitchedMessage():
        return DisplayMessage(
          id: e.id,
          type: 'model-switched',
          created: e.created,
          previousLabel: e.previous?.id,
          currentLabel: e.model?.id,
        );
      case LocationSwitchedMessage():
        return DisplayMessage(
          id: e.id,
          type: 'location-switched',
          created: e.created,
          previousLabel: e.previous,
          currentLabel: e.directory,
        );
      case UnknownMessage():
        return null;
    }
  }

  static DisplayPart _toolPart(String partId, ToolContent c) {
    final state = c.state;
    String? status;
    String? output;
    String? toolError;
    Map<String, dynamic>? input;
    Map<String, dynamic>? metadata;
    switch (state) {
      case StreamingToolState():
        status = 'streaming';
      case RunningToolState():
        status = 'running';
        input = state.input;
        metadata = state.metadata;
      case CompletedToolState():
        status = 'completed';
        input = state.input;
        metadata = state.metadata;
        output = _toolContentText(state.content);
      case ErrorToolState():
        status = 'error';
        input = state.input;
        metadata = state.metadata;
        output = _toolContentText(state.content);
        toolError = state.error.message;
    }
    return DisplayPart(
      id: partId,
      type: 'tool',
      tool: c.name,
      toolStatus: status,
      toolOutput: output,
      toolError: toolError,
      toolInput: input,
      toolMetadata: metadata,
    );
  }

  void setStatus(String s, {String? retryMessage}) {
    final prevStatus = status;
    final prevRetry = this.retryMessage;
    status = s;
    if (s == 'retry') {
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

  void markWorkspaceMissing() {
    if (workspaceMissing) return;
    setStatus('idle');
    workspaceMissing = true;
    if (!_disposed) notifyListeners();
  }

  void clearWorkspaceMissing() {
    if (!workspaceMissing) return;
    workspaceMissing = false;
    if (!_disposed) notifyListeners();
  }

  void onStepStarted(String mid,
      {String? agent, ModelRef? model, int? started}) {
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    if (agent != null && agent.isNotEmpty) msg.agent = agent;
    if (model != null) {
      msg.modelID = model.id;
      msg.modelProvider = model.providerID;
    }
    if (msg.finish == 'tool-calls') msg.finish = null;
    notifyListeners();
  }

  void _onContentDelta(
      String mid, String kind, int ordinal, String? delta, String? text) {
    final partId = kind == 'text' ? '${mid}_t$ordinal' : '${mid}_r$ordinal';
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    var idx = msg.parts.indexWhere((x) => x.id == partId);
    DisplayPart dp;
    if (idx == -1) {
      dp = DisplayPart(id: partId, type: kind);
      msg.parts.add(dp);
    } else {
      dp = msg.parts[idx];
    }
    if (delta != null && delta.isNotEmpty) {
      dp.text += delta;
    } else if (text != null && text.isNotEmpty) {
      dp.text = text;
    }
    _previewableTouch(msg);
    notifyListeners();
  }

  void onTextStarted(String mid, int ordinal) =>
      _onContentDelta(mid, 'text', ordinal, null, null);

  void onTextDelta(String mid, int ordinal, String delta) =>
      _onContentDelta(mid, 'text', ordinal, delta, null);

  void onTextEnded(String mid, int ordinal, String text) =>
      _onContentDelta(mid, 'text', ordinal, null, text);

  void onReasoningStarted(String mid, int ordinal) =>
      _onContentDelta(mid, 'reasoning', ordinal, null, null);

  void onReasoningDelta(String mid, int ordinal, String delta) =>
      _onContentDelta(mid, 'reasoning', ordinal, delta, null);

  void onReasoningEnded(String mid, int ordinal, String text) =>
      _onContentDelta(mid, 'reasoning', ordinal, null, text);

  void onToolInputStarted(String mid, String callId, String name) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    var idx = msg.parts.indexWhere((x) => x.id == partId);
    if (idx == -1) {
      msg.parts.add(DisplayPart(
        id: partId,
        type: 'tool',
        tool: name,
        toolStatus: 'streaming',
      ));
    } else {
      msg.parts[idx].tool = name;
      msg.parts[idx].toolStatus = 'streaming';
    }
    notifyListeners();
  }

  void onToolInputDelta(String mid, String callId, String delta) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid);
    if (msg == null) return;
    final idx = msg.parts.indexWhere((x) => x.id == partId);
    if (idx == -1) return;
    final dp = msg.parts[idx];
    dp.toolStatus = 'streaming';
    final cur = dp.command ?? '';
    dp.command = cur + delta;
    notifyListeners();
  }

  void onToolInputEnded(String mid, String callId, String text) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid);
    if (msg == null) return;
    final idx = msg.parts.indexWhere((x) => x.id == partId);
    if (idx == -1) return;
    final dp = msg.parts[idx];
    dp.command = text;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        dp.toolInput = decoded.cast<String, dynamic>();
        dp.command = null;
      }
    } catch (_) {}
    notifyListeners();
  }

  void onToolCalled(String mid, String callId, Map<String, dynamic>? input,
      bool? executed) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid) ?? _ensureMessage(mid);
    var idx = msg.parts.indexWhere((x) => x.id == partId);
    DisplayPart dp;
    if (idx == -1) {
      dp = DisplayPart(id: partId, type: 'tool', toolStatus: 'running');
      msg.parts.add(dp);
    } else {
      dp = msg.parts[idx];
    }
    if (input != null && input.isNotEmpty) dp.toolInput = input;
    dp.toolStatus = 'running';
    if (dp.tool == 'todowrite') _recomputeTodos();
    notifyListeners();
  }

  void onToolProgress(String mid, String callId, Map<String, dynamic>? metadata) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid);
    if (msg == null) return;
    final idx = msg.parts.indexWhere((x) => x.id == partId);
    if (idx == -1) return;
    if (metadata != null && metadata.isNotEmpty) {
      msg.parts[idx].toolMetadata = metadata;
    }
    notifyListeners();
  }

  void onToolSuccess(String mid, String callId, List<ToolContentItem> content) {
    _setToolCompleted(mid, callId, 'completed', output: _toolContentText(content));
  }

  void onToolFailed(String mid, String callId, Map<String, dynamic> error,
      {List<ToolContentItem>? content}) {
    final msg = error['message']?.toString() ?? error.toString();
    _setToolCompleted(mid, callId, 'error',
        output: content == null ? null : _toolContentText(content),
        error: msg);
  }

  void _setToolCompleted(String mid, String callId, String status,
      {String? output, String? error}) {
    final partId = '${mid}_tool_$callId';
    final msg = _findMessage(mid);
    if (msg == null) return;
    final idx = msg.parts.indexWhere((x) => x.id == partId);
    if (idx == -1) return;
    final dp = msg.parts[idx];
    dp.toolStatus = status;
    if (output != null && output.isNotEmpty) dp.toolOutput = output;
    if (error != null && error.isNotEmpty) dp.toolError = error;
    if (dp.tool == 'todowrite') _recomputeTodos();
    _previewableTouch(msg);
    notifyListeners();
  }

  void onStepEnded(String mid,
      {String? finish,
      String? rawFinish,
      double? cost,
      Tokens? tokens}) {
    final msg = _findMessage(mid);
    if (msg == null) return;
    if (finish != null) msg.finish = finish;
    if (cost != null) msg.cost = cost;
    _recomputeTodos();
    _touchMessages(<String>{mid});
    if (finish != 'tool-calls') {
      unawaited(_saveCache());
    }
    notifyListeners();
  }

  void onStepFailed(String mid, Map<String, dynamic> error, {String? finish}) {
    final msg = _findMessage(mid);
    if (msg == null) return;
    msg.finish = finish ?? 'error';
    msg.error = error;
    _touchMessages(<String>{mid});
    if (finish != 'tool-calls') {
      unawaited(_saveCache());
    }
    notifyListeners();
  }

  void onMessageContentUpdated(String mid, List<AssistantContent> content) {
    final existing = _findMessage(mid);
    if (existing == null) {
      final sm = AssistantMessage(
        id: mid,
        raw: {
          'id': mid,
          'type': 'assistant',
          'time': {'created': DateTime.now().millisecondsSinceEpoch},
          'agent': '',
          'model': null,
          'content': [for (final c in content) c],
        },
        created: DateTime.now().millisecondsSinceEpoch,
        agent: '',
        model: null,
        content: content,
      );
      final d = _toDisplay(sm);
      if (d != null) {
        _messages.add(d);
        _sort(<String>{mid});
      }
    } else {
      final authoritative = <DisplayPart>[];
      var ti = 0;
      var ri = 0;
      for (final c in content) {
        switch (c) {
          case TextContent():
            authoritative.add(DisplayPart(
              id: '${mid}_t${ti++}',
              type: 'text',
              text: c.text,
            ));
          case ReasoningContent():
            authoritative.add(DisplayPart(
              id: '${mid}_r${ri++}',
              type: 'reasoning',
              text: c.text,
            ));
          case ToolContent():
            authoritative.add(_toolPart('${mid}_tool_${c.id}', c));
        }
      }
      existing.parts
        ..clear()
        ..addAll(_mergeParts(authoritative, existing.parts));
      _touchMessages(<String>{mid});
    }
    _recomputeTodos();
    notifyListeners();
  }

  void onInboxEnqueued(String inboxId, Map<String, dynamic> item,
      {int? created}) {
    if (item['type'] != 'user') return;
    final payload =
        (item['payload'] as Map?)?.cast<String, dynamic>() ?? const {};
    final text = payload['text']?.toString() ?? '';
    final files = (payload['files'] as List? ?? [])
        .whereType<Map>()
        .map((e) => FileAttachment.fromJson(e.cast<String, dynamic>()))
        .toList();
    final time = created ?? DateTime.now().millisecondsSinceEpoch;
    final sm = UserMessage(
      id: inboxId,
      raw: {
        'id': inboxId,
        'type': 'user',
        'time': {'created': time},
        'text': text,
        'files': [for (final f in files) f.toJson()],
      },
      created: time,
      text: text,
      files: files,
    );
    onUserMessageArrived(sm);
  }

  void onUserMessageArrived(UserMessage user) {
    List<DisplayPart>? bridge;
    final opt = _firstOptimisticUser();
    if (opt != null) bridge = List<DisplayPart>.of(opt.parts);
    _pruneOptimistic();
    final existing = _findMessage(user.id);
    if (existing != null) {
      _messages.remove(existing);
    }
    final d = _toDisplay(user);
    if (d == null) return;
    if (bridge != null) _bridgeOptimisticParts(d, bridge);
    _messages.add(d);
    _sort(<String>{user.id});
    unawaited(_saveCache());
    notifyListeners();
  }

  void onRetryScheduled(String? mid, int attempt, Map<String, dynamic> error) {
    final message = error['message']?.toString();
    setStatus('retry', retryMessage: message);
    if (mid != null) {
      final msg = _findMessage(mid);
      if (msg != null &&
          msg.error == null &&
          message != null &&
          message.isNotEmpty) {
        msg.error = error;
        _touchMessages(<String>{mid});
        notifyListeners();
      }
    }
  }

  void onExecutionSettled(String outcome) {
    setStatus('idle');
  }

  void _previewableTouch(DisplayMessage msg) {
    final cacheable =
        msg.type != 'assistant' || (msg.finish != null && msg.finish!.isNotEmpty);
    if (cacheable) {
      _touchMessages(<String>{msg.id});
    }
  }

  void _recomputeTodos() {
    List<Todo>? latest;
    for (final m in _messages) {
      if (m.type != 'assistant') continue;
      for (final p in m.parts) {
        if (p.type != 'tool' || p.tool != 'todowrite') continue;
        final input = p.toolInput;
        if (input == null) continue;
        if (input['todos'] is List) {
          latest = (input['todos'] as List)
              .whereType<Map>()
              .map((e) => Todo.fromJson(e.cast<String, dynamic>()))
              .toList();
        }
      }
    }
    final old = _todos;
    final next = latest ?? const <Todo>[];
    if (old.length != next.length) {
      _todos = next;
      return;
    }
    for (var i = 0; i < old.length; i++) {
      if (old[i].content != next[i].content ||
          old[i].status != next[i].status) {
        _todos = next;
        return;
      }
    }
  }

  void onPermission(Permission p) {
    final idx = _permissions.indexWhere((x) => x.id == p.id);
    if (idx == -1) {
      _permissions.add(p);
    } else {
      final old = _permissions[idx];
      if (old.action == p.action &&
          old.sessionID == p.sessionID &&
          _eqMetadata(old.metadata, p.metadata) &&
          old.resources.length == p.resources.length &&
          old.resources.asMap().entries
              .every((e) => p.resources[e.key] == e.value)) {
        return;
      }
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

  bool _eqMetadata(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return mapEquals(a, b);
  }

  Future<void> respondPermission(Permission p, String response) async {
    final cardSid = p.sessionID.isNotEmpty ? p.sessionID : sessionId;
    AppLogger.I.i(_tag,
        'respondPermission sid=$sessionId cardSid=$cardSid pid=${p.id} resp=$response dir=$directory');
    try {
      await client.respondPermission(cardSid, p.id, response);
      AppLogger.I.i(_tag, 'respondPermission POST ok pid=${p.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      AppLogger.I.e(_tag, 'respondPermission POST err pid=${p.id} status=$code body=${e.response?.data}');
      if (code != 404) throw OperationException('回复权限', cause: e);
    }
    onPermissionResolved?.call(p.id);
    onPermissionReplied(p.id);
  }

  void onForm(FormInfo f) {
    final idx = _forms.indexWhere((x) => x.id == f.id);
    if (idx == -1) {
      if (!f.pending) return;
      _forms.add(f);
    } else {
      if (!f.pending) {
        _forms.removeAt(idx);
        notifyListeners();
        return;
      }
      final old = _forms[idx];
      if (old == f) return;
      _forms[idx] = f;
    }
    AppLogger.I.i(_tag, 'onForm fid=${f.id} sid=${f.sessionID} op=${idx == -1 ? "add" : "replace"} → count=${_forms.length}');
    notifyListeners();
  }

  void onFormReplied(String formId) {
    AppLogger.I.i(_tag, 'onFormReplied fid=$formId → removed, count was=${_forms.length}');
    _forms.removeWhere((f) => f.id == formId);
    notifyListeners();
  }

  Future<void> replyForm(FormInfo form, Map<String, dynamic> answers) async {
    AppLogger.I.i(_tag, 'replyForm sid=$sessionId fid=${form.id} answers=$answers');
    try {
      await client.replyForm(sessionId, form.id, answers);
      AppLogger.I.i(_tag, 'replyForm POST ok fid=${form.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      AppLogger.I.e(_tag, 'replyForm POST err fid=${form.id} status=$code body=${e.response?.data}');
      if (code != 404) throw OperationException('回复问题', cause: e);
    }
    onQuestionResolved?.call(form.id);
    onFormReplied(form.id);
  }

  Future<void> cancelForm(FormInfo form) async {
    AppLogger.I.i(_tag, 'cancelForm sid=$sessionId fid=${form.id}');
    try {
      await client.cancelForm(sessionId, form.id);
      AppLogger.I.i(_tag, 'cancelForm DELETE ok fid=${form.id}');
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      if (code != 404) throw OperationException('取消问题', cause: e);
    }
    onQuestionResolved?.call(form.id);
    onFormReplied(form.id);
  }

  DisplayMessage? _findMessage(String id) {
    for (final m in _messages) {
      if (m.id == id) return m;
    }
    return null;
  }

  DisplayMessage _ensureMessage(String id) {
    final found = _findMessage(id);
    if (found != null) return found;
    final maxCreated = _messages.fold<int>(0, (a, m) => a > m.created ? a : m.created);
    final m = DisplayMessage(
      id: id,
      type: 'assistant',
      created: maxCreated + 1,
    );
    _messages.add(m);
    _sort(const <String>{});
    return m;
  }

  void _sort([Set<String>? changedIds]) {
    _touchMessages(changedIds);
    _messages.sort((a, b) => a.created.compareTo(b.created));
  }

  @visibleForTesting
  Future<void> saveCacheForTest() async => _saveCache();

  @visibleForTesting
  Future<void> loadCacheForTest() async => _loadCache();

  @visibleForTesting
  Future<void> preheatCacheForTest() async => _maybePreheatCache();

  @visibleForTesting
  DisplayMessage? toDisplayForTest(SessionMessage e) => _toDisplay(e);

  @visibleForTesting
  static bool isEmptyUserForTest(DisplayMessage m) => _isEmptyUser(m);
}
