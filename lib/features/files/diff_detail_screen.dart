import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';

class DiffDetailScreen extends StatefulWidget {
  final String sessionId;
  final String path;
  final String? directory;
  const DiffDetailScreen(
      {super.key,
      required this.sessionId,
      required this.path,
      this.directory});

  @override
  State<DiffDetailScreen> createState() => _DiffDetailScreenState();
}

class _DiffDetailScreenState extends State<DiffDetailScreen> {
  FileDiff? _diff;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = '未连接服务器');
      return;
    }
    try {
      final diffs = await c.diff(widget.sessionId, directory: widget.directory);
      for (final d in diffs) {
        if (d.file == widget.path) {
          _diff = d;
          break;
        }
      }
      _error = _diff == null ? '未找到该文件的 diff' : null;
    } catch (e) {
      _error = friendlyError(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.path.split('/').last,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
            if (_diff != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: _Stat(add: _diff!.additions, del: _diff!.deletions),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _diff == null
                ? null
                : () => context.push(
                      '/session/${widget.sessionId}/file'
                      '?path=${Uri.encodeQueryComponent(widget.path)}'
                      '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
                    ),
            child: const Text('查看完整文件'),
          ),
        ],
      ),
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_error!, style: AppTheme.mono.copyWith(fontSize: 12)),
        const SizedBox(height: 12),
        FilledButton(onPressed: _load, child: const Text('重试')),
      ]));
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
              child: Text(line.oldNo?.toString() ?? '',
                  style: mono.copyWith(fontSize: 12, color: muted),
                  textAlign: TextAlign.right),
            ),
          if (line.kind != '@' && line.kind != 'h')
            const SizedBox(width: 4),
          if (line.kind != '@' && line.kind != 'h')
            SizedBox(
              width: 40,
              child: Text(line.newNo?.toString() ?? '',
                  style: mono.copyWith(fontSize: 12, color: muted),
                  textAlign: TextAlign.right),
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

class _Stat extends StatelessWidget {
  final int add;
  final int del;
  const _Stat({required this.add, required this.del});
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('+$add', style: const TextStyle(color: Color(0xFF3FB950), fontSize: 12)),
          const SizedBox(width: 8),
          Text('-$del', style: const TextStyle(color: Color(0xFFF85149), fontSize: 12)),
        ],
      );
}
