import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart';

import '../../ui/theme.dart';
import 'highlight_theme.dart';
import 'markdown_css.dart';

/// Splits optional YAML front matter (`---\n...\n---`) from the body.
///
/// Front matter is detected when the content:
///  - starts at the very first byte (no leading whitespace / BOM),
///  - is fenced by lines containing exactly `---`,
///  - contains at least one `key: value` mapping line at any indent level
///    (so a header that is only nested containers still counts, while a
///    `---` horizontal-rule sandwich with no mappings does not).
/// Once detected the YAML header is always stripped from the body so it
/// never renders as raw YAML; the metadata card is best-effort and may be
/// omitted entirely (frontMatter == null) when no top-level scalar entries
/// could be extracted — the body is still stripped.
({List<({String key, String value})>? frontMatter, String body})
    splitFrontMatter(String content) {
  if (!content.startsWith('---')) {
    return (frontMatter: null, body: content);
  }
  final lines = content.split('\n');
  if (lines.isEmpty || lines.first.trim() != '---') {
    return (frontMatter: null, body: content);
  }
  var end = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].trim() == '---') {
      end = i;
      break;
    }
  }
  if (end <= 1) return (frontMatter: null, body: content);
  final entries = <({String key, String value})>[];
  var sawMapping = false;
  var i = 1;
  while (i < end) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      continue;
    }
    final trimmed = line.trim();
    final tcolon = trimmed.indexOf(':');
    if (tcolon > 0) sawMapping = true;
    if (_isIndented(line)) {
      i++;
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) {
      i++;
      continue;
    }
    final key = line.substring(0, colon).trim();
    final rawValue = line.substring(colon + 1).trim();
    if (key.isEmpty) {
      i++;
      continue;
    }
    final block = _blockScalarKind(rawValue);
    if (block != null) {
      final buf = <String>[];
      i++;
      while (i < end) {
        final l = lines[i];
        if (l.trim().isEmpty) {
          buf.add('');
          i++;
          continue;
        }
        if (!_isIndented(l)) break;
        buf.add(l.trim());
        i++;
      }
      final joined = buf
          .where((s) => s.isNotEmpty)
          .join(block == 'folded' ? ' ' : '\n');
      entries.add((key: key, value: joined.isEmpty ? '—' : joined));
      continue;
    }
    var value = rawValue;
    if (value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty) {
      var peek = i + 1;
      while (peek < end && lines[peek].trim().isEmpty) {
        peek++;
      }
      if (peek < end && _isIndented(lines[peek])) {
        i++;
        continue;
      }
      value = '—';
    }
    entries.add((key: key, value: value));
    i++;
  }
  if (!sawMapping) return (frontMatter: null, body: content);
  final bodyStart = end + 1;
  final String body;
  if (bodyStart >= lines.length) {
    body = '';
  } else {
    var s = bodyStart;
    if (lines[s].isEmpty) s++;
    body = lines.sublist(s).join('\n');
  }
  return (frontMatter: entries.isEmpty ? null : entries, body: body);
}

bool _isIndented(String line) {
  if (line.isEmpty) return false;
  final c = line.codeUnitAt(0);
  return c == 0x20 || c == 0x09;
}

String? _blockScalarKind(String value) {
  switch (value) {
    case '|':
    case '|-':
    case '|+':
      return 'literal';
    case '>':
    case '>-':
    case '>+':
      return 'folded';
    default:
      return null;
  }
}

/// Resolves a (possibly relative) markdown link [href] against the file
/// [currentPath] it appears in. Absolute (`/foo`) and already-normal paths
/// are returned relative to the workspace root (no leading slash); relative
/// paths are resolved against the current file's directory.
String resolveRelativePath(String href, String currentPath) {
  if (href.startsWith('/')) {
    return Uri.parse(href).normalizePath().path.replaceFirst('/', '');
  }
  final parent = currentPath.contains('/')
      ? currentPath.substring(0, currentPath.lastIndexOf('/'))
      : '';
  final joined = parent.isEmpty ? href : '$parent/$href';
  return Uri.parse(joined).normalizePath().path;
}

final _fencedCodeRe =
    RegExp(r'<pre><code(?:\s+class="language-([^"]*)")?>([\s\S]*?)</code></pre>');

String _unescapeHtml(String s) {
  return s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&#x27;', "'")
      .replaceAll('&amp;', '&');
}

String _escapeHtml(String s) {
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#x27;');
}

/// Re-highlights fenced code blocks produced by `package:markdown` with the
/// shared `re_highlight` source, returning HTML whose `<code>` inner markup
/// uses `tok-*` spans (colored via CSS). Unknown/empty languages fall back to
/// escaped plain text so the block still renders safely.
String _highlightCodeBlocks(String html) {
  return html.replaceAllMapped(_fencedCodeRe, (m) {
    final lang = (m.group(1) ?? '').trim();
    final raw = m.group(2) ?? '';
    var code = _unescapeHtml(raw);
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);
    final highlighted = HighlightPainter.highlightToHtml(code, lang);
    final cls = lang.isEmpty ? '' : ' class="language-${_escapeAttr(lang)}"';
    return '<pre><code$cls>$highlighted</code></pre>';
  });
}

String _escapeAttr(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('"', '&quot;');

String _frontMatterHtml(List<({String key, String value})> entries) {
  final rows = StringBuffer();
  for (final e in entries) {
    rows.write('<div class="fm-row">');
    rows.write('<div class="fm-key">${_escapeHtml(e.key)}</div>');
    rows.write('<div class="fm-val">${_escapeHtml(e.value)}</div>');
    rows.write('</div>');
  }
  return '<div class="frontmatter">$rows</div>';
}

/// Builds a self-contained HTML document for the Markdown preview WebView.
/// Front matter (if any) renders as a metadata card above the body; code
/// blocks are pre-highlighted with `tok-*` spans; all colors/weights come
/// from the inline `<style>` generated from the current theme.
String buildMarkdownPreviewHtml({
  required String content,
  required Brightness brightness,
  required Color scaffoldBg,
  required Color onSurface,
  required AppColors appColors,
}) {
  final (:frontMatter, :body) = splitFrontMatter(content);
  var html = markdownToHtml(body, extensionSet: ExtensionSet.gitHubWeb);
  html = _highlightCodeBlocks(html);
  final css = markdownPreviewCss(
    brightness: brightness,
    scaffoldBg: scaffoldBg,
    onSurface: onSurface,
    appColors: appColors,
  );
  final fm = frontMatter == null ? '' : _frontMatterHtml(frontMatter);
  // Restrictive CSP: block every script (inline + external), iframe, and
  // external resource so raw HTML passed through by `package:markdown` is
  // inert. Inline styles are allowed (the stylesheet is embedded); images may
  // be data/blob URIs. Scripts injected by the host via the WebView's
  // evaluateJavascript API (the link/scroll bridge) are NOT subject to CSP, so
  // the bridge keeps working.
  const csp = "default-src 'none'; style-src 'unsafe-inline';"
      " img-src data: blob:; font-src data:;";
  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta http-equiv="Content-Security-Policy" content="$csp">'
      '<meta name="viewport" content="width=device-width, initial-scale=1.0, '
      'maximum-scale=1.0, user-scalable=no">'
      '<style>$css</style></head><body>'
      '<div class="md">$fm$html</div></body></html>';
}
