import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'diff_widgets.dart';
import 'file_browsing_container.dart';
import 'highlight_theme.dart';

class DiffDetailScreen extends StatefulWidget {
  final String sessionId;
  final String path;
  final String? directory;
  final DiffMode mode;
  final String? messageID;
  const DiffDetailScreen({
    super.key,
    required this.sessionId,
    required this.path,
    this.directory,
    this.mode = DiffMode.uncommitted,
    this.messageID,
  });

  @override
  State<DiffDetailScreen> createState() => _DiffDetailScreenState();
}

class _DiffDetailScreenState extends State<DiffDetailScreen> {
  FileDiff? _diff;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = const KnownError(FriendlyErrorKind.notConnected));
      return;
    }
    try {
      if (widget.mode == DiffMode.lastMessage &&
          (widget.messageID == null || widget.messageID!.isEmpty)) {
        _error = const KnownError(FriendlyErrorKind.diffNoLastMessage);
      } else {
        final diffs = await c.diff(
          widget.sessionId,
          directory: widget.directory,
          mode: widget.mode == DiffMode.branch ? 'branch' : 'git',
          messageID: widget.mode == DiffMode.lastMessage ? widget.messageID : null,
        );
        for (final d in diffs) {
          if (d.file == widget.path) {
            _diff = d;
            break;
          }
        }
        _error = _diff == null
            ? const KnownError(FriendlyErrorKind.diffNotFound)
            : null;
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFullFile() async {
    final store = serverStore.fileBrowsing;
    final container = store.containerFor<FileBrowsingContainerState>(
      widget.sessionId,
      widget.directory,
    );
    if (container != null) {
      final popped = ModalRoute.of(context)?.popped;
      Navigator.of(context, rootNavigator: true).pop();
      await popped;
      if (container.mounted) container.openFile(widget.path);
      return;
    }
    final existing = store.snapshotFor(widget.sessionId, widget.directory);
    final entry = OpenFileEntry(
      path: widget.path,
      scrollOffset: 0,
      wrap: false,
      mdShowSource: false,
    );
    if (existing != null) {
      existing.openFiles.removeWhere((e) => e.path == entry.path);
      existing.openFiles.add(entry);
      if (existing.openFiles.length > FileBrowsingStore.maxOpenFiles) {
        existing.openFiles.removeAt(0);
      }
    }
    if (!mounted) return;
    context.push(
      '/session/${widget.sessionId}/files'
      '?directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
      extra: existing ?? FileBrowsingSnapshot(openFiles: [entry]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.path.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: _diff == null ? null : _openFullFile,
            child: Text(l(context).diffViewFullFile),
          ),
          appBarActionsTrailing,
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l(context).loadFailed,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              friendlyMessage(l(context), _error!),
              style: AppTheme.mono.copyWith(fontSize: 12),
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(l(context).retry)),
          ],
        ),
      );
    }
    final hunks = parseDiffHunks(_diff!.patch);
    if (hunks.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.compare, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(l(context).diffNoTextDiff),
          ],
        ),
      );
    }
    final language = languageForPath(widget.path);
    final brightness = Theme.of(context).brightness;
    final scaler = MediaQuery.textScalerOf(context);
    final contentWidth = _maxContentWidth(hunks, scaler);
    final gutterWidth = _gutterWidth(hunks, scaler);
    final totalWidth = contentWidth + gutterWidth + _gutterGap + _padLeft + _padRight;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: totalWidth,
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: hunks.length,
          itemBuilder: (_, i) => DiffHunkSection(
            hunk: hunks[i],
            index: i,
            language: language,
            contentWidth: contentWidth,
            gutterWidth: gutterWidth,
            brightness: brightness,
          ),
        ),
      ),
    );
  }
}

const _fontSize = 12.5;
const _gutterGap = 6.0;
const _padLeft = 8.0;
const _padRight = 20.0;

TextStyle _baseStyle(Brightness brightness) => AppTheme.mono.copyWith(
      fontSize: _fontSize,
      color: brightness == Brightness.dark
          ? const Color(0xFFDFE4DC)
          : const Color(0xFF181D18),
    );

