import 'package:flutter/material.dart';

import 'code_view.dart';
import 'preview_web_view.dart';

/// Dispatches an HTML file between rendered preview (WebView) and source
/// view (`CodeView`). Mirrors `MarkdownView`: the preview document build and
/// link routing live in `html_preview.dart` / `preview_web_view.dart`; this
/// widget only selects the mode. Preview is the default — the source mode is
/// a manual toggle (or a diff line anchor / sealed-snapshot restore).
class HtmlView extends StatelessWidget {
  final String content;
  final bool showSource;
  final bool wrap;
  final String path;
  final String? directory;
  final ScrollController? scrollController;
  final double? initialScrollOffset;
  final void Function(double)? onScrolled;

  /// Pre-built preview document. Only meaningful in preview mode; see
  /// [PreviewWebView.prebuiltHtml].
  final String? prebuiltHtml;

  /// First-render signal from the preview WebView; see
  /// [PreviewWebView.onFirstRendered]. Preview mode only.
  final VoidCallback? onFirstRendered;

  const HtmlView({
    super.key,
    required this.content,
    required this.showSource,
    required this.wrap,
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
        language: 'html',
        wrap: wrap,
        scrollController: scrollController,
      );
    }
    return PreviewWebView(
      kind: PreviewKind.html,
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
