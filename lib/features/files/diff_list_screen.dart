import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';

class DiffListScreen extends StatefulWidget {
  final String sessionId;
  final String? directory;
  const DiffListScreen(
      {super.key, required this.sessionId, this.directory});

  @override
  State<DiffListScreen> createState() => _DiffListScreenState();
}

class _DiffListScreenState extends State<DiffListScreen> {
  List<FileDiff> _diffs = [];
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
      _diffs = await c.diff(widget.sessionId, directory: widget.directory);
      _error = null;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _totalAdd =>
      _diffs.fold(0, (s, d) => s + d.additions);
  int get _totalDel =>
      _diffs.fold(0, (s, d) => s + d.deletions);

  @override
  Widget build(BuildContext context) {
    final session = serverStore.sessionById(widget.sessionId);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Diff', style: TextStyle(fontSize: 16)),
            if (session != null)
              Text(session.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mono.copyWith(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline)),
          ],
        ),
        actions: [
          if (!_loading)
            Padding(
              padding: const EdgeInsets.only(right: 14),
              child: _DiffStat(add: _totalAdd, del: _totalDel),
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
        ]),
      );
    }
    if (_diffs.isEmpty) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.compare, size: 48, color: Colors.grey),
          SizedBox(height: 12),
          Text('无变更'),
        ]),
      );
    }
    return ListView.separated(
      itemCount: _diffs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final d = _diffs[i];
        return ListTile(
          leading: const Icon(Icons.description_outlined),
          title: Text(d.file,
              style: AppTheme.mono.copyWith(fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
          trailing: _DiffStat(add: d.additions, del: d.deletions),
          onTap: () => context.push(
            '/session/${widget.sessionId}/diff/file'
            '?path=${Uri.encodeQueryComponent(d.file)}'
            '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
          ),
        );
      },
    );
  }
}

class _DiffStat extends StatelessWidget {
  final int add;
  final int del;
  const _DiffStat({required this.add, required this.del});
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('+$add', style: const TextStyle(color: Color(0xFF3FB950), fontSize: 13)),
          const SizedBox(width: 8),
          Text('-$del', style: const TextStyle(color: Color(0xFFF85149), fontSize: 13)),
        ],
      );
}
