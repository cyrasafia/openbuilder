import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import 'binary_view.dart';
import 'code_view.dart';
import 'download_policy.dart';
import 'file_browsing_container.dart';
import 'highlight_theme.dart';
import 'image_view.dart';
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

  @override
  void initState() {
    super.initState();
    _loadDiff();
    final r = widget.restore;
    if (r != null) {
      _wrap = r.wrap;
      _mdShowSource = r.mdShowSource;
      _pendingScrollRestore = r.scrollOffset;
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
      if (_policy == DownloadPolicy.immediate || r.hadContent) _download();
      return;
    }
    if (_policy == DownloadPolicy.immediate) _download();
  }

  FileBrowsingContainerState? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = FileBrowsingContainer.maybeOf(context);
    _container?.registerCollector(this, _collectSelf);
    _container?.registerFile(widget.path);
  }

  @override
  void dispose() {
    _container?.unregisterCollector(this);
    _container?.unregisterFile(widget.path);
    _cancelToken?.cancel();
    _scrollCtl.dispose();
    super.dispose();
  }

  void _collectSelf() {
    serverStore.fileBrowsing.collectFile(
      widget.sessionId,
      widget.directory,
      OpenFileEntry(
        path: widget.path,
        scrollOffset: _scrollCtl.hasClients ? _scrollCtl.position.pixels : 0,
        wrap: _wrap,
        mdShowSource: _mdShowSource,
        hadContent: _file != null,
      ),
    );
  }

  void _collapse() {
    _container?.collapse();
  }

  void _scheduleScrollRestore() {
    if (_pendingScrollRestore == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final pending = _pendingScrollRestore;
      _pendingScrollRestore = null;
      if (pending == null || !_scrollCtl.hasClients) return;
      final pos = _scrollCtl.position;
      _scrollCtl.jumpTo(
        pending.clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble(),
      );
    });
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
          if (t > 0 && mounted) {
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
      if (e.type == DioExceptionType.cancel) return;
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

  bool get _isTextLike =>
      !_downloading && _error == null && _file != null && !_file!.isBinary;

  void _onMenuAction(_MenuAction value) {
    switch (value) {
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
        title: Text(
          widget.path.split('/').last,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16),
        ),
        actions: [
          if (_isMarkdown)
            TextButton(
              onPressed: () => setState(() => _mdShowSource = !_mdShowSource),
              child: Text(
                _mdShowSource ? l(context).filePreview : l(context).fileSource,
              ),
            ),
          IconButton(
            icon: const Icon(Icons.keyboard_arrow_down, size: 20),
            tooltip: l(context).fileCollapse,
            onPressed: _collapse,
          ),
          PopupMenuButton<_MenuAction>(
            icon: const Icon(Icons.more_vert),
            onSelected: _onMenuAction,
            itemBuilder: (_) => [
              if (_isTextLike)
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
        ],
      ),
      body: _body(),
    );
  }

  Widget _body() {
    if (_error != null) return _errorView();
    if (_downloading) return _progressView();
    if (_file != null) return _contentDispatch();
    return _onDemandPlaceholder();
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

  Widget _onDemandPlaceholder() {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 64,
              color: scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              widget.path.split('/').last,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _download,
              icon: const Icon(Icons.download),
              label: Text(l(context).fileDownload),
            ),
          ],
        ),
      ),
    );
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
}

enum _MenuAction { wrap, diff }
