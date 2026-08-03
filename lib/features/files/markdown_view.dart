import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../ui/theme.dart';
import 'code_view.dart';
import 'file_browsing_container.dart';
import 'highlight_theme.dart';

class MarkdownView extends StatelessWidget {
  final String content;
  final bool showSource;
  final bool wrap;
  final String sessionId;
  final String path;
  final String? directory;
  final ScrollController? scrollController;

  const MarkdownView({
    super.key,
    required this.content,
    required this.showSource,
    required this.wrap,
    required this.sessionId,
    required this.path,
    this.directory,
    this.scrollController,
  });

  @override
  Widget build(BuildContext context) {
    if (showSource) {
      return CodeView(
        content: content,
        language: 'markdown',
        wrap: wrap,
        scrollController: scrollController,
      );
    }
    return _preview(context);
  }

  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onSurface;
    final appColors = theme.extension<AppColors>()!;
    final mdBase = MarkdownStyleSheet.fromTheme(theme);
    final (:frontMatter, :body) = splitFrontMatter(content);
    return SingleChildScrollView(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (frontMatter != null)
            _FrontMatterCard(
              entries: frontMatter,
              appColors: appColors,
              baseColor: baseColor,
            ),
          MarkdownBody(
            data: body,
            selectable: true,
            builders: {
              'pre': _CodeBlockBuilder(
                brightness: theme.brightness,
                appColors: appColors,
              ),
            },
            onTapLink: (text, href, title) => _openLink(context, href),
            styleSheet: mdBase.copyWith(
              p: TextStyle(fontSize: 14, height: 1.45, color: baseColor),
              pPadding: const EdgeInsets.only(bottom: 6),
              strong: TextStyle(fontWeight: FontWeight.w600, color: baseColor),
              h1: mdBase.h1?.copyWith(color: baseColor),
              h2: mdBase.h2?.copyWith(color: baseColor),
              h3: mdBase.h3?.copyWith(color: baseColor),
              h4: mdBase.h4?.copyWith(color: baseColor),
              h5: mdBase.h5?.copyWith(color: baseColor),
              h6: mdBase.h6?.copyWith(color: baseColor),
              em: mdBase.em?.copyWith(color: baseColor),
              del: mdBase.del?.copyWith(color: baseColor),
              tableHead: mdBase.tableHead?.copyWith(color: baseColor),
              tableBody: mdBase.tableBody?.copyWith(color: baseColor),
              tableBorder: TableBorder.all(color: appColors.border),
              tableColumnWidth: const IntrinsicColumnWidth(),
              tableScrollbarThumbVisibility: false,
              horizontalRuleDecoration: BoxDecoration(
                border: Border(top: BorderSide(color: appColors.border, width: 1)),
              ),
              a: TextStyle(color: appColors.link),
              code: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: appColors.code,
              ),
              listBullet: TextStyle(color: baseColor),
              blockquote: TextStyle(color: baseColor, fontStyle: FontStyle.italic),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(color: appColors.quoteBar, width: 3),
                ),
              ),
              blockquotePadding: const EdgeInsets.only(left: 12),
            ),
          ),
        ],
      ),
    );
  }

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
  ///
  /// Parsing notes:
  ///  - block scalars (`|` / `>`) and their indented continuation lines are
  ///    consumed and folded into the entry value,
  ///  - indented lines (nested mappings / sequences) and colon-less lines are
  ///    skipped rather than aborting the whole block,
  ///  - container keys whose value is empty but that have indented children
  ///    (e.g. `colors:`) are omitted from the metadata card to avoid noise,
  ///  - quoted values are unwrapped; quoted strings with embedded colons are
  ///    split on the first `:`.
  static ({List<({String key, String value})>? frontMatter, String body}) splitFrontMatter(
    String content,
  ) {
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

  static bool _isIndented(String line) {
    if (line.isEmpty) return false;
    final c = line.codeUnitAt(0);
    return c == 0x20 || c == 0x09;
  }

  static String? _blockScalarKind(String value) {
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

  void _openLink(BuildContext context, String? href) {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('#')) return;
    final uri = Uri.parse(href);
    if (uri.hasScheme) {
      _launchExternal(uri);
      return;
    }
    final resolved = _resolvePath(href);
    FileBrowsingContainer.maybeOf(context)?.openFile(resolved);
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  String _resolvePath(String href) {
    if (href.startsWith('/')) {
      return Uri.parse(href).normalizePath().path.replaceFirst('/', '');
    }
    final parent = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '';
    final joined = parent.isEmpty ? href : '$parent/$href';
    return Uri.parse(joined).normalizePath().path;
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.brightness, required this.appColors});

  final Brightness brightness;
  final AppColors appColors;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    var code = element.textContent;
    String? lang;
    final children = element.children;
    if (children != null) {
      for (final c in children) {
        if (c is md.Element && c.tag == 'code') {
          code = c.textContent;
          final cls = c.attributes['class'];
          if (cls != null && cls.startsWith('language-')) {
            lang = cls.substring('language-'.length);
          }
          break;
        }
      }
    }
    if (code.endsWith('\n')) code = code.substring(0, code.length - 1);

    final base = AppTheme.mono.copyWith(fontSize: 13);
    final spans = HighlightPainter.highlight(
      code,
      lang ?? '',
      base,
      brightness,
    );
    final inline = <InlineSpan>[];
    for (var i = 0; i < spans.length; i++) {
      if (i > 0) inline.add(TextSpan(text: '\n', style: base));
      inline.add(spans[i]);
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      clipBehavior: Clip.hardEdge,
      decoration: BoxDecoration(
        color: appColors.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appColors.border),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(12),
        child: SelectableText.rich(
          TextSpan(children: inline, style: base),
        ),
      ),
    );
  }
}

class _FrontMatterCard extends StatelessWidget {
  const _FrontMatterCard({
    required this.entries,
    required this.appColors,
    required this.baseColor,
  });

  final List<({String key, String value})> entries;
  final AppColors appColors;
  final Color baseColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: appColors.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                entries[i].key,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: baseColor.withValues(alpha: 0.55),
                  letterSpacing: 0.4,
                ),
              ),
            ),
            SelectableText(
              entries[i].value,
              style: TextStyle(
                fontSize: 13,
                height: 1.4,
                color: baseColor,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
