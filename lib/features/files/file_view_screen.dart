import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/logging/app_logger.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'binary_view.dart';
import 'code_view.dart';
import 'download_policy.dart';
import 'file_actions.dart';
import 'file_browsing_container.dart';
import 'highlight_theme.dart';
import 'image_view.dart';
import 'markdown_html.dart';
import 'markdown_view.dart';

class FileViewScreen extends StatefulWidget {
  final String sessionId;
  final String path;
  final String? directory;
  final OpenFileEntry? restore;
  const FileViewScreen({
    super.key,
    required this.sessionId,
    required this.path,
    this.directory,
    this.restore,
  });

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  bool _isPlaceholderAnimation(Animation<double>? anim) =>
      anim is ProxyAnimation &&
      identical(anim.parent, kAlwaysCompleteAnimation);

  late final DownloadPolicy _policy = inferDownloadPolicy(widget.path);

  StreamedFile? _file;
  bool _downloading = false;
  double? _progress;
  Object? _error;
  bool _wrap = false;
  bool _mdShowSource = false;
  CancelToken? _cancelToken;
  final _scrollCtl = ScrollController();
  double? _pendingScrollRestore;
  int? _pendingLine;
  // Markdown preview scrolls inside its own WebView (not via _scrollCtl); we
  // track its offset here via the WebView callback so collapse/restore keeps
  // the reading position for preview mode.
  double _mdScrollOffset = 0;

  Animation<double>? _routeAnimation;
  bool _routeAnimInstalled = false;
  bool _routeTransitionDone = false;

  // Markdown preview document, built off the UI isolate while the loading UI
  // is up (download / route transition). Gates the preview mount: content
  // appears only after it is ready, so the markdown→HTML conversion never
  // lands inside a transition-animation frame. _mdHtmlTheme is the theme the
  // document was built under — a theme flip while the WebView is unmounted
  // (e.g. source-mode round trip) must invalidate it.
  String? _mdHtml;
  (Brightness, Color, Color, AppColors)? _mdHtmlTheme;
  int _mdHtmlGen = 0;

  // Highlight spans for code files, built off the UI isolate during the
  // loading phase — the same pattern as _mdHtml. Gates the CodeView mount so
  // the mount frame adopts ready spans instead of paying the highlight cost.
  List<TextSpan>? _codeSpans;
  Brightness? _codeSpansBrightness;
  bool _codeSpansReady = false;
  int _codeSpansGen = 0;

  // The preview WebView is mounted once _mdHtml is ready but paints
  // asynchronously (loadHtmlString → parse → first paint). The loading
  // overlay stays on top until the first onPageFinished arrives, so the
  // user never sees a blank WebView. _webviewRenderFallback bounds that wait:
  // if onPageFinished never fires (renderer crash, platform-view init
  // failure, loadHtmlString throw), the overlay is dropped after a timeout
  // instead of dead-ending on a permanent spinner.
  bool _webviewRendered = false;
  Timer? _webviewRenderFallback;
  static const _webviewRenderFallbackDelay = Duration(seconds: 8);

  /// True once the user explicitly tapped Download on the oversized binary
  /// preview; subsequent [_download] calls (including error-retry) skip the
  /// threshold probe and fetch the full body regardless of size. Lives for
  /// the lifetime of this State — re-opening the file gets a fresh State and
  /// re-probes. Intentional: don't re-cancel what the user explicitly asked
  /// for.
  bool _forceDownload = false;

  bool _exportBusy = false;

  @override
  void initState() {
    super.initState();
    final r = widget.restore;
    if (r != null) {
      _wrap = r.wrap;
      _mdShowSource = r.mdShowSource;
      _pendingScrollRestore = r.scrollOffset;
      _pendingLine = r.initialLine;
      _mdScrollOffset = r.scrollOffset;
      final cached = serverStore.fileBrowsing.cachedContent(
        widget.sessionId,
        widget.directory,
        widget.path,
      );
      if (cached != null) {
        _file = cached;
        _maybePrepareMarkdownHtml();
        _maybePrepareCodeSpans();
        _scheduleScrollRestore();
        return;
      }
    }
    // Both policies download on entry: immediate renders directly, probe
    // inspects Content-Length and cancels if oversized.
    _download();
  }

