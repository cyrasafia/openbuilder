import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'highlight_theme.dart';

const _gutterGap = 6.0;
const _gutterPad = 4.0;
const _padLeft = 8.0;
const _padRight = 20.0;
const codeFontSize = 12.5;

/// Explicit line-height multiplier for code/diff rows. Without it the line
/// box comes from per-glyph font metrics, so rows containing emoji / symbol
/// fallback glyphs render taller than plain rows and offset math assuming a
/// uniform row height (diff→file line anchor) drifts.
const codeLineHeight = 1.44;
const codeListVerticalPadding = 8.0;

// Extra bottom padding appended to the code list so the user can keep
// scrolling past the last line until it reaches the top of the viewport.
// Sized to the available viewport height (minus the list's own top/bottom
// padding and a one-row buffer so the last line isn't flush against the
// top edge) via LayoutBuilder, so it scales correctly with font size, text
// scaler, and screen size.

TextStyle codeTextStyle({double fontSize = codeFontSize}) =>
    AppTheme.mono.copyWith(fontSize: fontSize, height: codeLineHeight);

/// Forces every code/diff row to exactly fontSize × codeLineHeight.
/// TextStyle.height alone does NOT constrain fallback-font runs (color
/// emoji glyphs are measured with their own font metrics), so rows with
/// emoji still grow taller; only a forced strut guarantees uniform rows.
const codeStrutStyle = StrutStyle(
  fontSize: codeFontSize,
  height: codeLineHeight,
  forceStrutHeight: true,
);

/// Number of widest-by-estimate lines actually laid out by `_maxContentWidth`.
const _measureCandidates = 8;

class CodeView extends StatefulWidget {
  final String content;
  final String? language;
  final bool wrap;
  final ScrollController? scrollController;

  /// Pre-computed highlight spans (built off the UI isolate during the file
  /// view's loading phase). When provided they are adopted as-is and no
  /// in-widget highlighting runs, keeping the mount frame cheap.
  /// [prebuiltBrightness] is the brightness the spans were built under; a
  /// mismatch with the current theme triggers a re-highlight.
  final List<TextSpan>? prebuiltSpans;
  final Brightness? prebuiltBrightness;

  const CodeView({
    super.key,
    required this.content,
    this.language,
    required this.wrap,
    this.scrollController,
    this.prebuiltSpans,
    this.prebuiltBrightness,
  });

  @override
  State<CodeView> createState() => _CodeViewState();
}

class _CodeViewState extends State<CodeView> {
  late List<String> _lines;
  List<TextSpan>? _lineSpans;
  Brightness? _highlightedBrightness;
  int _highlightGen = 0;
  double? _maxWidthCache;
  double? _gutterWidthCache;
  TextScaler _textScaler = TextScaler.noScaling;

  @override
  void initState() {
    super.initState();
    _lines = widget.content.split('\n');
    _lineSpans = widget.prebuiltSpans;
    _highlightedBrightness = widget.prebuiltBrightness;
  }

  @override
  void didUpdateWidget(covariant CodeView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.content != oldWidget.content ||
        widget.language != oldWidget.language) {
      _lines = widget.content.split('\n');
      _lineSpans = null;
      _maxWidthCache = null;
      _gutterWidthCache = null;
      final brightness = Theme.of(context).brightness;
      _highlightedBrightness = brightness;
      _beginHighlight(brightness);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    if (_highlightedBrightness != brightness) {
      _highlightedBrightness = brightness;
      _beginHighlight(brightness);
    }
    final scaler = MediaQuery.textScalerOf(context);
    if (_textScaler != scaler) {
      _textScaler = scaler;
      _maxWidthCache = null;
      _gutterWidthCache = null;
    }
  }

  Future<void> _beginHighlight(Brightness brightness) async {
    final lang = widget.language;
    if (lang == null) return;
    final gen = ++_highlightGen;
    final base = _base;
    List<TextSpan> result;
    try {
      result = await compute(
        highlightOffIsolate,
        HighlightTask(widget.content, lang, base, brightness),
      );
    } catch (_) {
      // Highlighting is best-effort: keep the plain spans, and clear the
      // recorded brightness so a later didChangeDependencies (any inherited
      // change) retries instead of seeing "already highlighted" forever.
      if (mounted && gen == _highlightGen) _highlightedBrightness = null;
      return;
    }
    if (mounted && gen == _highlightGen) setState(() => _lineSpans = result);
  }

  TextSpan _plainSpan(int i) => TextSpan(text: _lines[i], style: _base);

  TextStyle get _base => codeTextStyle();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    final gutterStyle = _base.copyWith(color: muted);
    final gutterWidth = _gutterWidth();

