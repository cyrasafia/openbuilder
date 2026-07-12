import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ProjectsTab extends StatelessWidget {
  const ProjectsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('项目')),
      body: ListenableBuilder(
        listenable: serverStore,
        builder: (context, _) {
          if (!serverStore.connected && serverStore.projects.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          final projects = serverStore.sortedProjects();
          if (projects.isEmpty) {
            return const Center(
              child: Text('服务器上暂无项目',
                  style: TextStyle(fontSize: 14)),
            );
          }
          return RefreshIndicator(
            onRefresh: () => serverStore.refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: projects.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final p = projects[i];
                final sessions = serverStore.sessions
                    .where((s) => s.projectID == p.id)
                    .length;
                return ListTile(
                  onTap: () => context.push('/project/${p.id}'),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  leading: ProjectAvatar(name: p.displayName, icon: p.icon),
                  title: Text(p.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Row(children: [
                        Icon(Icons.source_outlined,
                            size: 12, color: Theme.of(context).colorScheme.outline),
                        const SizedBox(width: 3),
                        Expanded(
                          child: Text(p.worktree,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTheme.mono.copyWith(
                                  fontSize: 11.5,
                                  color: Theme.of(context).colorScheme.outline)),
                        ),
                      ]),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, children: [
                        _MetaChip(
                            icon: Icons.chat_bubble_outline,
                            label: '$sessions 会话'),
                      ]),
                    ],
                  ),
                  trailing: Icon(Icons.chevron_right,
                      color: Theme.of(context).colorScheme.outline),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _MetaChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 3),
          Text(label,
              style: TextStyle(
                  fontSize: 11, color: Theme.of(context).colorScheme.outline)),
        ],
      ),
    );
  }
}
