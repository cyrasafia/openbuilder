/// Builds the WebView document for raw HTML file preview.
///
/// The user's document is rendered as-is (its own markup/styles rule — no
/// theme CSS is injected), but two `<meta>` tags are injected as early as
/// possible to neutralize active content and make phone layout usable:
///  - a restrictive CSP identical to the markdown preview's, so `<script>`,
///    iframes and external resources are inert while inline styles and
///    data/blob-URI resources keep working;
///  - a viewport meta, only when the document doesn't declare its own.
///
/// Injection points are picked by a plain string scan that skips regions the
/// HTML parser never parses tags in (comments, bogus comments, raw-text
/// element bodies, inert `<template>` content, regular tag extents), where a
/// literal `<head>` would never parse as a live tag and the injection would
/// be silently dropped. HTML downloads are uncapped
/// (`DownloadPolicy.immediate`), so the scan guards itself: it is a single
/// left-to-right pass whose every search starts where the previous one
/// ended (linear, no per-region rescans), and files beyond [scanCap] skip
/// the scan entirely and get the metas prepended — the CSP always applies,
/// only the render may degrade to quirks mode. Residual blind spots —
/// tag-looking literals inside attribute values that the naive first-`>`
/// tag-extent scan misjudges — can still swallow the injection; when no
/// active injection point is found at all, the prepend fallback keeps the
/// CSP effective.
library;

import 'package:flutter/foundation.dart';

final _headOpenRe = RegExp(r'<head(?:\s[^>]*)?>', caseSensitive: false);
final _htmlOpenRe = RegExp(r'<html(?:\s[^>]*)?>', caseSensitive: false);
// A viewport declaration: quoted or unquoted attribute values, and only a
// real <meta> tag (not SVG's <metadata …>). The attribute name must be a
// whole word (`\sname=`, not `data-name=`), and unquoted values terminate
// at whitespace, '>' or '/'.
final _viewportRe = RegExp(
  r'''<meta(?=[\s/>])[^>]*\sname\s*=\s*("viewport"|'viewport'|viewport(?=[\s/>]))''',
  caseSensitive: false,
);

const _csp =
    "default-src 'none'; style-src 'unsafe-inline'; img-src data: blob:;"
    ' font-src data:';
const _cspMeta = '<meta http-equiv="Content-Security-Policy" content="$_csp">';
const _viewportMeta =
    '<meta name="viewport" content="width=device-width, initial-scale=1.0">';

/// Upper bound for the injection-point scan. Matches the content-cache
/// single-file cap; beyond it the document is pathological and the metas
/// are prepended without scanning.
@visibleForTesting
const scanCap = 8 << 20;

String buildHtmlPreviewDocument(String content) {
  if (content.length > scanCap) return '$_cspMeta$_viewportMeta$content';
  final lower = content.toLowerCase();
  final inactive = _inactiveRegions(lower);
  bool active(int i) => !inactive.any((r) => i > r.$1 && i < r.$2);
  final metas = _viewportRe.allMatches(content).any((m) => active(m.start))
      ? _cspMeta
      : '$_cspMeta$_viewportMeta';
  for (final m in _headOpenRe.allMatches(content)) {
    if (!active(m.start)) continue;
    return content.replaceRange(m.end, m.end, metas);
  }
  for (final m in _htmlOpenRe.allMatches(content)) {
    if (!active(m.start)) continue;
    return content.replaceRange(m.end, m.end, '<head>$metas</head>');
  }
  return '$metas$content';
}

/// Character ranges the HTML parser never parses tags in. One strict
/// left-to-right pass — every `indexOf` starts where the previous structure
/// ended, so each position is examined a constant number of times (linear
/// overall; restarting any search from the region cursor would make dense
/// documents quadratic). Per `<`, the region kind mirrors tokenizer states:
///  - `<!--` comment (to `-->`), `<?`/`<!…` bogus comment incl. doctype and
///    CDATA (to the first `>`), unclosed → swallow to EOF, like the parser;
///  - a [_rawTextTags] open (to a real `</tag` close — terminator-checked,
///    so `</scriptx` inside script data does not end the region — or EOF;
///    `plaintext` has no close per spec and always swallows to EOF);
///  - any other tag-like `<` (regular open/close tag): its extent up to the
///    first `>` is one region, so attribute-value literals don't count as
///    active injection points; a bare `<` not opening a tag is text and the
///    scan just steps past it.
List<(int, int)> _inactiveRegions(String lower) {
  final ranges = <(int, int)>[];
  final n = lower.length;
  var i = 0;
  while (true) {
    final lt = lower.indexOf('<', i);
    if (lt < 0) return ranges;
    if (lower.startsWith('<!--', lt)) {
      final close = lower.indexOf('-->', lt + 4);
      final end = close < 0 ? n : close + 3;
      ranges.add((lt, end));
      i = end;
      continue;
    }
    final second = lt + 1 < n ? lower.codeUnitAt(lt + 1) : -1;
    if (second == 0x3F || second == 0x21) {
      final close = lower.indexOf('>', lt + 2);
      final end = close < 0 ? n : close + 1;
      ranges.add((lt, end));
      i = end;
      continue;
    }
    final tag = _rawTextOpenAt(lower, lt);
    if (tag != null) {
      final end = tag == 'plaintext'
          ? n
          : (_rawTextCloseFrom(lower, lt, tag) ?? n);
      ranges.add((lt, end));
      if (end >= n) return ranges;
      i = end;
      continue;
    }
    final isTag = (second >= 0x61 && second <= 0x7A) || second == 0x2F;
    if (!isTag) {
      i = lt + 1;
      continue;
    }
    final gt = lower.indexOf('>', lt + 1);
    if (gt < 0) {
      ranges.add((lt, n));
      return ranges;
    }
    ranges.add((lt, gt + 1));
    i = gt + 1;
  }
}

/// Elements whose content never yields a live injection point: the parser's
/// raw-text elements, plus `<template>` — its content is parsed but inert
/// document-fragment markup, so a `<head>` or viewport meta inside it
/// neither applies nor is a useful injection target.
const _rawTextTags = [
  'script',
  'style',
  'textarea',
  'title',
  'noscript',
  'xmp',
  'noembed',
  'noframes',
  'template',
  'plaintext',
];

bool _isTagBoundary(int ch) =>
    ch == 0x20 ||
    ch == 0x09 ||
    ch == 0x0A ||
    ch == 0x0D ||
    ch == 0x3E ||
    ch == 0x2F;

/// The raw-text tag opened exactly at [lt], if any — the tag name must be
/// followed by whitespace, `/` or `>`, so lookalikes such as `<scriptx>`
/// don't count.
String? _rawTextOpenAt(String lower, int lt) {
  for (final tag in _rawTextTags) {
    if (!lower.startsWith('<$tag', lt)) continue;
    final after = lt + tag.length + 1;
    if (after >= lower.length || _isTagBoundary(lower.codeUnitAt(after))) {
      return tag;
    }
  }
  return null;
}

/// Index just past a real `</tag` close for the raw-text element open at
/// [lt], or null when none exists. The close must be terminator-checked —
/// per the tokenizer `</scriptx` inside script data is not an end tag — and
/// the search is monotonic from the element's content.
int? _rawTextCloseFrom(String lower, int lt, String tag) {
  final needle = '</$tag';
  var i = lt + tag.length + 1;
  while (true) {
    final c = lower.indexOf(needle, i);
    if (c < 0) return null;
    final after = c + needle.length;
    if (after >= lower.length) return null;
    if (_isTagBoundary(lower.codeUnitAt(after))) return after;
    i = after;
  }
}
