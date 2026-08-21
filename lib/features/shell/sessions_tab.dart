import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/session/server_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../../ui/l10n_ext.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  Timer? _periodicRefreshTimer;

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
    _periodicRefreshTimer?.cancel();
    super.dispose();
  }

  _SessionTile _cachedTile(SessionModel s) {
    final projectLabel = serverStore.projectDisplayOf(s);
    final sseConnected = serverStore.isSessionSseConnected(s.id);
    final tile = _tileCache[s.id];
    if (tile != null &&
        tile.session == s &&
        tile.projectLabel == projectLabel &&
        tile.worktreeLabel == serverStore.worktreeDisplayOf(s) &&
        tile.projectName == projectLabel &&
        identical(tile.project, serverStore.projectOf(s.projectID)) &&
        tile.agentState == serverStore.agentIndicatorStateOf(s.id) &&
        tile.preview == serverStore.lastMessageOf(s.id) &&
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
      sseConnected: sseConnected,
      sseReconnecting: serverStore.sseReconnecting,
      onTap: () => context.push('/session/${s.id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // See MainShell: tab is background behind pushed routes; must not rebuild
      // every frame of a foreground keyboard animation (no text input here).
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Text(l(context).tabSessions),
      ),
      body: ListenableBuilder(
        // JANK-5：预览走独立 previewVersion（120ms 节流），不随 serverStore
        // 全局广播；两者 merge 后，流式期间列表只在预览 tick 时重建。
        listenable: Listenable.merge([serverStore, serverStore.previewVersion]),
        builder: (context, _) {
          final hasCache = serverStore.sessions.isNotEmpty;
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
          final sessions = serverStore.sortedSessions().toList();
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
                        Text(l(context).noSessions, style: Theme.of(context).textTheme.titleMedium),
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
}

class _SessionTile extends StatelessWidget {
  final SessionModel session;
  final String projectLabel;
  final String worktreeLabel;
  final String projectName;
  final ProjectModel? project;
  final AgentIndicatorState agentState;
  final String? preview;
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
                child: Text(
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
