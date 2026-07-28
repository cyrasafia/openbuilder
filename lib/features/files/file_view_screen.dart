import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import 'code_view.dart';
import 'highlight_theme.dart';

class FileViewScreen extends StatefulWidget {
  final String sessionId;
  final String path;
  final String? directory;
  const FileViewScreen({
    super.key,
    required this.sessionId,
    required this.path,
    this.directory,
  });

  @override
  State<FileViewScreen> createState() => _FileViewScreenState();
}

class _FileViewScreenState extends State<FileViewScreen> {
  FileContent? _content;
  bool _hasDiff = false;
  bool _loading = true;
  Object? _error;
  bool _wrap = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = const KnownError(FriendlyErrorKind.notConnected));
      return;
    }
    setState(() => _loading = true);
    try {
      _content = await c.readFile(
        directory: widget.directory ?? '',
        path: widget.path,
      );
      try {
        final diffs = await c.diff(
          widget.sessionId,
          directory: widget.directory,
        );
        _hasDiff = diffs.any((d) => d.file == widget.path);
      } catch (_) {
        _hasDiff = false;
      }
      _error = null;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _isTextLike =>
      !_loading && _error == null && _content != null && !_content!.isBinary;

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
              if (_hasDiff)
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
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
            FilledButton(onPressed: _load, child: Text(l(context).retry)),
          ],
        ),
      );
    }
    return _dispatch();
  }

  Widget _dispatch() {
    final file = _content!;
    if (file.isBinary) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.file_present, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(l(context).fileBinaryHint),
          ],
        ),
      );
    }
    return CodeView(
      content: file.content,
      language: languageForPath(widget.path),
      wrap: _wrap,
    );
  }
}

enum _MenuAction { wrap, diff }
