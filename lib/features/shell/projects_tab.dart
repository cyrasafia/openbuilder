import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
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
          final items = _buildItems(context);
          if (items.isEmpty) {
            return const Center(
              child: Text('服务器上暂无项目',
                  style: TextStyle(fontSize: 14)),
            );
          }
          return RefreshIndicator(
            onRefresh: () => serverStore.refresh(),
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: items.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 76),
              itemBuilder: (context, i) {
                final it = items[i];
                return ListTile(
                  onTap: it.onTap,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  leading: ProjectAvatar(name: it.name, icon: it.icon),
                  title: Text(it.name,
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
                          child: Text(it.subtitle,
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
                            label: '${it.count} 会话'),
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

/// A project-list entry. The `global` project is expanded into one entry per
/// working directory (each shown as a pseudo-project, matching the desktop
/// client), while every other project is a single entry.
class _ProjItem {
  final String name;
  final String subtitle;
  final ProjectIcon? icon;
  final int count;
  final int lastUpdated;
  final VoidCallback onTap;
  const _ProjItem(
      {required this.name,
      required this.subtitle,
      this.icon,
      required this.count,
      required this.lastUpdated,
      required this.onTap});
}

List<_ProjItem> _buildItems(BuildContext context) {
  final items = <_ProjItem>[];
  for (final p in serverStore.projects) {
    if (p.id == 'global') {
      // Expand the global project into one entry per working directory.
      final byDir = <String, List<SessionModel>>{};
      for (final s in serverStore.sessions.where((s) => s.projectID == 'global')) {
        byDir.putIfAbsent(s.directory, () => []).add(s);
      }
      for (final entry in byDir.entries) {
        final dir = entry.key;
        final name = dir.isEmpty ? 'global' : dir.split('/').last;
        final last = entry.value.isEmpty
            ? 0
            : entry.value.map((s) => s.updated).reduce((a, b) => a > b ? a : b);
        items.add(_ProjItem(
          name: name,
          subtitle: dir.isEmpty ? 'global' : dir,
          count: entry.value.length,
          lastUpdated: last,
          onTap: () => context.push(
              '/project/global?directory=${Uri.encodeQueryComponent(dir)}'),
        ));
      }
      continue;
    }
    final sess = serverStore.sessions.where((s) => s.projectID == p.id).toList();
    final last = sess.isEmpty
        ? 0
        : sess.map((s) => s.updated).reduce((a, b) => a > b ? a : b);
    items.add(_ProjItem(
      name: p.displayName,
      subtitle: p.worktree,
      icon: p.icon,
      count: sess.length,
      lastUpdated: last,
      onTap: () => context.push('/project/${p.id}'),
    ));
  }
  items.sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
  return items;
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