  FileBrowsingContainerState? _container;
  bool _containerTransitionDone = true;
  bool _containerListenerInstalled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = FileBrowsingContainer.maybeOf(context);
    _container?.registerCollector(this, _collectSelf);
    _container?.registerFileEntry(widget.path, _currentEntry);
    final notifier = _container?.transitionDone;
    if (notifier != null) {
      _containerTransitionDone = notifier.value;
      if (!_containerListenerInstalled) {
        _containerListenerInstalled = true;
        notifier.addListener(_onContainerTransitionDone);
      }
    }
    _installRouteAnimationListener();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _container?.transitionDone.removeListener(_onContainerTransitionDone);
    _container?.unregisterCollector(this);
    _container?.unregisterFileEntry(widget.path, _currentEntry);
    _cancelWebViewRenderFallback();
    _mdHtmlGen++;
    _codeSpansGen++;
    _cancelToken?.cancel();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _onContainerTransitionDone() {
    final notifier = _container?.transitionDone;
    if (notifier == null || !mounted) return;
    if (notifier.value == _containerTransitionDone) return;
    setState(() => _containerTransitionDone = notifier.value);
    _scheduleScrollRestore();
  }

  void _installRouteAnimationListener() {
    if (_routeAnimInstalled) return;
    _routeAnimInstalled = true;
    _tryInstallRouteAnimation();
  }

