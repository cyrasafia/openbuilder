import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../../ui/theme.dart';
import 'code_view.dart';
import 'highlight_theme.dart';

class MarkdownView extends StatelessWidget {
  final String content;
  final bool showSource;
  final bool wrap;
  final String sessionId;
  final String path;
  final String? directory;

  const MarkdownView({
    super.key,
    required this.content,
    required this.showSource,
    required this.wrap,
    required this.sessionId,
    required this.path,
    this.directory,
  });

  @override
  Widget build(BuildContext context) {
    if (showSource) {
      return CodeView(content: content, language: 'markdown', wrap: wrap);
    }
    return _preview(context);
  }

  Widget _preview(BuildContext context) {
    final theme = Theme.of(context);
    final baseColor = theme.colorScheme.onSurface;
    final appColors = theme.extension<AppColors>()!;
    final mdBase = MarkdownStyleSheet.fromTheme(theme);
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: MarkdownBody(
        data: content,
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
          blockquote: TextStyle(
            color: baseColor,
            fontStyle: FontStyle.italic,
          ),
          blockquoteDecoration: BoxDecoration(
            border: Border(left: BorderSide(color: appColors.quoteBar, width: 3)),
          ),
          blockquotePadding: const EdgeInsets.only(left: 12),
        ),
      ),
    );
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
    context.push(
      '/session/$sessionId/file'
      '?path=${Uri.encodeQueryComponent(resolved)}'
      '&directory=${Uri.encodeQueryComponent(directory ?? '')}',
    );
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
    final parent =
        path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
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
    final spans = HighlightPainter.highlight(code, lang ?? '', base, brightness);
    final inline = <InlineSpan>[];
    for (var i = 0; i < spans.length; i++) {
      if (i > 0) inline.add(TextSpan(text: '\n', style: base));
      inline.add(spans[i]);
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: appColors.codeBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: appColors.border),
      ),
      child: SelectableText.rich(TextSpan(children: inline, style: base)),
    );
  }
}