    Widget rowBuilder(BuildContext _, int i) {
      final span = (_lineSpans != null && i < _lineSpans!.length)
          ? _lineSpans![i]
          : _plainSpan(i);
      final rich = TextSpan(children: [span], style: _base);
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: gutterWidth,
            child: Text(
              '${i + 1}',
              style: gutterStyle,
              textAlign: TextAlign.right,
              strutStyle: codeStrutStyle,
            ),
          ),
          const SizedBox(width: _gutterGap),
          Expanded(
            child: SelectableText.rich(
              rich,
              maxLines: widget.wrap ? null : 1,
              strutStyle: codeStrutStyle,
            ),
          ),
        ],
      );
    }

    final rowHeight =
        MediaQuery.textScalerOf(context).scale(codeFontSize) * codeLineHeight;

    Widget buildList(double viewportHeight) {
      final extra = (viewportHeight - codeListVerticalPadding * 2 - rowHeight)
          .clamp(0.0, double.infinity);
      return ListView.builder(
        controller: widget.scrollController,
        padding: EdgeInsets.only(
          left: _padLeft,
          right: _padRight,
          top: codeListVerticalPadding,
          bottom: codeListVerticalPadding + extra,
        ),
        itemCount: _lines.length,
        itemBuilder: rowBuilder,
      );
    }

    if (widget.wrap) {
      return LayoutBuilder(
        builder: (_, constraints) => buildList(constraints.maxHeight),
      );
    }

    final contentWidth = _maxContentWidth();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: gutterWidth + _gutterGap + contentWidth + _padLeft + _padRight,
        child: LayoutBuilder(
          builder: (_, constraints) => buildList(constraints.maxHeight),
        ),
      ),
    );
  }

  double _gutterWidth() {
    final cached = _gutterWidthCache;
    if (cached != null) return cached;
    final digits = _lines.length.toString().length;
    final tp = TextPainter(
      text: TextSpan(text: '0' * digits, style: _base),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return _gutterWidthCache = w + _gutterPad;
  }

  double _maxContentWidth() {
    final cached = _maxWidthCache;
    if (cached != null) return cached;
    final style = _base;
    final unitPainter = TextPainter(
      text: TextSpan(text: '0', style: style),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    )..layout();
    final unit = unitPainter.width;
    unitPainter.dispose();

    // Rank lines by an O(N) width estimate, then lay out only the top
    // candidates. The old approach laid out every line, and that O(N)
    // TextPainter cost dominated the content mount frame. A ranking miss
    // (true widest line outside the top candidates) slightly understates the
    // scroll extent; the generous wide-rune table makes that unlikely.
    final topIdx = <int>[];
    final topEst = <double>[];
    for (var i = 0; i < _lines.length; i++) {
      final est = estimateLineWidthUnits(_lines[i]);
      if (est <= 0) continue;
      var pos = topEst.length;
      while (pos > 0 && topEst[pos - 1] < est) {
        pos--;
      }
      if (pos >= _measureCandidates) continue;
      topIdx.insert(pos, i);
      topEst.insert(pos, est);
      if (topIdx.length > _measureCandidates) {
        topIdx.removeLast();
        topEst.removeLast();
      }
    }

    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    );
    var widest = 0.0;
    for (final i in topIdx) {
      tp.text = TextSpan(text: _lines[i], style: style);
      tp.layout();
      if (tp.width > widest) widest = tp.width;
    }
    tp.dispose();
    return _maxWidthCache = widest + unit;
  }
}

/// Width of [line] in monospace cell units: ASCII one cell, wide (CJK /
/// fullwidth / emoji-class) runes two, tab eight. Used to rank lines so only
/// the widest candidates need a real `TextPainter.layout`.
@visibleForTesting
double estimateLineWidthUnits(String line) {
  var units = 0.0;
  for (final r in line.runes) {
    if (r == 0x09) {
      units += 8;
    } else if (_isWideRune(r)) {
      units += 2;
    } else {
      units += 1;
    }
  }
  return units;
}

bool _isWideRune(int r) =>
    (r >= 0x1100 && r <= 0x115F) ||
    (r >= 0x2600 && r <= 0x27BF) ||
    (r >= 0x2B00 && r <= 0x2BFF) ||
    (r >= 0x2E80 && r <= 0xA4CF) ||
    (r >= 0xAC00 && r <= 0xD7A3) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    (r >= 0xFE30 && r <= 0xFE4F) ||
    (r >= 0xFF00 && r <= 0xFF60) ||
    (r >= 0xFFE0 && r <= 0xFFE6) ||
    (r >= 0x1F000 && r <= 0x1FAFF) ||
    (r >= 0x20000 && r <= 0x3FFFD);
