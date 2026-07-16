import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ProjectDetailScreen extends StatelessWidget {
  final String projectId;
  final String? directory;
  const ProjectDetailScreen(
      {super.key, required this.projectId, this.directory});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: serverStore,
      builder: (context, _) {
        final project = serverStore.projectOf(projectId);
        if (project == null && directory == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('项目不存在')),
          );
        }
        final sessions = serverStore.sessions
            .where((s) =>
                s.projectID == projectId &&
                (directory == null || s.directory == directory))
            .toList()
          ..sort((a, b) => b.updated.compareTo(a.updated));

        // A `global` project scoped to a single directory behaves like an
        // ordinary single-worktree project (flat list, no section header).
        final scopedTitle = directory == null
            ? (project?.displayName ?? 'global')
            : (directory!.isEmpty ? 'global' : directory!.split('/').last);
        final scopedWorktree =
            directory ?? (project?.worktree ?? '');

        return Scaffold(
          appBar: AppBar(title: Text(scopedTitle)),
          floatingActionButton: (project != null && project.id != 'global')
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('新建工作区'),
                  onPressed: () => _showCreateWorktreeDialog(
                      context, project.worktree),
                )
              : null,
          body: ListView(
            children: [
              _Header(
                  name: scopedTitle,
                  worktree: scopedWorktree,
                  sessionCount: sessions.length),
              const Divider(height: 1),
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('无活跃会话')),
                )
              else if (project?.id == 'global' && directory == null)
                ..._groupedGlobal(context, sessions)
              else
                ..._groupedByWorktree(context, sessions, scopedWorktree),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  void _showCreateWorktreeDialog(BuildContext context, String projectDir) {
    final nameCtl = TextEditingController();
    final cmdCtl = TextEditingController();
    bool creating = false;
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSt) {
          return AlertDialog(
            title: const Text('新建工作区'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '工作区名称',
                    hintText: '如 feature-x',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: cmdCtl,
                  decoration: const InputDecoration(
                    labelText: '启动命令（可选）',
                    hintText: '工作区创建后运行的脚本',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: creating ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: creating
                    ? null
                    : () async {
                        final name = nameCtl.text.trim();
                        if (name.isEmpty) return;
                        setSt(() => creating = true);
                        final client = serverStore.client;
                        if (client == null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          return;
                        }
                        try {
                          final result = await client.createWorktree(projectDir,
                              name: name,
                              startCommand: cmdCtl.text.trim().isEmpty
                                  ? null
                                  : cmdCtl.text.trim());
                          if (ctx.mounted) Navigator.pop(ctx);
                          // Refresh to pick up the new worktree + its sessions.
                          unawaited(serverStore.refresh());
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(
                                    '已创建：${result.name} (${result.branch ?? "?"})')));
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setSt(() => creating = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('创建失败：$e')));
                          }
                        }
                      },
                child: creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('创建'),
              ),
            ],
          );
        });
      },
    );
  }

  void _confirmRemoveWorktree(
      BuildContext context, String projectWorktree, String worktreeDir) {
    final wtName = worktreeDir.split('/').last;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除工作区'),
        content: Text('确定删除工作区「$wtName」？\n该工作区下的会话将一并移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () async {
              final client = serverStore.client;
              if (client == null) {
                if (ctx.mounted) Navigator.pop(ctx);
                return;
              }
              try {
                await client.removeWorktree(projectWorktree,
                    worktreeDir: worktreeDir);
                if (ctx.mounted) Navigator.pop(ctx);
                unawaited(serverStore.refresh());
                if (ctx.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('已删除工作区「$wtName」')));
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('删除失败：$e')));
                }
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  List<Widget> _groupedGlobal(BuildContext context, List<SessionModel> all) {
    final byDir = <String, List<SessionModel>>{};
    for (final s in all) {
      byDir.putIfAbsent(s.dirName, () => []).add(s);
    }
    final out = <Widget>[];
    for (final entry in byDir.entries) {
      out.add(_SectionHeader(name: entry.key, count: entry.value.length));
      out.addAll(entry.value.map((s) => _SessionRow(
            session: s,
            status: serverStore.statusOf(s.id).type,
            preview: serverStore.lastMessageOf(s.id),
            onTap: () => context.push('/session/${s.id}'),
          )));
    }
    return out;
  }

  /// Section sessions by worktree (directory). Section headers are shown only
  /// when the project spans more than one worktree, so single-worktree
  /// projects keep a flat list. Groups are ordered by their most recent
  /// activity (busiest worktree first); within a group, sessions keep the
  /// global recency order.
  List<Widget> _groupedByWorktree(
      BuildContext context, List<SessionModel> all, String projectWorktree) {
    final byDir = <String, List<SessionModel>>{};
    for (final s in all) {
      byDir.putIfAbsent(s.directory, () => []).add(s);
    }
    final groups = byDir.entries.toList()
      ..sort((a, b) {
        final at = a.value.map((s) => s.updated).reduce((x, y) => x > y ? x : y);
        final bt = b.value.map((s) => s.updated).reduce((x, y) => x > y ? x : y);
        return bt.compareTo(at);
      });
    final out = <Widget>[];
    for (final entry in groups) {
      if (byDir.length > 1) {
        final name =
            entry.key.isEmpty ? 'global' : entry.key.split('/').last;
        // Only non-main worktrees (sandboxes) can be removed.
        final canDelete = entry.key.isNotEmpty && entry.key != projectWorktree;
        out.add(_SectionHeader(
          name: name,
          count: entry.value.length,
          onDelete: canDelete
              ? () => _confirmRemoveWorktree(
                  context, projectWorktree, entry.key)
              : null,
        ));
      }
      out.addAll(entry.value.map((s) => _SessionRow(
            session: s,
            status: serverStore.statusOf(s.id).type,
            preview: serverStore.lastMessageOf(s.id),
            onTap: () => context.push('/session/${s.id}'),
          )));
    }
    return out;
  }
}

class _Header extends StatelessWidget {
  final String name;
  final String worktree;
  final int sessionCount;
  const _Header(
      {required this.name,
      required this.worktree,
      required this.sessionCount});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          ProjectAvatar(name: name, size: 52),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 17, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(worktree,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono.copyWith(fontSize: 12, color: muted)),
                const SizedBox(height: 6),
                Text('$sessionCount 个未存档会话',
                    style: TextStyle(fontSize: 12, color: muted)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback? onDelete;
  const _SectionHeader({required this.name, required this.count, this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(children: [
        Icon(Icons.call_split,
            size: 14, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 6),
        Expanded(
          child: Text(name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono.copyWith(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface)),
        ),
        Text('$count',
            style: TextStyle(
                fontSize: 11, color: Theme.of(context).colorScheme.outline)),
        if (onDelete != null) ...[
          const SizedBox(width: 8),
          InkWell(
            onTap: onDelete,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.delete_outline,
                  size: 16, color: Theme.of(context).colorScheme.error),
            ),
          ),
        ],
      ]),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final SessionModel session;
  final String status;
  final String? preview;
  final VoidCallback onTap;
  const _SessionRow(
      {required this.session,
      required this.status,
      required this.preview,
      required this.onTap});

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return ListTile(
      onTap: onTap,
      dense: true,
      title: Row(
        children: [
          StatusDot(type: status),
          const SizedBox(width: 8),
          Expanded(
            child: Text(session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          Text(relTime(session.updated),
              style: TextStyle(fontSize: 11.5, color: muted)),
        ],
      ),
      subtitle: preview == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 17, top: 2),
              child: Text(preview!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: muted)),
            ),
    );
  }
}