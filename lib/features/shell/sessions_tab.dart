import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SessionsTab extends StatelessWidget {
  const SessionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('会话')),
      body: ListenableBuilder(
        listenable: serverStore,
        builder: (context, _) {
          if (!serverStore.connected && serverStore.error == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (serverStore.error != null && serverStore.sessions.isEmpty) {
            return _ErrorView(
              message: serverStore.error!,
              onRetry: () => connectionStore.active != null
                  ? serverStore.connect(connectionStore.active!)
                  : null,
            );
          }
          final sessions = serverStore.sortedSessions().toList();
          if (sessions.isEmpty) {
            return const _EmptyView(
              icon: Icons.chat_bubble_outline,
              message: '暂无会话',
            );
          }
          return RefreshIndicator(
            onRefresh: () => serverStore.refresh(),
            child: ListView.separated(
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
  final VoidCallback onTap;

  const _SessionTile({
    required this.session,
    required this.projectLabel,
    required this.worktreeLabel,
    required this.projectName,
    required this.project,
    required this.status,
    required this.preview,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      leading: ProjectAvatar(name: projectName, icon: project?.icon),
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
          Text(relTime(serverStore.lastMessageTimeOf(session.id) ?? session.updated),
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
          ),
        ],
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  final IconData icon;
  final String message;
  const _EmptyView({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(message, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const _ErrorView({required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('连接失败',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: AppTheme.mono.copyWith(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(
                  onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}
