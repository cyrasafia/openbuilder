import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../ui/theme.dart';
import 'file_browsing_container.dart';
import 'html_preview.dart';
import 'markdown_html.dart';

enum PreviewKind { markdown, html }

/// Document preview rendered by a full-screen WebView (HCPP on Android 14+).
///
/// Markdown content goes through `buildMarkdownPreviewHtml` (`package:markdown`
/// → pre-highlighted code blocks → theme-generated CSS); raw HTML files are
/// previewed as-is with a CSP/viewport meta injected
/// (`buildHtmlPreviewDocument`).
/// Both kinds share everything else: link interception via the JS bridge
/// (relative links open in the file browser, external links launch the system
/// browser), scroll reporting/restore for the file browser's
/// collapse/restore, and the O(1) signature check that decides document
/// rebuilds. The HTML kind's document is theme-independent, so its signature
/// covers content only — a brightness flip never reloads it.
///
/// The WebView manages its own scrolling; the current offset is reported via
/// [onScrolled] and restored from [initialScrollOffset] after each load so the
/// file browser's collapse/restore keeps the reading position.
class PreviewWebView extends StatefulWidget {
  final PreviewKind kind;
  final String content;
  final String path;
  final String? directory;
  final double? initialScrollOffset;
  final void Function(double offset)? onScrolled;

  /// Pre-built preview document (from the FileViewScreen loading-phase
  /// pre-build). Production flows always provide it: FileViewScreen pre-builds
  /// during the loading phase and gates the mount on it — including the
  /// source→preview toggle, which kicks the pre-build before switching. Null
  /// is only a defensive fallback (synchronous in-widget build on first use).
  final String? prebuiltHtml;

  /// Called once when the initial document finishes loading in the WebView
  /// (first `onPageFinished`). Lets the file view keep its loading overlay up
  /// until the preview is actually painted, not merely mounted.
  final VoidCallback? onFirstRendered;

  const PreviewWebView({
    super.key,
    required this.kind,
    required this.content,
    required this.path,
    this.directory,
    this.initialScrollOffset,
    this.onScrolled,
    this.prebuiltHtml,
    this.onFirstRendered,
  });

  @override
  State<PreviewWebView> createState() => _PreviewWebViewState();
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

class _PreviewWebViewState extends State<PreviewWebView> {
  WebViewController? _controller;
  String? _html;
  Object? _builtSignature;
  double _restoreOffset = 0;
  bool _firstRenderReported = false;

  @override
  void initState() {
    super.initState();
    _restoreOffset = widget.initialScrollOffset ?? 0;
    _html = widget.prebuiltHtml;
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
      ..loadHtmlString(_html!);
    return c;
  }

  Color get _scaffoldBg => Theme.of(context).scaffoldBackgroundColor;

  String _buildHtml(BuildContext context) {
    if (widget.kind == PreviewKind.html) {
      return buildHtmlPreviewDocument(widget.content);
    }
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
    // Theme-dependent init (HTML fallback build, controller creation) lives
    // here, not initState: looking up Theme.of in initState throws in debug
    // (framework assert). First call adopts the prebuilt document (if any)
    // or builds one, and records the signature without comparing.
    final c = _controller;
    if (c == null) {
      // A prebuilt document is assumed to have been generated under the
      // current theme (it is built moments before mount, during the loading
      // phase); a theme flip inside that sub-second window would render
      // stale colors until the next theme/content change.
      _html ??= _buildHtml(context);
      _builtSignature = _signature();
      _controller = _buildController();
    } else {
      _maybeRebuild();
    }
  }

  @override
  void didUpdateWidget(covariant PreviewWebView old) {
    super.didUpdateWidget(old);
    if (widget.initialScrollOffset != null &&
        widget.initialScrollOffset != old.initialScrollOffset) {
      _restoreOffset = widget.initialScrollOffset!;
    }
    _maybeRebuild();
  }

  /// Regenerates the document only when the inputs the document derives from
  /// changed. Compares an O(1) signature (content +, for markdown only, the
  /// theme values the HTML/CSS derive from) instead of rebuilding the full
  /// document to compare strings — the old approach paid the markdown
  /// conversion twice per open.
  void _maybeRebuild() {
    final sig = _signature();
    if (sig == _builtSignature) return;
    _builtSignature = sig;
    _html = _buildHtml(context);
    _reload();
  }

  Object _signature() {
    if (widget.kind == PreviewKind.html) return widget.content;
    final theme = Theme.of(context);
    return (
      widget.content,
      theme.brightness,
      theme.scaffoldBackgroundColor,
      theme.colorScheme.onSurface,
      theme.extension<AppColors>()!,
    );
  }

  Future<void> _reload() async {
    final c = _controller;
    final html = _html;
    if (c == null || html == null) return;
    // Keep the platform background in sync with the (possibly theme-changed)
    // scaffold so there's no white flash before the CSS paints.
    try {
      await c.setBackgroundColor(_scaffoldBg);
    } catch (_) {}
    // Preserve the reading position across the theme/content reload.
    try {
      final res = await c.runJavaScriptReturningResult('window.scrollY || 0');
      final y = res is num ? res.toDouble() : double.tryParse('$res') ?? 0;
      if (y > 0) _restoreOffset = y;
    } catch (_) {}
    try {
      await c.loadHtmlString(html);
    } catch (_) {}
  }

  Future<void> _onPageLoaded() async {
    // (Re)install the link/scroll bridge now that the DOM is ready, then
    // restore the saved reading position.
    final c = _controller;
    if (c == null) return;
    if (!_firstRenderReported) {
      _firstRenderReported = true;
      widget.onFirstRendered?.call();
    }
    try {
      await c.runJavaScript(_bridgeScript);
    } catch (_) {}
    await _applyScrollRestore();
  }

  Future<void> _applyScrollRestore() async {
    if (_restoreOffset <= 0) return;
    final c = _controller;
    if (c == null) return;
    try {
      await c.runJavaScript('window.scrollTo(0,${_restoreOffset.round()})');
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
    final c = _controller;
    if (c == null) return const SizedBox.shrink();
    return WebViewWidget(controller: c);
  }
}
