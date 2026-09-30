import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/session/server_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/search_app_bar.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  Timer? _periodicRefreshTimer;

  final _searchCtl = TextEditingController();
  bool _searchExpanded = false;
  String _query = '';

  void _collapseSearch() {
    _searchCtl.clear();
    setState(() {
      _searchExpanded = false;
      _query = '';
    });
  }

  // JANK-5：tile 实例缓存。serverStore 任意 notify（SSE 事件尾部/refresh/SSE
  // 状态）都会重跑 itemBuilder；_SessionTile 是值对象，内容未变时复用同一
  // widget 实例 → element 等值剪枝，整条子树跳过 rebuild。流式期间预览走
  // previewVersion（120ms 节流）也只重建预览变了的 tile。缓存键含全部显示
  // 字段——以 sessions 快照+索引为键，列表结构变化（增删/排序）自然失配。
  final _tileCache = <String, _SessionTile>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Refresh on entry + set up periodic refresh while visible.
    serverStore.refreshListAndWorkingSse(force: false);
    _periodicRefreshTimer?.cancel();
    _periodicRefreshTimer = Timer.periodic(
        ServerStore.kMaxRefreshInterval,
        (_) => serverStore.refreshListAndWorkingSse(force: false));
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    _periodicRefreshTimer?.cancel();
    super.dispose();
  }

  _SessionTile _cachedTile(SessionModel s) {
    final projectLabel = serverStore.projectDisplayOf(s);
    final sseConnected = serverStore.isSessionSseConnected(s.id);
    final stalePreview = serverStore.isSessionStale(s.id) &&
        !serverStore.hasLivePreview(s.id);
    final tile = _tileCache[s.id];
    if (tile != null &&
        tile.session == s &&
        tile.projectLabel == projectLabel &&
        tile.worktreeLabel == serverStore.worktreeDisplayOf(s) &&
        tile.projectName == projectLabel &&
        identical(tile.project, serverStore.projectOf(s.projectID)) &&
        tile.agentState == serverStore.agentIndicatorStateOf(s.id) &&
        tile.preview == serverStore.lastMessageOf(s.id) &&
        tile.stalePreview == stalePreview &&
        tile.sseConnected == sseConnected &&
        tile.sseReconnecting == serverStore.sseReconnecting) {
      return tile;
    }
    return _tileCache[s.id] = _SessionTile(
      session: s,
      projectLabel: projectLabel,
      worktreeLabel: serverStore.worktreeDisplayOf(s),
      projectName: projectLabel,
      project: serverStore.projectOf(s.projectID),
      agentState: serverStore.agentIndicatorStateOf(s.id),
      preview: serverStore.lastMessageOf(s.id),
      stalePreview: stalePreview,
      sseConnected: sseConnected,
      sseReconnecting: serverStore.sseReconnecting,
      onTap: () => context.push('/session/${s.id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // See MainShell: tab is background behind pushed routes; the search
      // field keeps its TextInputConnection during keyboard animations, so
      // the freeze in MainShell handles those frames instead of
      // resizeToAvoidBottomInset.
      resizeToAvoidBottomInset: false,
      appBar: SearchAppBar(
        searchHint: l(context).sessionSearchHint,
        expanded: _searchExpanded,
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v.trim()),
        onExpand: () => setState(() => _searchExpanded = true),
        onExitSearch: _collapseSearch,
        collapsedTitle: l(context).tabSessions,
      ),
      body: ListenableBuilder(
        // JANK-5：预览走独立 previewVersion（120ms 节流），不随 serverStore
        // 全局广播；两者 merge 后，流式期间列表只在预览 tick 时重建。
        listenable: Listenable.merge([serverStore, serverStore.previewVersion]),
        builder: (context, _) {
          final hasCache = serverStore.sessions.isNotEmpty;
          // Initial connect in flight (e.g. right after adding a server):
          // loading state wins over the stale error/empty views.
          if (serverStore.connecting && !hasCache) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!serverStore.connected && !hasCache) {
            if (serverStore.bootstrapFailed) {
              return RefreshIndicator(
                onRefresh: () => serverStore.refresh(),
                child: emptyScrollable(
                  ErrorView(
                    onRetry: () => connectionStore.active != null
                        ? serverStore.connect(connectionStore.active!)
                        : null,
                  ),
                ),
              );
            }
            return const Center(child: CircularProgressIndicator());
          }
          final all = serverStore.sortedSessions().toList();
          final sessions =
              all.where((s) => _matchesQuery(s, _query)).toList();
          _pruneTileCache(sessions);
          return RefreshIndicator(
            onRefresh: () async {
              final ok = await refreshOrReconnect();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l(context).refreshFailed)),
                );
              }
            },
            child: sessions.isEmpty
                ? emptyScrollable(
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline,
                            size: 56, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(height: 12),
                        // A query that filtered real rows out says "no match";
                        // a server that never had rows says "no sessions".
                        Text(
                            _query.isNotEmpty && all.isNotEmpty
                                ? l(context).sessionNoMatch
                                : l(context).noSessions,
                            style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  )
                : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                return _cachedTile(sessions[i]);
              },
            ),
          );
        },
      ),
    );
  }

  void _pruneTileCache(List<SessionModel> sessions) {
    final ids = {for (final s in sessions) s.id};
    _tileCache.removeWhere((id, _) => !ids.contains(id));
  }

  /// Case-insensitive substring hit on the session title, project label or
  /// worktree/directory path. Matches what the tile displays.
  bool _matchesQuery(SessionModel s, String query) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    final project = serverStore.projectDisplayOf(s);
    final projectPath = s.projectID == 'global'
        ? s.directory
        : (serverStore.projectOf(s.projectID)?.canonical ?? s.directory);
    return s.title.toLowerCase().contains(q) ||
        project.toLowerCase().contains(q) ||
        projectPath.toLowerCase().contains(q) ||
        s.dirName.toLowerCase().contains(q);
  }
}

