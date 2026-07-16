import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/session/server_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SessionsTab extends StatefulWidget {
  const SessionsTab({super.key});

  @override
  State<SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<SessionsTab> {
  Timer? _periodicRefreshTimer;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话'),
      ),
      body: ListenableBuilder(
        listenable: serverStore,
        builder: (context, _) {
          if (!serverStore.connected && serverStore.bootstrapFailed) {
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
          if (!serverStore.connected) {
            return const Center(child: CircularProgressIndicator());
          }
          final sessions = serverStore.sortedSessions().toList();
          return RefreshIndicator(
            onRefresh: () async {
              final ok = await serverStore.refresh();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('刷新失败，请稍后再试')),
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
                        Text('暂无会话', style: Theme.of(context).textTheme.titleMedium),
                      ],
                    ),
                  )
                : ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final s = sessions[i];
                return _SessionTile(
                  session: s,
                  projectLabel: serverStore.projectDisplayOf(s),
                  worktreeLabel: serverStore.worktreeDisplayOf(s),
                  projectName: serverStore.projectDisplayOf(s),
                  project: serverStore.projectOf(s.projectID),
                  status: serverStore.statusOf(s.id).type,
                  preview: serverStore.lastMessageOf(s.id),
                  hasPermission:
                      serverStore.hasPendingPermission(s.id),
                  hasQuestion:
                      serverStore.hasPendingQuestion(s.id),
                  sseConnected:
                      serverStore.isSessionSseConnected(s.id),
                  onTap: () => context.push('/session/${s.id}'),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  final SessionModel session;
  final String projectLabel;
  final String worktreeLabel;
  final String projectName;
  final ProjectModel? project;
  final String status;
  final String? preview;
  final bool hasPermission;
  final bool hasQuestion;
  final bool sseConnected;
  final VoidCallback onTap;

  const _SessionTile({
    required this.session,
    required this.projectLabel,
    required this.worktreeLabel,
    required this.projectName,
    required this.project,
    required this.status,
    required this.preview,
    this.hasPermission = false,
    this.hasQuestion = false,
    this.sseConnected = true,
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
              reconnecting: !sseConnected && serverStore.sseReconnecting,
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
          if (hasPermission) ...[
            Icon(Icons.shield_outlined,
                size: 15, color: Theme.of(context).colorScheme.error),
            const SizedBox(width: 4),
          ],
          if (hasQuestion) ...[
            Icon(Icons.help_outline,
                size: 15, color: Theme.of(context).colorScheme.tertiary),
            const SizedBox(width: 4),
          ],
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
              StatusDot(type: status),
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

