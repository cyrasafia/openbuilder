import 'package:flutter/material.dart';

import 'code_view.dart';
import 'markdown_web_view.dart';

/// Dispatches a Markdown file between rendered preview (WebView) and source
/// view (`CodeView`). The preview rendering, front-matter handling, code
/// highlighting and link routing live in `markdown_html.dart` /
/// `markdown_web_view.dart`; this widget only selects the mode.
class MarkdownView extends StatelessWidget {
  final String content;
  final bool showSource;
  final bool wrap;
  final String sessionId;
  final String path;
  final String? directory;
  final ScrollController? scrollController;
  final double? initialScrollOffset;
  final void Function(double)? onScrolled;

  /// Pre-built preview HTML (off-isolate). Only meaningful in preview mode;
  /// see [MarkdownWebView.prebuiltHtml].
  final String? prebuiltHtml;

  /// First-render signal from the preview WebView; see
  /// [MarkdownWebView.onFirstRendered]. Preview mode only.
  final VoidCallback? onFirstRendered;

  const MarkdownView({
    super.key,
    required this.content,
    required this.showSource,
    required this.wrap,
    required this.sessionId,
    required this.path,
    this.directory,
    this.scrollController,
    this.initialScrollOffset,
    this.onScrolled,
    this.prebuiltHtml,
    this.onFirstRendered,
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
    return MarkdownWebView(
      content: content,
      path: path,
      directory: directory,
      initialScrollOffset: initialScrollOffset,
      onScrolled: onScrolled,
      prebuiltHtml: prebuiltHtml,
      onFirstRendered: onFirstRendered,
    );
  }
}
