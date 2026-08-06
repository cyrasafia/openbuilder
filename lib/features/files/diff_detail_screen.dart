import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'file_browsing_container.dart';

class DiffDetailScreen extends StatefulWidget {
  final String sessionId;
  final String path;
  final String? directory;
  final DiffMode mode;
  final String? messageID;
  const DiffDetailScreen({
    super.key,
    required this.sessionId,
    required this.path,
    this.directory,
    this.mode = DiffMode.uncommitted,
    this.messageID,
  });

  @override
  State<DiffDetailScreen> createState() => _DiffDetailScreenState();
}

class _DiffDetailScreenState extends State<DiffDetailScreen> {
  FileDiff? _diff;
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
    try {
      if (widget.mode == DiffMode.lastMessage &&
          (widget.messageID == null || widget.messageID!.isEmpty)) {
        _error = const KnownError(FriendlyErrorKind.diffNoLastMessage);
      } else {
        final diffs = await c.diff(
          widget.sessionId,
          directory: widget.directory,
          mode: widget.mode == DiffMode.branch ? 'branch' : 'git',
          messageID: widget.mode == DiffMode.lastMessage ? widget.messageID : null,
        );
        for (final d in diffs) {
          if (d.file == widget.path) {
            _diff = d;
            break;
          }
        }
        _error = _diff == null
            ? const KnownError(FriendlyErrorKind.diffNotFound)
            : null;
      }
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openFullFile() async {
    final store = serverStore.fileBrowsing;
    final container = store.containerFor<FileBrowsingContainerState>(
      widget.sessionId,
      widget.directory,
    );
    if (container != null) {
      final popped = ModalRoute.of(context)?.popped;
      Navigator.of(context, rootNavigator: true).pop();
      await popped;
      if (container.mounted) container.openFile(widget.path);
      return;
    }
    final existing = store.snapshotFor(widget.sessionId, widget.directory);
    final entry = OpenFileEntry(
      path: widget.path,
      scrollOffset: 0,
      wrap: false,
      mdShowSource: false,
    );
    if (existing != null) {
      existing.openFiles.removeWhere((e) => e.path == entry.path);
      existing.openFiles.add(entry);
      if (existing.openFiles.length > FileBrowsingStore.maxOpenFiles) {
        existing.openFiles.removeAt(0);
      }
    }
    if (!mounted) return;
    context.push(
      '/session/${widget.sessionId}/files'
      '?directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
      extra: existing ?? FileBrowsingSnapshot(openFiles: [entry]),
    );
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
          TextButton(
            onPressed: _diff == null ? null : _openFullFile,
            child: Text(l(context).diffViewFullFile),
          ),
          appBarActionsTrailing,
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
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
    final lines = parseUnifiedDiff(_diff!.patch);
    return ListView.builder(
      itemCount: lines.length,
      itemExtent: null,
      itemBuilder: (_, i) => _DiffRow(line: lines[i]),
    );
  }
}

class _DiffRow extends StatelessWidget {
  final DiffLine line;
  const _DiffRow({required this.line});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final addBg = isDark ? const Color(0xFF12261A) : const Color(0xFFE6F4EA);
    final delBg = isDark ? const Color(0xFF2A1416) : const Color(0xFFFCE8E8);
    final headBg = isDark ? const Color(0xFF1B2230) : const Color(0xFFEAEEF5);
    final muted = Theme.of(context).colorScheme.outline;

    Color bg = Colors.transparent;
    Color fg = Theme.of(context).colorScheme.onSurface;
    switch (line.kind) {
      case '+':
        bg = addBg;
        fg = const Color(0xFF3FB950);
        break;
      case '-':
        bg = delBg;
        fg = const Color(0xFFF85149);
        break;
      case '@':
        bg = headBg;
        fg = const Color(0xFF60A5FA);
        break;
      case 'h':
        fg = muted;
        break;
    }
    final mono = AppTheme.mono;
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (line.kind != '@' && line.kind != 'h')
            SizedBox(
              width: 40,
              child: Text(
                line.oldNo?.toString() ?? '',
                style: mono.copyWith(fontSize: 12, color: muted),
                textAlign: TextAlign.right,
              ),
            ),
          if (line.kind != '@' && line.kind != 'h') const SizedBox(width: 4),
          if (line.kind != '@' && line.kind != 'h')
            SizedBox(
              width: 40,
              child: Text(
                line.newNo?.toString() ?? '',
                style: mono.copyWith(fontSize: 12, color: muted),
                textAlign: TextAlign.right,
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              line.text,
              style: mono.copyWith(fontSize: 12.5, color: fg),
              softWrap: false,
            ),
          ),
        ],
      ),
    );
  }
}
