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

  List<DiffHunk>? _hunks;
  List<_DiffItem>? _items;
  Brightness? _brightness;
  TextScaler _textScaler = TextScaler.noScaling;
  final Map<int, List<TextSpan>> _newSpansByHunk = {};
  final Map<int, List<TextSpan>> _oldSpansByHunk = {};
  int _highlightGen = 0;
  double? _maxWidthCache;
  double? _gutterWidthCache;
  final _hScrollCtl = ScrollController();
  final _vScrollCtl = ScrollController();
  final _firstLineKey = GlobalKey();
  List<GlobalKey> _headerKeys = const [];
  double? _headerHeight;
  double? _lineHeight;
  List<double> _headerTops = const [];
  double _contentHeight = 0;
  int _firstLineItemIndex = -1;
  final _sticky = ValueNotifier<_StickyState>(const _StickyState(-1, 0));

  @override
  void initState() {
    super.initState();
    _vScrollCtl.addListener(_updateSticky);
    _load();
  }

  @override
  void dispose() {
    _sticky.dispose();
    _hScrollCtl.dispose();
    _vScrollCtl.dispose();
    super.dispose();
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
        if (_diff != null) _prepare();
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _prepare() {
    final hunks = parseDiffHunks(_diff!.patch);
    _hunks = hunks;
    _items = _flatten(hunks);
    _newSpansByHunk.clear();
    _oldSpansByHunk.clear();
    _firstLineItemIndex = _items!.indexWhere((e) => e is _LineItem);
    _headerKeys = List.generate(hunks.length, (_) => GlobalKey());
    _headerHeight = null;
    _lineHeight = null;
    _headerTops = const [];
    _contentHeight = 0;
    _sticky.value = const _StickyState(-1, 0);
    _beginHighlight();
  }

  void _measureItemHeights() {
    if (_headerHeight != null) return;
    final headerBox = _headerKeys.first.currentContext?.findRenderObject() as RenderBox?;
    if (headerBox == null || !headerBox.hasSize) return;
    double? lineHeight;
    if (_firstLineItemIndex >= 0) {
      final lineBox = _firstLineKey.currentContext?.findRenderObject() as RenderBox?;
      if (lineBox == null || !lineBox.hasSize) return;
      lineHeight = lineBox.size.height;
    }
    setState(() {
      _headerHeight = headerBox.size.height;
      _lineHeight = lineHeight;
      _computeHeaderTops();
      _updateSticky();
    });
  }

  void _computeHeaderTops() {
    final hh = _headerHeight;
    final lh = _lineHeight;
    if (hh == null || (_firstLineItemIndex >= 0 && lh == null)) return;
    final tops = <double>[];
    var y = 0.0;
    for (final item in _items!) {
      if (item is _HeaderItem) {
        tops.add(y);
        y += hh;
      } else {
        y += lh!;
      }
    }
    _headerTops = tops;
    _contentHeight = y;
  }

  void _jumpToHunk(int hunkIndex) {
    if (hunkIndex < 0 ||
        hunkIndex >= _headerKeys.length ||
        !_vScrollCtl.hasClients) {
      return;
    }
    final box = _headerKeys[hunkIndex].currentContext?.findRenderObject()
        as RenderBox?;
    double target;
    if (box != null) {
      final scrollRenderObject =
          _vScrollCtl.position.context.storageContext.findRenderObject();
      final top =
          box.localToGlobal(Offset.zero, ancestor: scrollRenderObject).dy;
      target = _vScrollCtl.offset + top;
    } else {
      target = _headerTops[hunkIndex];
    }
    _vScrollCtl.animateTo(
      target.clamp(0.0, _vScrollCtl.position.maxScrollExtent),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  void _updateSticky() {
    if (_headerHeight == null || _headerKeys.isEmpty || !_vScrollCtl.hasClients) return;
    final scrollRenderObject =
        _vScrollCtl.position.context.storageContext.findRenderObject();
    var active = -1;
    for (var i = 0; i < _headerKeys.length; i++) {
      final box = _headerKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null) continue;
      final top = box.localToGlobal(Offset.zero, ancestor: scrollRenderObject).dy;
      if (top <= 0.5) {
        active = i;
      } else {
        break;
      }
    }
    _sticky.value = _StickyState(active, 0);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    final scaler = MediaQuery.textScalerOf(context);
    final brightnessChanged = _brightness != null && _brightness != brightness;
    final scalerChanged = scaler != _textScaler;
    _brightness = brightness;
    _textScaler = scaler;
    if (scalerChanged) {
      _maxWidthCache = null;
      _gutterWidthCache = null;
      _headerHeight = null;
      _lineHeight = null;
    }
    if (_hunks != null && brightnessChanged) _beginHighlight();
  }

  List<_DiffItem> _flatten(List<DiffHunk> hunks) {
    final items = <_DiffItem>[];
    for (var hi = 0; hi < hunks.length; hi++) {
      final hunk = hunks[hi];
      items.add(_HeaderItem(index: hi, hunk: hunk));
      var ni = 0;
      var oi = 0;
      for (final line in hunk.lines) {
        final useOld = line.kind == '-';
        items.add(_LineItem(
          hunkIndex: hi,
          line: line,
          useOld: useOld,
          spanIndex: useOld ? oi : ni,
        ));
        if (line.kind == ' ') {
          ni++;
          oi++;
        } else if (line.kind == '+') {
          ni++;
        } else {
          oi++;
        }
      }
    }
    return items;
  }

  Future<void> _beginHighlight() async {
    final lang = languageForPath(widget.path);
    final hunks = _hunks;
    final brightness = _brightness;
    if (lang == null || hunks == null || brightness == null) return;
    final gen = ++_highlightGen;
    final base = _base;
    for (var hi = 0; hi < hunks.length; hi++) {
      final hunk = hunks[hi];
      final newList = <String>[];
      final oldList = <String>[];
      for (final line in hunk.lines) {
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
      final newAsync = newList.length > kAsyncHighlightThreshold;
      final oldAsync = oldList.length > kAsyncHighlightThreshold;

      List<TextSpan> nsp;
      List<TextSpan> osp;
      if (newAsync || oldAsync) {
        final newFuture = newAsync
            ? compute(_highlightTask, _Task(newCode, lang, base, brightness))
            : Future.value(
                HighlightPainter.highlight(newCode, lang, base, brightness));
        final oldFuture = oldAsync
            ? compute(_highlightTask, _Task(oldCode, lang, base, brightness))
            : Future.value(
                HighlightPainter.highlight(oldCode, lang, base, brightness));
        final results = await Future.wait([newFuture, oldFuture]);
        nsp = results[0];
        osp = results[1];
      } else {
        nsp = HighlightPainter.highlight(newCode, lang, base, brightness);
        osp = HighlightPainter.highlight(oldCode, lang, base, brightness);
      }
      if (gen != _highlightGen) return;
      if (!mounted) return;
      _newSpansByHunk[hi] = nsp;
      _oldSpansByHunk[hi] = osp;
      setState(() {});
    }
  }

  TextSpan _spanForLine(_LineItem item) {
    final spans =
        item.useOld ? _oldSpansByHunk[item.hunkIndex] : _newSpansByHunk[item.hunkIndex];
    if (spans != null && item.spanIndex < spans.length) {
      return spans[item.spanIndex];
    }
    return TextSpan(text: item.line.text, style: _base);
  }

  TextStyle get _base => AppTheme.mono.copyWith(
        fontSize: _fontSize,
        color: _brightness == Brightness.dark
            ? const Color(0xFFDFE4DC)
            : const Color(0xFF181D18),
      );

  double get _gutterWidth {
    final cached = _gutterWidthCache;
    if (cached != null) return cached;
    final hunks = _hunks!;
    var maxNo = 0;
    for (final h in hunks) {
      for (final line in h.lines) {
        final n = line.newNo ?? line.oldNo ?? 0;
        if (n > maxNo) maxNo = n;
      }
    }
    final digits = maxNo.toString().length;
    final tp = TextPainter(
      text: TextSpan(
          text: '0' * digits, style: AppTheme.mono.copyWith(fontSize: _fontSize)),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final w = tp.width + 4;
    tp.dispose();
    return _gutterWidthCache = w;
  }

  double get _maxContentWidth {
    final cached = _maxWidthCache;
    if (cached != null) return cached;
    final hunks = _hunks!;
    final style = AppTheme.mono.copyWith(fontSize: _fontSize);
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
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
    final pad = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final padW = pad.width;
    pad.dispose();
    tp.dispose();
    return _maxWidthCache = widest + padW;
  }

  Future<void> _openFullFile() async {
    final store = serverStore.fileBrowsing;
    final hunks = _hunks;
    int? line;
    if (hunks != null && hunks.isNotEmpty) {
      final top = _sticky.value.index >= 0 ? _sticky.value.index : 0;
      line = hunks[top].newStart ?? hunks[top].oldStart;
    }
    final container = store.containerFor<FileBrowsingContainerState>(
      widget.sessionId,
      widget.directory,
    );
    if (container != null) {
      final popped = ModalRoute.of(context)?.popped;
      Navigator.of(context, rootNavigator: true).pop();
      await popped;
      if (container.mounted) container.openFile(widget.path, initialLine: line, mdShowSource: true);
      return;
    }
    final existing = store.snapshotFor(widget.sessionId, widget.directory);
    final entry = OpenFileEntry(
      path: widget.path,
      scrollOffset: 0,
      wrap: false,
      mdShowSource: true,
      initialLine: line,
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
    final hunks = _hunks!;
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
    final contentWidth = _maxContentWidth;
    final gutterWidth = _gutterWidth;
    final totalWidth = contentWidth + gutterWidth + _gutterGap + _padLeft + _padRight;
    final a = Theme.of(context).extension<AppColors>()!;
    final muted = Theme.of(context).colorScheme.outline;
    final base = _base;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportWidth = constraints.maxWidth;
        final viewportHeight = constraints.maxHeight;
        final effectiveWidth = totalWidth < viewportWidth ? viewportWidth : totalWidth;
        final double bottomPad = _headerTops.isEmpty
            ? 8.0
            : (_headerTops.last + viewportHeight - _contentHeight > 8
                ? _headerTops.last + viewportHeight - _contentHeight
                : 8.0);
        if (_headerHeight == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _measureItemHeights());
        }
        return Stack(
          children: [
            SingleChildScrollView(
              controller: _hScrollCtl,
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: effectiveWidth,
                child: ListView.builder(
                  controller: _vScrollCtl,
                  padding: EdgeInsets.only(bottom: bottomPad),
                  itemCount: _items!.length,
                  itemBuilder: (_, i) {
                    final item = _items![i];
                    if (item is _HeaderItem) {
                      return DiffHunkHeader(
                        key: _headerKeys[item.index],
                        index: item.index,
                        hunk: item.hunk,
                        width: effectiveWidth,
                        viewportWidth: viewportWidth,
                        scroll: _hScrollCtl,
                        onPrev: item.index > 0 ? () => _jumpToHunk(item.index - 1) : null,
                        onNext: item.index < hunks.length - 1
                            ? () => _jumpToHunk(item.index + 1)
                            : null,
                      );
                    }
                    final li = item as _LineItem;
                    return DiffRow(
                      key: i == _firstLineItemIndex ? _firstLineKey : null,
                      line: li.line,
                      span: _spanForLine(li),
                      gutterWidth: gutterWidth,
                      base: base,
                      addBg: a.diffAddBg,
                      delBg: a.diffDelBg,
                      addFg: a.diffAddFg,
                      delFg: a.diffDelFg,
                      muted: muted,
                    );
                  },
                ),
              ),
            ),
            ValueListenableBuilder<_StickyState>(
              valueListenable: _sticky,
              builder: (context, sticky, _) {
                if (sticky.index < 0) return const SizedBox.shrink();
                return Positioned(
                  top: sticky.shift,
                  left: 0,
                  right: 0,
                  child: DiffHunkHeader(
                    index: sticky.index,
                    hunk: hunks[sticky.index],
                    width: viewportWidth,
                    viewportWidth: viewportWidth,
                    overlay: true,
                    scroll: _hScrollCtl,
                    onPrev: sticky.index > 0
                        ? () => _jumpToHunk(sticky.index - 1)
                        : null,
                    onNext: sticky.index < hunks.length - 1
                        ? () => _jumpToHunk(sticky.index + 1)
                        : null,
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }
}

const _fontSize = 12.5;
const _gutterGap = 6.0;
const _padLeft = 8.0;
const _padRight = 20.0;
const _hunkHPad = 12.0;
const _navBtnMin = 22.0;

abstract class _DiffItem {}

class _HeaderItem extends _DiffItem {
  final int index;
  final DiffHunk hunk;
  _HeaderItem({required this.index, required this.hunk});
}

class _LineItem extends _DiffItem {
  final int hunkIndex;
  final DiffLine line;
  final bool useOld;
  final int spanIndex;
  _LineItem({
    required this.hunkIndex,
    required this.line,
    required this.useOld,
    required this.spanIndex,
  });
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

class _StickyState {
  final int index;
  final double shift;
  const _StickyState(this.index, this.shift);
  @override
  bool operator ==(Object other) =>
      other is _StickyState && other.index == index && other.shift == shift;
  @override
  int get hashCode => Object.hash(index, shift);
}

class DiffHunkHeader extends StatelessWidget {
  final int index;
  final DiffHunk hunk;
  final double width;
  final double viewportWidth;
  final bool overlay;
  final ScrollController scroll;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const DiffHunkHeader({
    super.key,
    required this.index,
    required this.hunk,
    required this.width,
    required this.viewportWidth,
    this.overlay = false,
    required this.scroll,
    this.onPrev,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    final surface = Theme.of(context).colorScheme.surfaceContainerLow;
    final newStart = hunk.newStart;
    var newCount = 0;
    for (final l in hunk.lines) {
      if (l.kind == ' ' || l.kind == '+') newCount++;
    }
    final newEnd = (newStart == null || newCount == 0)
        ? null
        : newStart + newCount - 1;
    final left = Row(
      mainAxisSize: MainAxisSize.min,
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
      ],
    );
    final cluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        DiffStat(add: hunk.additions, del: hunk.deletions),
        const SizedBox(width: 4),
        _HunkNavButton(
          icon: Icons.keyboard_arrow_up,
          onPressed: onPrev,
        ),
        _HunkNavButton(
          icon: Icons.keyboard_arrow_down,
          onPressed: onNext,
        ),
      ],
    );
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: surface,
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: AnimatedBuilder(
        animation: scroll,
        builder: (context, _) {
          final hOffset = scroll.hasClients ? scroll.offset : 0.0;
          final raw = width - viewportWidth + _hunkHPad - hOffset;
          final right = raw < _hunkHPad ? _hunkHPad : raw;
          final leftPadded = Padding(
            padding: const EdgeInsets.only(left: _hunkHPad),
            child: left,
          );
          return Stack(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(minHeight: _navBtnMin),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: overlay
                      ? Transform.translate(
                          offset: Offset(-hOffset, 0),
                          child: leftPadded,
                        )
                      : leftPadded,
                ),
              ),
              Positioned(
                right: right,
                top: 0,
                bottom: 0,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: cluster,
                ),
              ),
            ],
          );
        },
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

class _HunkNavButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  const _HunkNavButton({required this.icon, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon),
      iconSize: 16,
      color: muted,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: _navBtnMin, minHeight: _navBtnMin),
    );
  }
}