  void _tryInstallRouteAnimation() {
    if (!mounted || _routeTransitionDone) return;
    final anim = ModalRoute.of(context)?.animation;
    if (_isPlaceholderAnimation(anim)) {
      // The route's animation is still the completed-forever placeholder the
      // framework installs before the real controller attaches (its ProxyAnimation
      // parent is kAlwaysCompleteAnimation). Reading it eagerly would defeat the
      // gate, so retry after this frame until the real animation is live.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryInstallRouteAnimation(),
      );
      return;
    }
    if (anim == null || anim.status == AnimationStatus.completed) {
      setState(() => _routeTransitionDone = true);
      _scheduleScrollRestore();
      return;
    }
    _routeAnimation = anim;
    anim.addStatusListener(_onRouteAnimationStatus);
    // The listener was installed after the animation might have already
    // completed (placeholder retry costs a frame), so check the current
    // status once — status listeners don't replay the current state.
    if (anim.status == AnimationStatus.completed) {
      _onRouteAnimationStatus(AnimationStatus.completed);
    }
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    setState(() => _routeTransitionDone = true);
    _scheduleScrollRestore();
  }

  OpenFileEntry _currentEntry() => OpenFileEntry(
        path: widget.path,
        scrollOffset: _isMarkdownPreview
            ? _mdScrollOffset
            : (_scrollCtl.hasClients
                ? _scrollCtl.position.pixels
                : (_pendingScrollRestore ?? 0)),
        wrap: _wrap,
        mdShowSource: _mdShowSource,
        hadContent: _file != null,
        initialLine: _pendingLine,
      );

  void _collectSelf() {
    serverStore.fileBrowsing.collectFile(
      widget.sessionId,
      widget.directory,
      _currentEntry(),
    );
  }

  void _scheduleScrollRestore() {
    if (_pendingScrollRestore == null && _pendingLine == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollCtl.hasClients) {
        // Content not mounted yet (transition/HTML gate still closed, or the
        // download still running). Keep rescheduling frame-by-frame so the
        // restore lands on the first frame after mount — download completion
        // and error-retry both rely on the target staying armed. Only once
        // content IS mounted and provably not _scrollCtl-driven (markdown
        // preview / image / binary) is the target dropped, so the loop can't
        // stay armed forever on views that never attach this controller.
        if (_file != null && !_isScrollCtlContent) {
          _pendingLine = null;
          _pendingScrollRestore = null;
          return;
        }
        // Settled without content (error view, or the probe/user-cancel
        // download prompt): stay armed but dormant — retry / full-download
        // success re-schedules the restore.
        if (_file == null && !_downloading) return;
        if (_pendingScrollRestore != null || _pendingLine != null) {
          _scheduleScrollRestore();
        }
        return;
      }
      final line = _pendingLine;
      if (line != null) {
        _pendingLine = null;
        _pendingScrollRestore = null;
        if (_isMarkdownPreview || line <= 1) return;
        final pos = _scrollCtl.position;
        _scrollCtl.jumpTo(
          (codeListVerticalPadding + (line - 1) * _lineHeight())
              .clamp(pos.minScrollExtent, pos.maxScrollExtent)
              .toDouble(),
        );
        return;
      }
      if (_pendingScrollRestore == null) return;
      final pending = _pendingScrollRestore!;
      _pendingScrollRestore = null;
      final pos = _scrollCtl.position;
      _scrollCtl.jumpTo(
        pending.clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble(),
      );
    });
  }

  double _lineHeight() {
    // Must match CodeView's rendered row height exactly. Rows carry the
    // codeStrutStyle (forceStrutHeight), which pins every row to
    // fontSize × codeLineHeight regardless of glyph fallback fonts (emoji /
    // symbol runs are measured with their own font metrics otherwise, so
    // those rows grow taller and break the offset math). Sample the mounted
    // content's context — not this State's own, which sits above the
    // Scaffold — so the textScaler matches the rows'.
    assert(_scrollCtl.hasClients);
    final BuildContext ctx = _scrollCtl.position.context.storageContext;
    final tp = TextPainter(
      text: TextSpan(
        text: '0',
        style: DefaultTextStyle.of(ctx).style.merge(codeTextStyle()),
      ),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(ctx),
      maxLines: 1,
    )..layout();
    final h = tp.height;
    tp.dispose();
    return h;
  }

  /// Kicks the markdown preview document build on a background isolate as
  /// soon as the content is available (download finished / cache hit) — it
  /// overlaps the route transition instead of landing in the first content
  /// frame. Only the preview mode needs it; source mode renders via CodeView.
  /// Content/theme changes after mount are handled inside MarkdownWebView's
  /// signature check, not here. Scheduled via microtask so the cache-hit call
  /// from initState never reads Theme before the state is ready.
  void _maybePrepareMarkdownHtml() {
    if (!_isMarkdown || _mdShowSource) return;
    Future<void>.microtask(_prepareMarkdownHtml);
  }

  (Brightness, Color, Color, AppColors) _themeSignature() {
    final theme = Theme.of(context);
    return (
      theme.brightness,
      theme.scaffoldBackgroundColor,
      theme.colorScheme.onSurface,
      theme.extension<AppColors>()!,
    );
  }

  void _prepareMarkdownHtml() {
    if (!mounted || !_isMarkdown || _mdShowSource) return;
    final theme = Theme.of(context);
    final themeSig = _themeSignature();
    if (_mdHtml != null) {
      if (themeSig == _mdHtmlTheme) return;
      // Stale document (theme flipped since it was built): drop it so the
      // gate holds the loading UI until the rebuild lands.
      setState(() => _mdHtml = null);
    }
    final gen = ++_mdHtmlGen;
    final task = MarkdownHtmlTask(
      _file!.text!,
      theme.brightness,
      theme.scaffoldBackgroundColor,
      theme.colorScheme.onSurface,
      theme.extension<AppColors>()!,
    );
    () async {
      String html;
      try {
        html = await compute(buildMarkdownPreviewHtmlOffIsolate, task);
      } catch (_) {
        // Isolate failure must not strand the loading UI; fall back to a
        // synchronous build on the UI isolate.
        try {
          html = buildMarkdownPreviewHtmlOffIsolate(task);
        } catch (_) {
          // And if even the fallback throws, degrade to source mode — the
          // _mdHtml gate must never hold the spinner forever.
          if (!mounted || gen != _mdHtmlGen) return;
          setState(() => _mdShowSource = true);
          return;
        }
      }
      if (!mounted || gen != _mdHtmlGen) return;
      setState(() {
        _mdHtml = html;
        _mdHtmlTheme = themeSig;
      });
    }();
  }

  /// Whether the content renders via CodeView with syntax highlighting —
  /// text, non-markdown, known language. Such files get their spans
  /// pre-built during the loading phase (see [_maybePrepareCodeSpans]).
  bool get _isCodeFile {
    final f = _file;
    if (f == null || f.isBinary || _isMarkdown) return false;
    return languageForPath(widget.path) != null;
  }

  /// Code-file counterpart of [_maybePrepareMarkdownHtml]: highlight off the
  /// UI isolate while the loading UI is up, gate the mount on the result.
  void _maybePrepareCodeSpans() {
    if (!_isCodeFile || _codeSpansReady) return;
    Future<void>.microtask(_prepareCodeSpans);
  }

  void _prepareCodeSpans() {
    if (!mounted || _codeSpansReady || !_isCodeFile) return;
    final brightness = Theme.of(context).brightness;
    final gen = ++_codeSpansGen;
    final task = HighlightTask(
      _file!.text!,
      languageForPath(widget.path)!,
      codeTextStyle(),
      brightness,
    );
    () async {
      List<TextSpan>? spans;
      try {
        spans = await compute(highlightOffIsolate, task);
      } catch (_) {
        // Keep spans null: CodeView mounts plain and retries highlighting
        // itself. The gate must never strand the loading UI.
      }
      if (!mounted || gen != _codeSpansGen) return;
      setState(() {
        _codeSpans = spans;
        // Null brightness on failure makes CodeView's first
        // didChangeDependencies kick off its own highlight — adopting a
        // brightness with no spans would suppress it permanently.
        _codeSpansBrightness = spans == null ? null : brightness;
        _codeSpansReady = true;
      });
    }();
  }

  void _onWebViewFirstRendered() {
    _cancelWebViewRenderFallback();
    if (!mounted || _webviewRendered) return;
    setState(() => _webviewRendered = true);
  }

  /// Bounds the wait for the WebView's first paint: if `onPageFinished` never
  /// arrives (renderer crash, platform-view init failure), drop the overlay
  /// after the delay instead of dead-ending on a permanent spinner. Idempotent
  /// — safe to call from build on every frame the overlay is up.
  void _armWebViewRenderFallback() {
    if (_webviewRenderFallback != null || _webviewRendered) return;
    _webviewRenderFallback = Timer(_webviewRenderFallbackDelay, () {
      _webviewRenderFallback = null;
      if (!mounted || _webviewRendered) return;
      setState(() => _webviewRendered = true);
    });
  }

  void _cancelWebViewRenderFallback() {
    _webviewRenderFallback?.cancel();
    _webviewRenderFallback = null;
  }

  Future<void> _download() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = const KnownError(FriendlyErrorKind.notConnected));
      return;
    }
    _cancelToken?.cancel();
    final token = CancelToken();
    _cancelToken = token;
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
      _file = null;
      // Content is being replaced: drop the derived artifacts of the previous
      // body so a re-download can never mount stale spans/HTML (and any
      // in-flight pre-build is invalidated via the generation counters).
      _codeSpans = null;
      _codeSpansBrightness = null;
      _codeSpansReady = false;
      _codeSpansGen++;
      _mdHtml = null;
      _mdHtmlTheme = null;
      _mdHtmlGen++;
      _webviewRendered = false;
    });
    try {
      _file = await c.readFileStream(
        directory: widget.directory ?? '',
        path: widget.path,
        onProgress: (r, t) {
          // Ignore progress from a superseded/cancelled download so it can't
          // overwrite the active token's percentage (mirrors the finally guard).
          if (_cancelToken != token) return;
          if (!mounted) return;
          if (_policy == DownloadPolicy.probe && !_forceDownload) {
            // Cancel once the download clearly exceeds the threshold. We gate on
            // both the announced total (Content-Length) and the bytes received so
            // far: `total` may be -1/0 when the server omits Content-Length
            // (chunked / HTTP2), in which case the received-bytes guard still
            // caps the download. On native, `total` is the gzipped transfer size
            // (raw_download keeps compression on); on web the browser owns
            // decompression and reports decoded bytes — either way the guard
            // bounds the real cost of previewing.
            final knownTotal = t > 0 ? t : null;
            if ((knownTotal != null && knownTotal > probeThreshold) ||
                r > probeThreshold) {
              // The finally block clears _downloading, which drops the UI into
              // the binary-style preview with a Download button.
              token.cancel();
              return;
            }
          }
          if (t > 0) {
            final p = (r / t).clamp(0.0, 1.0);
            if (p != _progress) setState(() => _progress = p);
          }
        },
        cancelToken: token,
      );
      serverStore.fileBrowsing.cacheContent(
        widget.sessionId,
        widget.directory,
        widget.path,
        _file!,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        // Probe-induced cancellation is expected; the finally block drops the
        // UI into the binary-style preview. Don't surface as an error.
        return;
      }
      _error = e;
    } catch (e) {
      _error = e;
    } finally {
      // Only clear the downloading state if this call is still the active
      // download — a later _download() (retry/open) cancels this token and
      // supersedes it; letting the superseded call clear the flag would drop
      // the progress UI mid-download.
      if (mounted && _cancelToken == token) {
        setState(() => _downloading = false);
      }
    }
    // Kick the pre-builds only after the finally block has cleared
    // _downloading: their _isMarkdown/_isCodeFile guards read that flag, and
    // a kick from inside the try block above would see it still true, skip
    // the markdown HTML build, and strand the preview gate on its spinner.
    // The token check mirrors the finally guard: a superseded download must
    // not interfere with the active one's derived state or scroll restore.
    if (!mounted || _cancelToken != token || _error != null || _file == null) {
      return;
    }
    _maybePrepareMarkdownHtml();
    _maybePrepareCodeSpans();
    _scheduleScrollRestore();
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    if (mounted) setState(() => _downloading = false);
  }

  bool get _isTextLike =>
      !_downloading && _error == null && _file != null && !_file!.isBinary;

  String get _filename => basenameOf(widget.path);

  Future<File> _materializeTextFile() {
    return materializeTextExportFile(_filename, _file!.text!);
  }

  Future<void> _onSaveToDevice() async {
    if (_exportBusy) return;
    _exportBusy = true;
    try {
      final file = await _materializeTextFile();
      await saveExportToDownloads(
        srcPath: file.path,
        displayName: _filename,
        mimeType: _file!.mimeType,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l(context).fileDownloadSuccess)),
      );
    } catch (e) {
      AppLogger.I.w('FileViewScreen', 'saveToDownloads failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l(context).fileDownloadFailed(e.toString()))),
      );
    } finally {
      _exportBusy = false;
    }
  }

  Future<void> _onShare() async {
    if (_exportBusy) return;
    _exportBusy = true;
    try {
      final file = await _materializeTextFile();
      await shareExportFile(file);
    } catch (e) {
      AppLogger.I.w('FileViewScreen', 'share failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l(context).fileShareFailed(e.toString()))),
      );
    } finally {
      _exportBusy = false;
    }
  }

  void _onMenuAction(_MenuAction value) {
    switch (value) {
      case _MenuAction.mdShowSource:
        setState(() {
          _mdShowSource = !_mdShowSource;
          // Returning to preview after a theme flip (source-mode round
          // trip): invalidate the stale document synchronously so the gate
          // holds the loading UI from this frame, not one frame later.
          if (!_mdShowSource &&
              _mdHtml != null &&
              _mdHtmlTheme != _themeSignature()) {
            _mdHtml = null;
          }
          // Switching back to preview remounts the WebView, which reloads
          // and repaints asynchronously — re-arm the first-render overlay so
          // that repaint is covered too, not just the initial open.
          if (!_mdShowSource) _webviewRendered = false;
          // Leaving preview cancels the pending fallback; returning to it
          // re-arms via the next build.
          _cancelWebViewRenderFallback();
        });
        // Opening in source mode (diff line anchor, sealed snapshot) skips
        // the HTML pre-build; kick it here so the preview toggle can't hit
        // the _mdHtml gate with nothing ever producing the document.
        if (!_mdShowSource) _maybePrepareMarkdownHtml();
      case _MenuAction.wrap:
        setState(() => _wrap = !_wrap);
      case _MenuAction.saveToDevice:
        _onSaveToDevice();
      case _MenuAction.share:
        _onShare();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: () {
            final c = _container;
            if (c != null) {
              c.handleBack();
            } else {
              Navigator.of(context).maybePop();
            }
          },
        ),
        title: Text(
          widget.path.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.more_vert),
            popUpAnimationStyle: popupMenuAnimationStyle,
            onSelected: _onMenuAction,
            itemBuilder: (_) => [
              if (_isMarkdown)
                PopupMenuItem(
                  value: _MenuAction.mdShowSource,
                  child: Text(
                    _mdShowSource
                        ? l(context).filePreview
                        : l(context).fileSource,
                  ),
                ),
              if (_isTextLike && !_isMarkdownPreview)
                PopupMenuItem(
                  value: _MenuAction.wrap,
                  child: Text(
                    _wrap ? l(context).fileWrapOff : l(context).fileWrapOn,
                  ),
                ),
              if (_isTextLike && !kIsWeb && Platform.isAndroid)
                PopupMenuItem(
                  value: _MenuAction.saveToDevice,
                  enabled: !_exportBusy,
                  child: Text(l(context).save),
                ),
              if (_isTextLike)
                PopupMenuItem(
                  value: _MenuAction.share,
                  enabled: !_exportBusy,
                  child: Text(l(context).fileShare),
                ),
            ],
          ),
          const FileCollapseAction(),
          appBarActionsTrailing,
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) return _errorView();
    if (_downloading) return _progressView();
    if (_file != null) {
      // Content mounts only when every transition animation is done (the
      // inner route's, and the container root route's for restore/peek flows
      // where the inner route is an un-animated initial route) and, for
      // markdown preview, the off-isolate HTML build has finished. Until then
      // the cheap loading UI stays up, so no heavy first-content frame can
      // land inside an animation window.
      if (!_routeTransitionDone || !_containerTransitionDone) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_isMarkdownPreview && _mdHtml == null) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_isCodeFile && !_codeSpansReady) {
        return const Center(child: CircularProgressIndicator());
      }
      return _contentDispatch();
    }
    // No content and not downloading: a probe-cancelled oversized file or a
    // user-cancelled download. Present it like a binary file (icon + name +
    // Download) rather than a dead-end "too large" notice; tapping Download
    // resumes/fetches the full body.
    return BinaryView(
      filename: widget.path.split('/').last,
      onDownload: _requestFullDownload,
    );
  }

  Widget _progressView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_progress != null)
              LinearProgressIndicator(value: _progress)
            else
              const CircularProgressIndicator(),
            const SizedBox(height: 16),
            if (_progress != null) Text('${(_progress! * 100).round()}%'),
            if (_progress != null) const SizedBox(height: 16),
            TextButton(
              onPressed: _cancelDownload,
              child: Text(l(context).fileLoadCancel),
            ),
          ],
        ),
      ),
    );
  }

  /// User-initiated download from the oversized binary preview: skip any
  /// probe threshold and fetch the full body.
  void _requestFullDownload() {
    _forceDownload = true;
    _download();
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l(context).loadFailed,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            friendlyMessage(l(context), _error!),
            style: AppTheme.mono.copyWith(fontSize: 12),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _download, child: Text(l(context).retry)),
        ],
      ),
    );
  }

  Widget _contentDispatch() {
    final f = _file!;
    final ext = extensionOf(widget.path);

    if (f.isBinary &&
        f.bytes != null &&
        (f.mimeType?.startsWith('image/') ?? false) &&
        f.mimeType != 'image/svg+xml') {
      return ImageView(bytes: f.bytes!, isSvg: false);
    }
    if (!f.isBinary && ext == '.svg') {
      return ImageView(text: f.text!, isSvg: true);
    }
    if (_isMarkdown) {
      final view = MarkdownView(
        content: f.text!,
        showSource: _mdShowSource,
        wrap: _wrap,
        sessionId: widget.sessionId,
        path: widget.path,
        directory: widget.directory,
        scrollController: _scrollCtl,
        initialScrollOffset: _mdScrollOffset,
        onScrolled: (o) => _mdScrollOffset = o,
        prebuiltHtml: _mdShowSource ? null : _mdHtml,
        onFirstRendered: _onWebViewFirstRendered,
      );
      // Preview mode: the WebView loads/paints asynchronously after mount;
      // keep an opaque loading overlay on top until its first page finishes,
      // so the user sees the spinner right up to real content — never a
      // blank WebView. The Stack structure stays stable across the overlay
      // swap so the WebView element is never remounted (which would reload
      // the document from scratch).
      if (!_mdShowSource) {
        _armWebViewRenderFallback();
        return Stack(
          children: [
            view,
            if (!_webviewRendered)
              Container(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: const Center(child: CircularProgressIndicator()),
              )
            else
              const SizedBox.shrink(),
          ],
        );
      }
      return view;
    }
    if (!f.isBinary) {
      return CodeView(
        content: f.text!,
        language: languageForPath(widget.path),
        wrap: _wrap,
        scrollController: _scrollCtl,
        prebuiltSpans: _codeSpans,
        prebuiltBrightness: _codeSpansBrightness,
      );
    }
    return BinaryView(
      filename: widget.path.split('/').last,
      mimeType: f.mimeType,
      downloadedBytes: f.bytes,
    );
  }

  bool get _isMarkdown {
    if (_downloading || _error != null || _file == null || _file!.isBinary) {
      return false;
    }
    final ext = extensionOf(widget.path);
    return ext == '.md' || ext == '.markdown';
  }

  bool get _isMarkdownPreview => _isMarkdown && !_mdShowSource;

  /// Whether the mounted content drives [_scrollCtl]. Mirrors the dispatch in
  /// [_contentDispatch]: CodeView and markdown source mode attach it;
  /// image/SVG/binary views and the markdown preview (WebView scrolls
  /// itself) do not.
  bool get _isScrollCtlContent {
    final f = _file;
    if (f == null) return false;
    if (f.isBinary &&
        f.bytes != null &&
        (f.mimeType?.startsWith('image/') ?? false) &&
        f.mimeType != 'image/svg+xml') {
      return false;
    }
    if (!f.isBinary && extensionOf(widget.path) == '.svg') return false;
    if (_isMarkdown && !_mdShowSource) return false;
    if (f.isBinary) return false;
    return true;
  }
}

enum _MenuAction { mdShowSource, wrap, saveToDevice, share }
