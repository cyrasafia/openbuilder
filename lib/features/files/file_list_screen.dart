import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/attachments/file_ref.dart';
import '../../core/net/net_error.dart';
import '../../core/session/file_browsing_store.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'file_browsing_container.dart';

class FileListScreen extends StatefulWidget {
  final String sessionId;
  final String? directory;
  final String? initialPath;
  final FileListRestore? restore;
  const FileListScreen({
    super.key,
    required this.sessionId,
    this.directory,
    this.initialPath,
    this.restore,
  });

  @override
  State<FileListScreen> createState() => _FileListScreenState();
}

class _FileListScreenState extends State<FileListScreen> {
  String _path = '';
  List<FileNode> _nodes = [];
  bool _loading = true;
  Object? _error;
  String _query = '';
  final _searchCtl = TextEditingController();
  final _crumbScrollCtl = ScrollController();
  final _scrollCtl = ScrollController();
  String? _lastCrumbPath;
  bool _searchExpanded = false;
  bool _restoring = false;
  double? _pendingScrollRestore;

  @override
  void initState() {
    super.initState();
    _path = widget.initialPath ?? '';
    final r = widget.restore;
    if (r != null) {
      _restoring = true;
      _searchExpanded = r.searchExpanded;
      _query = r.searchQuery;
      _searchCtl.text = r.searchQuery;
      _pendingScrollRestore = r.scrollOffset;
      if (r.searchQuery.isNotEmpty) {
        _search(r.searchQuery);
      } else {
        _load();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoring = false;
      });
    } else {
      _load();
    }
  }

  FileBrowsingContainerState? _container;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _container = FileBrowsingContainer.maybeOf(context);
    _container?.registerCollector(this, _collectSelf);
    _container?.registerBackInterceptor(_interceptBack);
  }

  @override
  void dispose() {
    _container?.unregisterCollector(this);
    _container?.unregisterBackInterceptor(_interceptBack);
    _searchCtl.dispose();
    _crumbScrollCtl.dispose();
    _scrollCtl.dispose();
    super.dispose();
  }

  bool _interceptBack() {
    if (_searchExpanded) {
      _collapseSearch();
      return true;
    }
    if (_path.isNotEmpty) {
      _goUp();
      return true;
    }
    return false;
  }

  double get _listScrollOffset =>
      _scrollCtl.hasClients ? _scrollCtl.position.pixels : 0;

  void _collectSelf() {
    serverStore.fileBrowsing.collectList(
      widget.sessionId,
      widget.directory,
      path: _path,
      scrollOffset: _listScrollOffset,
      searchQuery: _query,
      searchExpanded: _searchExpanded,
    );
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

  Future<void> _load() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() => _error = const KnownError(FriendlyErrorKind.notConnected));
      return;
    }
    setState(() => _loading = true);
    try {
      _nodes = await c.listFiles(
        directory: widget.directory ?? '',
        path: _path,
      );
      _nodes = _sortNodes(_nodes);
      _error = null;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
      if (_error == null) _scheduleScrollRestore();
    }
  }

  List<FileNode> _sortNodes(List<FileNode> list) {
    list.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  String _parentPath(String relPath) {
    final p = relPath.endsWith('/')
        ? relPath.substring(0, relPath.length - 1)
        : relPath;
    final idx = p.lastIndexOf('/');
    return idx <= 0 ? '' : p.substring(0, idx);
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
      _lastCrumbPath = null;
    });
    try {
      _nodes = await c.findFiles(
        directory: widget.directory ?? '',
        path: _segments.join('/'),
        query: q,
      );
      _error = null;
    } catch (e) {
      _error = e;
    } finally {
      if (mounted) setState(() => _loading = false);
      if (_error == null) _scheduleScrollRestore();
    }
  }

  List<String> get _segments => _path.isEmpty
      ? const []
      : _path.split('/').where((s) => s.isNotEmpty).toList();

  String _prefixPath(int segmentIndex) =>
      _segments.take(segmentIndex).join('/');

  void _goUp() {
    final segs = _segments;
    if (segs.isEmpty) return;
    setState(() => _path = segs.take(segs.length - 1).join('/'));
    _load();
  }

  void _collapseSearch() {
    _searchCtl.clear();
    setState(() {
      _searchExpanded = false;
      _query = '';
    });
    _load();
  }

  Future<void> _showRefMenu(BuildContext context, FileNode n) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: Text(l(ctx).fileRefToSession(n.name)),
              onTap: () => Navigator.pop(ctx, 'ref'),
            ),
            if (!n.isDir)
              ListTile(
                leading: const Icon(Icons.visibility_outlined),
                title: Text(l(ctx).filePreview),
                onTap: () => Navigator.pop(ctx, 'view'),
              ),
          ],
        ),
      ),
    );
    if (action == 'ref') {
      _refNode(n);
    } else if (action == 'view' && !n.isDir) {
      _container?.openFile(n.path);
    }
  }

  void _refNode(FileNode n) {
    final ref = FileRef.fromNode(n, directory: widget.directory);
    if (ref.absolute.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l(context).fileRefNoAbsolutePath)),
      );
      return;
    }
    _container?.applyReference(ref);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _searchExpanded
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: l(context).fileSearchHint,
                onPressed: _collapseSearch,
              )
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => _container?.handleBack(),
              ),
        title: _searchExpanded
            ? TextField(
                controller: _searchCtl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: l(context).fileSearchHint,
                  isDense: true,
                  border: InputBorder.none,
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
                  if (_restoring) return;
                  if (v.isEmpty && _query.isNotEmpty) {
                    setState(() => _query = '');
                    _load();
                  } else if (v.isNotEmpty) {
                    _search(v);
                  }
                },
              )
            : Text(l(context).fileTitle, style: const TextStyle(fontSize: 16)),
        actions: [
          if (!_searchExpanded)
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: l(context).fileSearchHint,
              onPressed: () => setState(() => _searchExpanded = true),
            ),
          if (!_searchExpanded) const FileCollapseAction(),
          appBarActionsTrailing,
        ],
      ),
      body: Column(
        children: [
          if (_query.isEmpty) _breadcrumb(),
          const Divider(height: 1),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _breadcrumb() {
    final items = <Widget>[];
    items.add(
      _Crumb(
        label: l(context).fileWorkspace,
        onTap: _segments.isNotEmpty
            ? () {
                setState(() => _path = '');
                _load();
              }
            : null,
      ),
    );
    for (var i = 0; i < _segments.length; i++) {
      items.add(
        const Text(' / ', style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
      final seg = _segments[i];
      final isLast = i == _segments.length - 1;
      items.add(
        _Crumb(
          label: seg,
          onTap: isLast
              ? null
              : () {
                  setState(() => _path = _prefixPath(i + 1));
                  _load();
                },
        ),
      );
    }
    if (_lastCrumbPath != _path) {
      _lastCrumbPath = _path;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_crumbScrollCtl.hasClients &&
            _crumbScrollCtl.position.hasContentDimensions) {
          _crumbScrollCtl.jumpTo(_crumbScrollCtl.position.maxScrollExtent);
        }
      });
    }
    return SingleChildScrollView(
      controller: _crumbScrollCtl,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(children: items),
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
            FilledButton(
              onPressed: _query.isEmpty ? _load : () => _search(_query),
              child: Text(l(context).retry),
            ),
          ],
        ),
      );
    }
    if (_nodes.isEmpty) {
      return Center(
        child: Text(
          _query.isEmpty ? l(context).fileEmptyDir : l(context).fileNoMatch,
          style: const TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.separated(
      controller: _scrollCtl,
      itemCount: _nodes.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final n = _nodes[i];
        return ListTile(
          leading: Icon(
            n.isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
          ),
          title: Text(
            n.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: n.ignored
                ? TextStyle(
                    color: Theme.of(context).colorScheme.outline,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  )
                : const TextStyle(fontSize: 14),
          ),
          subtitle: (_query.isNotEmpty && _parentPath(n.path).isNotEmpty)
              ? Text(
                  _parentPath(n.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline,
                  ),
                )
              : null,
          trailing: n.isDir ? const Icon(Icons.chevron_right) : null,
          onTap: () {
            if (n.isDir) {
              setState(() => _path = n.path);
              _load();
            } else {
              _container?.openFile(n.path);
            }
          },
          onLongPress: () => _showRefMenu(context, n),
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
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12.5,
        color: onTap == null
            ? Theme.of(context).colorScheme.outline
            : Theme.of(context).colorScheme.primary,
        fontWeight: onTap == null ? FontWeight.w600 : FontWeight.w400,
      ),
    ),
  );
}
