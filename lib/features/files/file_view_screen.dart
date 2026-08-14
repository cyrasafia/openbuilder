import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'binary_view.dart';
import 'code_view.dart';
import 'download_policy.dart';
import 'file_browsing_container.dart';
import 'highlight_theme.dart';
import 'image_view.dart';
import 'markdown_view.dart';

abstract interface class FileViewJumper {
  void jumpToLine(int line);
  void forceSourceMode();
}

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

class _FileViewScreenState extends State<FileViewScreen>
    implements FileViewJumper {
  late final DownloadPolicy _policy = inferDownloadPolicy(widget.path);

  StreamedFile? _file;
  bool _hasDiff = false;
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

  /// True once the user explicitly tapped Download on the oversized binary
  /// preview; subsequent [_download] calls (including error-retry) skip the
  /// threshold probe and fetch the full body regardless of size. Lives for
  /// the lifetime of this State — re-opening the file gets a fresh State and
  /// re-probes. Intentional: don't re-cancel what the user explicitly asked
  /// for.
  bool _forceDownload = false;

  @override
  void initState() {
    super.initState();
    _loadDiff();
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
        _scheduleScrollRestore();
        return;
      }
    }
    // Both policies download on entry: immediate renders directly, probe
    // inspects Content-Length and cancels if oversized.
    _download();
  }

  FileBrowsingContainerState? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = FileBrowsingContainer.maybeOf(context);
    _container?.registerCollector(this, _collectSelf);
    _container?.registerFile(widget.path, this);
    _installRouteAnimationListener();
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    _container?.unregisterCollector(this);
    _container?.unregisterFile(widget.path);
    _cancelToken?.cancel();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _installRouteAnimationListener() {
    if (_routeAnimInstalled) return;
    _routeAnimInstalled = true;
    final anim = ModalRoute.of(context)?.animation;
    if (anim == null || anim.status == AnimationStatus.completed) {
      _routeTransitionDone = true;
      return;
    }
    _routeAnimation = anim;
    anim.addStatusListener(_onRouteAnimationStatus);
  }

  void _onRouteAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    _routeAnimation?.removeStatusListener(_onRouteAnimationStatus);
    setState(() => _routeTransitionDone = true);
    _scheduleScrollRestore();
  }

  void _collectSelf() {
    serverStore.fileBrowsing.collectFile(
      widget.sessionId,
      widget.directory,
      OpenFileEntry(
        path: widget.path,
        scrollOffset: _isMarkdownPreview
            ? _mdScrollOffset
            : (_scrollCtl.hasClients ? _scrollCtl.position.pixels : 0),
        wrap: _wrap,
        mdShowSource: _mdShowSource,
        hadContent: _file != null,
      ),
    );
  }

  void _scheduleScrollRestore() {
    if (_pendingScrollRestore == null && _pendingLine == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_scrollCtl.hasClients) return;
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
    final tp = TextPainter(
      text: TextSpan(text: '0', style: AppTheme.mono.copyWith(fontSize: codeFontSize)),
      textDirection: TextDirection.ltr,
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final h = tp.height;
    tp.dispose();
    return h;
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
      _scheduleScrollRestore();
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
  }

  Future<void> _loadDiff() async {
    final c = serverStore.client;
    if (c == null) return;
    try {
      final diffs = await c.diff(widget.sessionId, directory: widget.directory);
      if (mounted) {
        setState(() => _hasDiff = diffs.any((d) => d.file == widget.path));
      }
    } catch (_) {
      // diff is best-effort; absence just hides the menu item
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    if (mounted) setState(() => _downloading = false);
  }

  @override
  void jumpToLine(int line) {
    if (line < 1) return;
    if (_isMarkdownPreview || _wrap) {
      setState(() {
        _mdShowSource = true;
        _wrap = false;
      });
    }
    _pendingLine = line;
    _scheduleScrollRestore();
  }

  @override
  void forceSourceMode() {
    if (_mdShowSource) return;
    setState(() => _mdShowSource = true);
  }

  bool get _isTextLike =>
      !_downloading && _error == null && _file != null && !_file!.isBinary;

  void _onMenuAction(_MenuAction value) {
    switch (value) {
      case _MenuAction.mdShowSource:
        setState(() => _mdShowSource = !_mdShowSource);
      case _MenuAction.wrap:
        setState(() => _wrap = !_wrap);
      case _MenuAction.diff:
        context.push(
          '/session/${widget.sessionId}/diff/file'
          '?path=${Uri.encodeQueryComponent(widget.path)}'
          '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
        );
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
              if (_hasDiff && _isTextLike)
                PopupMenuItem(
                  value: _MenuAction.diff,
                  child: Text(l(context).fileViewDiff),
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
      if (!_routeTransitionDone) {
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
      return MarkdownView(
        content: f.text!,
        showSource: _mdShowSource,
        wrap: _wrap,
        sessionId: widget.sessionId,
        path: widget.path,
        directory: widget.directory,
        scrollController: _scrollCtl,
        initialScrollOffset: _mdScrollOffset,
        onScrolled: (o) => _mdScrollOffset = o,
      );
    }
    if (!f.isBinary) {
      return CodeView(
        content: f.text!,
        language: languageForPath(widget.path),
        wrap: _wrap,
        scrollController: _scrollCtl,
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
}

enum _MenuAction { mdShowSource, wrap, diff }
