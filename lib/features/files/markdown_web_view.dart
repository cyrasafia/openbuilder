import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../ui/theme.dart';
import 'file_browsing_container.dart';
import 'markdown_html.dart';

/// Markdown preview rendered by a full-screen WebView (HCPP on Android 14+).
///
/// `package:markdown` converts the body to HTML, code blocks are pre-highlighted
/// with the shared `re_highlight` source (`tok-*` spans), and all colors /
/// three-tier font weights come from a CSS generated from the current theme.
/// Link taps are intercepted in JS and routed back to Dart so relative links
/// open in the file browser and external links launch the system browser,
/// matching the legacy Flutter-Markdown behavior.
///
/// The WebView manages its own scrolling; the current offset is reported via
/// [onScrolled] and restored from [initialScrollOffset] after each load so the
/// file browser's collapse/restore keeps the reading position.
class MarkdownWebView extends StatefulWidget {
  final String content;
  final String path;
  final String? directory;
  final double? initialScrollOffset;
  final void Function(double offset)? onScrolled;

  const MarkdownWebView({
    super.key,
    required this.content,
    required this.path,
    this.directory,
    this.initialScrollOffset,
    this.onScrolled,
  });

  @override
  State<MarkdownWebView> createState() => _MarkdownWebViewState();
}

const _openLinkChannel = 'OB_OPEN_LINK';
const _scrollChannel = 'OB_SCROLL';

// Intercept <a> clicks and report scroll position. Exposes two JS channels.
const _bridgeScript = r'''
(function(){
  document.addEventListener('click', function(e){
    var n = e.target;
    while (n && n.tagName !== 'A') n = n.parentElement;
    if (n && n.getAttribute('href')) {
      e.preventDefault();
      OB_OPEN_LINK.postMessage(n.getAttribute('href'));
    }
  }, true);
  var t = null;
  window.addEventListener('scroll', function(){
    if (t) return;
    t = setTimeout(function(){ t = null;
      OB_SCROLL.postMessage(String(window.scrollY || 0));
    }, 150);
  }, {passive: true});
})();
''';

class _MarkdownWebViewState extends State<MarkdownWebView> {
  late final WebViewController _controller;
  late String _html;
  double _restoreOffset = 0;

  @override
  void initState() {
    super.initState();
    _restoreOffset = widget.initialScrollOffset ?? 0;
    _html = _buildHtml(context);
    _controller = _buildController();
  }

  WebViewController _buildController() {
    final c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(_scaffoldBg)
      ..setNavigationDelegate(
        NavigationDelegate(
          // Allow only the initial data load (about:blank); block every other
          // navigation, in any frame — links are handled via the JS bridge
          // and embedded iframes must not load (CSP blocks them too, but
          // defense-in-depth).
          onNavigationRequest: (req) async => req.url == 'about:blank'
              ? NavigationDecision.navigate
              : NavigationDecision.prevent,
          onPageFinished: (_) => _onPageLoaded(),
        ),
      )
      ..addJavaScriptChannel(
        _openLinkChannel,
        onMessageReceived: (m) => _onLink(m.message),
      )
      ..addJavaScriptChannel(
        _scrollChannel,
        onMessageReceived: (m) {
          final y = double.tryParse(m.message) ?? 0;
          widget.onScrolled?.call(y);
        },
      )
      ..loadHtmlString(_html);
    return c;
  }

  Color get _scaffoldBg => Theme.of(context).scaffoldBackgroundColor;

  String _buildHtml(BuildContext context) {
    final theme = Theme.of(context);
    final appColors = theme.extension<AppColors>()!;
    return buildMarkdownPreviewHtml(
      content: widget.content,
      brightness: theme.brightness,
      scaffoldBg: theme.scaffoldBackgroundColor,
      onSurface: theme.colorScheme.onSurface,
      appColors: appColors,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeRebuild();
  }

  @override
  void didUpdateWidget(covariant MarkdownWebView old) {
    super.didUpdateWidget(old);
    if (widget.initialScrollOffset != null &&
        widget.initialScrollOffset != old.initialScrollOffset) {
      _restoreOffset = widget.initialScrollOffset!;
    }
    _maybeRebuild();
  }

  /// Regenerates the document when content OR theme changed (compare the full
  /// string so any real change — colors, weights, body — reloads; a length-only
  /// check could miss a theme switch whose output happens to be equally long).
  void _maybeRebuild() {
    final html = _buildHtml(context);
    if (html != _html) {
      _html = html;
      _reload();
    }
  }

  Future<void> _reload() async {
    // Keep the platform background in sync with the (possibly theme-changed)
    // scaffold so there's no white flash before the CSS paints.
    try {
      await _controller.setBackgroundColor(_scaffoldBg);
    } catch (_) {}
    // Preserve the reading position across the theme/content reload.
    try {
      final res = await _controller
          .runJavaScriptReturningResult('window.scrollY || 0');
      final y = res is num ? res.toDouble() : double.tryParse('$res') ?? 0;
      if (y > 0) _restoreOffset = y;
    } catch (_) {}
    try {
      await _controller.loadHtmlString(_html);
    } catch (_) {}
  }

  Future<void> _onPageLoaded() async {
    // (Re)install the link/scroll bridge now that the DOM is ready, then
    // restore the saved reading position.
    try {
      await _controller.runJavaScript(_bridgeScript);
    } catch (_) {}
    await _applyScrollRestore();
  }

  Future<void> _applyScrollRestore() async {
    if (_restoreOffset <= 0) return;
    try {
      await _controller.runJavaScript('window.scrollTo(0,${_restoreOffset.round()})');
    } catch (_) {}
  }

  void _onLink(String? href) {
    if (href == null || href.isEmpty) return;
    if (href.startsWith('#')) return;
    final uri = Uri.tryParse(href);
    if (uri == null) return;
    if (uri.hasScheme) {
      _launchExternal(uri);
      return;
    }
    final resolved = resolveRelativePath(href, widget.path);
    FileBrowsingContainer.maybeOf(context)?.openFile(resolved);
  }

  Future<void> _launchExternal(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return WebViewWidget(controller: _controller);
  }
}
