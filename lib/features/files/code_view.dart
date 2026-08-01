import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import 'highlight_theme.dart';

const _gutterGap = 6.0;
const _gutterPad = 4.0;
const _padLeft = 8.0;
const _padRight = 20.0;
const _fontSize = 12.5;
const _asyncThreshold = 2000;

class CodeView extends StatefulWidget {
  final String content;
  final String? language;
  final bool wrap;

  const CodeView({
    super.key,
    required this.content,
    this.language,
    required this.wrap,
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

    if (_lines.length <= _asyncThreshold) {
      final spans =
          HighlightPainter.highlight(widget.content, lang, base, brightness);
      if (gen == _highlightGen) setState(() => _lineSpans = spans);
      return;
    }

    final result = await compute(
      _highlightInBackground,
      _HighlightTask(widget.content, lang, base, brightness),
    );
    if (mounted && gen == _highlightGen) setState(() => _lineSpans = result);
  }

  TextSpan _plainSpan(int i) => TextSpan(text: _lines[i], style: _base);

  TextStyle get _base => AppTheme.mono.copyWith(fontSize: _fontSize);

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
            ),
          ),
          const SizedBox(width: _gutterGap),
          Expanded(
            child: SelectableText.rich(
              rich,
              maxLines: widget.wrap ? null : 1,
            ),
          ),
        ],
      );
    }

    final listView = ListView.builder(
      padding: const EdgeInsets.only(left: _padLeft, right: _padRight, top: 8, bottom: 8),
      itemCount: _lines.length,
      itemBuilder: rowBuilder,
    );

    if (widget.wrap) return listView;

    final contentWidth = _maxContentWidth();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SizedBox(
        width: gutterWidth + _gutterGap + contentWidth + _padLeft + _padRight,
        child: listView,
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
    final tp = TextPainter(
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
      maxLines: 1,
    );
    var widest = 0.0;
    for (final l in _lines) {
      tp.text = TextSpan(text: l, style: style);
      tp.layout();
      if (tp.width > widest) widest = tp.width;
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
}

List<TextSpan> _highlightInBackground(_HighlightTask t) =>
    HighlightPainter.highlight(t.code, t.language, t.base, t.brightness);

class _HighlightTask {
  final String code;
  final String language;
  final TextStyle base;
  final Brightness brightness;
  const _HighlightTask(this.code, this.language, this.base, this.brightness);
}
