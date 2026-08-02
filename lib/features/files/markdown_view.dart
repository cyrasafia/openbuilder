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
  /// Front matter must:
  ///  - start at the very first byte (no leading whitespace / BOM),
  ///  - be fenced by lines containing exactly `---`,
  ///  - contain at least one `key: value` line,
  /// otherwise the whole content is treated as the body. This is a minimal
  /// parser: it does not support multi-line YAML values, quoted strings with
  /// embedded colons are best-effort split on the first `:`.
  static ({List<({String key, String value})>? frontMatter, String body}) splitFrontMatter(
    String content,
  ) {
    if (!content.startsWith('---')) {
      return (frontMatter: null, body: content);
    }
    final lines = content.split('\n');
    if (lines.length < 4) return (frontMatter: null, body: content);
    if (lines.first.trim() != '---') return (frontMatter: null, body: content);
    var end = -1;
    for (var i = 1; i < lines.length; i++) {
      if (lines[i].trim() == '---') {
        end = i;
        break;
      }
    }
    if (end <= 1) return (frontMatter: null, body: content);
    final rawEntries = <({String key, String value})>[];
    for (var i = 1; i < end; i++) {
      final line = lines[i];
      if (line.trim().isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        return (frontMatter: null, body: content);
      }
      var key = line.substring(0, colon).trim();
      var value = line.substring(colon + 1).trim();
      if (key.isEmpty) {
        return (frontMatter: null, body: content);
      }
      if ((value.startsWith('"') && value.endsWith('"')) ||
          (value.startsWith("'") && value.endsWith("'"))) {
        value = value.substring(1, value.length - 1);
      }
      if (value.isEmpty) value = '—';
      rawEntries.add((key: key, value: value));
    }
    if (rawEntries.isEmpty) return (frontMatter: null, body: content);
    final bodyStart = end + 1;
    final body = bodyStart >= lines.length
        ? ''
        : (lines[bodyStart] == '' ? lines.sublist(bodyStart + 1) : lines.sublist(bodyStart)).join('\n');
    return (frontMatter: rawEntries, body: body);
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
