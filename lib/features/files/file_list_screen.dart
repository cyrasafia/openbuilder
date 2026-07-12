import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';

class FileListScreen extends StatefulWidget {
  final String sessionId;
  final String? directory;
  final String? initialPath;
  const FileListScreen({
    super.key,
    required this.sessionId,
    this.directory,
    this.initialPath,
  });

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  String _path = '';
  List<FileNode> _nodes = [];
  bool _loading = true;
  String? _error;
  String _query = '';
  final _searchCtl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath ?? '';
    _load();
  }

  Future<void> _load() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = '未连接服务器');
      return;
    }
    setState(() => _loading = true);
    try {
      _nodes = await c.listFiles(directory: widget.directory ?? '', path: _path);
      _nodes = _sortNodes(_nodes);
      _error = null;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<FileNode> _sortNodes(List<FileNode> list) {
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  Future<void> _search(String q) async {
    final c = serverStore.client;
    if (c == null || q.trim().isEmpty) {
      _load();
      return;
    }
    setState(() {
      _loading = true;
      _query = q;
    });
    try {
      _nodes = await c.findFiles(directory: widget.directory ?? '', query: q);
      _nodes = _sortNodes(_nodes);
      _error = null;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<String> get _segments => _path.isEmpty
      ? const []
      : _path.split('/').where((s) => s.isNotEmpty).toList();

  String _prefixPath(int segmentIndex) =>
      _segments.take(segmentIndex).join('/');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件', style: TextStyle(fontSize: 16)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: TextField(
              controller: _searchCtl,
              decoration: InputDecoration(
                hintText: '搜索文件…',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                suffixIcon: _searchCtl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchCtl.clear();
                          setState(() => _query = '');
                          _load();
                        },
                      )
                    : null,
              ),
              onChanged: (v) {
                if (v.isEmpty && _query.isNotEmpty) {
                  setState(() => _query = '');
                  _load();
                } else if (v.isNotEmpty) {
                  _search(v);
                }
              },
            ),
          ),
          if (_query.isEmpty) _breadcrumb(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _breadcrumb() {
    final items = <Widget>[];
    items.add(_Crumb(
      label: '工作区',
      onTap: _segments.isNotEmpty
          ? () {
              setState(() => _path = '');
              _load();
            }
          : null,
    ));
    for (var i = 0; i < _segments.length; i++) {
      items.add(const Text(' / ',
          style: TextStyle(color: Colors.grey, fontSize: 12)));
      final seg = _segments[i];
      final isLast = i == _segments.length - 1;
      items.add(_Crumb(
        label: seg,
        onTap: isLast
            ? null
            : () {
                setState(() => _path = _prefixPath(i + 1));
                _load();
              },
      ));
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: items),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('加载失败', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(_error!, style: AppTheme.mono.copyWith(fontSize: 12)),
          const SizedBox(height: 12),
          FilledButton(onPressed: _query.isEmpty ? _load : () => _search(_query),
              child: const Text('重试')),
        ]),
      );
    }
    if (_nodes.isEmpty) {
      return Center(
          child: Text(_query.isEmpty ? '空目录' : '无匹配文件',
              style: const TextStyle(color: Colors.grey)));
    }
    return ListView.separated(
      itemCount: _nodes.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final n = _nodes[i];
        return ListTile(
          leading: Icon(n.isDir
              ? Icons.folder_outlined
              : Icons.insert_drive_file_outlined),
          title: Text(n.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: n.ignored
                  ? TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 14,
                      fontStyle: FontStyle.italic)
                  : const TextStyle(fontSize: 14)),
          subtitle: n.ignored
              ? Text('.gitignored',
                  style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.outline))
              : null,
          trailing: n.isDir ? const Icon(Icons.chevron_right) : null,
          onTap: () {
            if (n.isDir) {
              setState(() => _path = n.path);
              _load();
            } else {
              context.push(
                '/session/${widget.sessionId}/file'
                '?path=${Uri.encodeQueryComponent(n.path)}'
                '&directory=${Uri.encodeQueryComponent(widget.directory ?? '')}',
              );
            }
          },
        );
      },
    );
  }
}

class _Crumb extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _Crumb({required this.label, this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Text(label,
            style: TextStyle(
              fontSize: 12.5,
              color: onTap == null
                  ? Theme.of(context).colorScheme.outline
                  : Theme.of(context).colorScheme.primary,
              fontWeight: onTap == null ? FontWeight.w600 : FontWeight.normal,
            )),
      );
}