class _SessionTile extends StatelessWidget {
  final SessionModel session;
  final String projectLabel;
  final String worktreeLabel;
  final String projectName;
  final ProjectModel? project;
  final AgentIndicatorState agentState;
  final String? preview;
  final bool stalePreview;
  final bool sseConnected;
  final bool sseReconnecting;
  final VoidCallback onTap;

  const _SessionTile({
    required this.session,
    required this.projectLabel,
    required this.worktreeLabel,
    required this.projectName,
    required this.project,
    required this.agentState,
    required this.preview,
    required this.stalePreview,
    required this.sseConnected,
    required this.sseReconnecting,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: Stack(
        clipBehavior: Clip.none,
        children: [
          ProjectAvatar(name: projectName, icon: project?.icon),
          Positioned(
            right: -2,
            bottom: -2,
            child: SseStatusDot(
              connected: sseConnected,
              reconnecting: !sseConnected && sseReconnecting,
              size: 10,
            ),
          ),
        ],
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontWeight: FontWeight.w600, fontSize: 15),
            ),
          ),
          const SizedBox(width: 8),
          Text(relTime(session.updated),
              style: TextStyle(fontSize: 11.5, color: muted)),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Row(
            children: [
              AgentStatusIndicator(state: agentState),
              const SizedBox(width: 6),
              Expanded(
                child: stalePreview
                    ? Text(
                        l(context).previewSyncing,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 13,
                            color: muted,
                            fontStyle: FontStyle.italic),
                      )
                    : Text(
                        preview ?? '—',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: muted),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.folder_outlined, size: 12, color: muted),
              const SizedBox(width: 3),
              Flexible(
                child: Text(projectLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: muted)),
              ),
              if (worktreeLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                Icon(Icons.call_split, size: 12, color: muted),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(
                    worktreeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono.copyWith(fontSize: 11.5, color: muted),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
