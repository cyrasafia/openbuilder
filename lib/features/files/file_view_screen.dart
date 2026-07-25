import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';

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
      // Whether this file has a diff (controls the "查看该文件 Diff" action).
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
          if (_hasDiff)
            TextButton(
              onPressed: () => context.push(
                '/session/${widget.sessionId}/diff/file'
                '?path=${Uri.encodeQueryComponent(widget.path)}'
                '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
              ),
              child: Text(l(context).fileViewDiff),
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
    if (_content!.type == 'binary') {
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
    final lines = _content!.content.split('\n');
    final muted = Theme.of(context).colorScheme.outline;
    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (_, i) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 48,
            child: Text(
              '${i + 1}',
              style: AppTheme.mono.copyWith(fontSize: 12, color: muted),
              textAlign: TextAlign.right,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                lines[i],
                style: AppTheme.mono.copyWith(fontSize: 12.5),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