double _gutterWidth(List<DiffHunk> hunks, TextScaler scaler) {
  var maxNo = 0;
  for (final h in hunks) {
    for (final line in h.lines) {
      final n = line.newNo ?? line.oldNo ?? 0;
      if (n > maxNo) maxNo = n;
    }
  }
  final digits = maxNo.toString().length;
  final tp = TextPainter(
    text: TextSpan(text: '0' * digits, style: AppTheme.mono.copyWith(fontSize: _fontSize)),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w + 4;
}

double _maxContentWidth(List<DiffHunk> hunks, TextScaler scaler) {
  final style = AppTheme.mono.copyWith(fontSize: _fontSize);
  final tp = TextPainter(
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  );
  var widest = 0.0;
  for (final h in hunks) {
    for (final line in h.lines) {
      tp.text = TextSpan(text: line.text, style: style);
      tp.layout();
      if (tp.width > widest) widest = tp.width;
    }
  }
  tp.dispose();
  return widest;
}

/// Per-hunk block: owns the dual-path highlight state and renders a header plus
/// its content rows. Does not scroll horizontally itself — width is bounded by
/// the parent [SizedBox] so all hunks share one horizontal axis.
class DiffHunkSection extends StatefulWidget {
  final DiffHunk hunk;
  final int index;
  final String? language;
  final double contentWidth;
  final double gutterWidth;
  final Brightness brightness;

  const DiffHunkSection({
    super.key,
    required this.hunk,
    required this.index,
    required this.language,
    required this.contentWidth,
    required this.gutterWidth,
    required this.brightness,
  });

  @override
  State<DiffHunkSection> createState() => _DiffHunkSectionState();
}

class _DiffHunkSectionState extends State<DiffHunkSection> {
  List<TextSpan>? _newSpans;
  List<TextSpan>? _oldSpans;
  int _gen = 0;

  @override
  void initState() {
    super.initState();
    _beginHighlight();
  }

  @override
  void didUpdateWidget(covariant DiffHunkSection old) {
    super.didUpdateWidget(old);
    if (widget.hunk != old.hunk ||
        widget.language != old.language ||
        widget.brightness != old.brightness) {
      _beginHighlight();
    }
  }

  Future<void> _beginHighlight() async {
    final lang = widget.language;
    if (lang == null) return;
    final gen = ++_gen;
    final base = _baseStyle(widget.brightness);

    final newList = <String>[];
    final oldList = <String>[];
    for (final line in widget.hunk.lines) {
      switch (line.kind) {
        case ' ':
          newList.add(line.text);
          oldList.add(line.text);
          break;
        case '+':
          newList.add(line.text);
          break;
        case '-':
          oldList.add(line.text);
          break;
      }
    }
    final newCode = newList.join('\n');
    final oldCode = oldList.join('\n');

    List<TextSpan> computeNew() => HighlightPainter.highlight(newCode, lang, base, widget.brightness);
    List<TextSpan> computeOld() => HighlightPainter.highlight(oldCode, lang, base, widget.brightness);

    final newAsync = newList.length > kAsyncHighlightThreshold;
    final oldAsync = oldList.length > kAsyncHighlightThreshold;

    List<TextSpan> nsp;
    List<TextSpan> osp;
    if (newAsync || oldAsync) {
      // Offload the heavy side(s) to a background isolate; a side under
      // threshold is computed inline first (it's already done by the time
      // Future.wait starts, so only the async side truly offloads).
      final newFuture = newAsync
          ? compute(_highlightTask, _Task(newCode, lang, base, widget.brightness))
          : Future.value(computeNew());
      final oldFuture = oldAsync
          ? compute(_highlightTask, _Task(oldCode, lang, base, widget.brightness))
          : Future.value(computeOld());
      final results = await Future.wait([newFuture, oldFuture]);
      nsp = results[0];
      osp = results[1];
    } else {
      nsp = computeNew();
      osp = computeOld();
    }
    if (mounted && gen == _gen) {
      setState(() {
        _newSpans = nsp;
        _oldSpans = osp;
      });
    }
  }

  TextSpan _plain(String text) => TextSpan(text: text, style: _baseStyle(widget.brightness));

  TextSpan _spanFor(DiffLine line, int ni, int oi) {
    if (line.kind == '-') {
      return (_oldSpans != null && oi < _oldSpans!.length) ? _oldSpans![oi] : _plain(line.text);
    }
    return (_newSpans != null && ni < _newSpans!.length) ? _newSpans![ni] : _plain(line.text);
  }

  @override
  Widget build(BuildContext context) {
    final a = Theme.of(context).extension<AppColors>()!;
    final muted = Theme.of(context).colorScheme.outline;
    final base = _baseStyle(widget.brightness);
    final rows = <Widget>[];
    var ni = 0;
    var oi = 0;
    for (final line in widget.hunk.lines) {
      final span = _spanFor(line, ni, oi);
      if (line.kind == ' ') {
        ni++;
        oi++;
      } else if (line.kind == '+') {
        ni++;
      } else {
        oi++;
      }
      rows.add(DiffRow(
        line: line,
        span: span,
        gutterWidth: widget.gutterWidth,
        base: base,
        addBg: a.diffAddBg,
        delBg: a.diffDelBg,
        addFg: a.diffAddFg,
        delFg: a.diffDelFg,
        muted: muted,
      ));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DiffHunkHeader(
          index: widget.index,
          hunk: widget.hunk,
          width: widget.contentWidth + widget.gutterWidth + _gutterGap + _padLeft + _padRight,
        ),
        ...rows,
      ],
    );
  }
}

