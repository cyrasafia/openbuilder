import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/session/server_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key});

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
  Timer? _periodicRefreshTimer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
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
      appBar: AppBar(title: const Text('项目')),
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
          final items = _buildItems(context);
          return RefreshIndicator(
            onRefresh: () => serverStore.refresh(),
            child: items.isEmpty
                ? emptyScrollable(
                    const Text('服务器上暂无项目',
                        style: TextStyle(fontSize: 14)),
                  )
                : ListView.separated(
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
  final int lastActivity;
  final VoidCallback onTap;
  const _ProjItem(
      {required this.name,
      required this.subtitle,
      this.icon,
      required this.count,
      required this.lastActivity,
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
        // Sort key comes from the monotonic activity map (includes archived
        // sessions) so archiving the last session in this directory doesn't
        // sink the row. Count chip still shows unarchived session count.
        final last = serverStore.lastActivityForGlobalDir(dir);
        items.add(_ProjItem(
          name: name,
          subtitle: dir.isEmpty ? 'global' : dir,
          count: entry.value.length,
          lastActivity: last,
          onTap: () => context.push(
              '/project/global?directory=${Uri.encodeQueryComponent(dir)}'),
        ));
      }
      continue;
    }
    final sess = serverStore.sessions.where((s) => s.projectID == p.id).toList();
    // See note above: monotonic activity (includes archived) for sort,
    // unarchived count for the chip.
    final last = serverStore.lastActivityForProject(p.id);
    items.add(_ProjItem(
      name: p.displayName,
      subtitle: p.worktree,
      icon: p.icon,
      count: sess.length,
      lastActivity: last,
      onTap: () => context.push('/project/${p.id}'),
    ));
  }
  items.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
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