List<TextSpan> _highlightTask(_Task t) =>
    HighlightPainter.highlight(t.code, t.language, t.base, t.brightness);

class _Task {
  final String code;
  final String language;
  final TextStyle base;
  final Brightness brightness;
  const _Task(this.code, this.language, this.base, this.brightness);
}

class DiffHunkHeader extends StatelessWidget {
  final int index;
  final DiffHunk hunk;
  final double width;
  const DiffHunkHeader({
    super.key,
    required this.index,
    required this.hunk,
    required this.width,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    final surface = Theme.of(context).colorScheme.surfaceContainerLow;
    final newStart = hunk.newStart;
    // New-side line numbers advance only for context + added lines, not deletions,
    // so the new-side span length is the count of those — not all hunk lines.
    var newCount = 0;
    for (final l in hunk.lines) {
      if (l.kind == ' ' || l.kind == '+') newCount++;
    }
    final newEnd = (newStart == null || newCount == 0)
        ? null
        : newStart + newCount - 1;
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text(
            l(context).diffHunkSegment(index + 1),
            style: TextStyle(fontSize: 12, color: muted),
          ),
          if (newStart != null && newEnd != null) ...[
            const SizedBox(width: 8),
            Text(
              'L$newStart–$newEnd',
              style: AppTheme.mono.copyWith(fontSize: 11, color: muted),
            ),
          ],
          const Spacer(),
          DiffStat(add: hunk.additions, del: hunk.deletions),
        ],
      ),
    );
  }
}

class DiffRow extends StatelessWidget {
  final DiffLine line;
  final TextSpan span;
  final double gutterWidth;
  final TextStyle base;
  final Color addBg;
  final Color delBg;
  final Color addFg;
  final Color delFg;
  final Color muted;
  const DiffRow({
    super.key,
    required this.line,
    required this.span,
    required this.gutterWidth,
    required this.base,
    required this.addBg,
    required this.delBg,
    required this.addFg,
    required this.delFg,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    Color bg = Colors.transparent;
    Color markerColor = Colors.transparent;
    Color numberColor = muted;
    String marker = '';
    int? number;
    switch (line.kind) {
      case '+':
        bg = addBg;
        markerColor = addFg;
        numberColor = addFg;
        marker = '+';
        number = line.newNo;
        break;
      case '-':
        bg = delBg;
        markerColor = delFg;
        numberColor = delFg;
        marker = '−';
        number = line.oldNo;
        break;
      default:
        number = line.newNo ?? line.oldNo;
    }
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: _padLeft, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            child: Text(
              marker,
              style: base.copyWith(color: markerColor),
            ),
          ),
          SizedBox(
            width: gutterWidth,
            child: Text(
              number?.toString() ?? '',
              style: base.copyWith(color: numberColor),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: _gutterGap),
          Expanded(
            child: SelectableText.rich(
              TextSpan(children: [span], style: base),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}
