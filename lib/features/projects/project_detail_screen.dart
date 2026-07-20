import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'worktree_order.dart';

class ProjectDetailScreen extends StatelessWidget {
  final String projectId;
  final String? directory;
  const ProjectDetailScreen({
    super.key,
    required this.projectId,
    this.directory,
  });

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
        final sessions =
            serverStore.sessions
                .where(
                  (s) =>
                      s.projectID == projectId &&
                      (directory == null || s.directory == directory),
                )
                .toList()
              ..sort((a, b) => b.updated.compareTo(a.updated));

        // A `global` project scoped to a single directory behaves like an
        // ordinary single-worktree project (flat list, no section header).
        final scopedTitle = directory == null
            ? (project?.displayName ?? 'global')
            : (directory!.isEmpty ? 'global' : directory!.split('/').last);
        final scopedWorktree = directory ?? (project?.worktree ?? '');
        final textScaler = MediaQuery.textScalerOf(context);
        final p = project;
        final wsCapable = p?.workspaceCapable ?? false;
        final wsEnabled = wsCapable && serverStore.workspaceEnabled(p!.id);
        final subLines = 2 + (wsEnabled ? 1 : 0);
        final scaledTitleHeight =
            textScaler.scale(16) * 1.2 + textScaler.scale(11) * 1.2 * subLines + 4;
        final toolbarHeight = scaledTitleHeight + 16 < 76
            ? 76.0
            : scaledTitleHeight + 16;

        return Scaffold(
          appBar: AppBar(
            toolbarHeight: toolbarHeight,
            title: _ProjectAppBarTitle(
              name: scopedTitle,
              icon: project?.icon,
              worktree: scopedWorktree,
              sessionCount: sessions.length,
              workspaceEnabled: wsEnabled,
            ),
            actions: [
              if (wsCapable)
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'toggle_workspace') {
                      final next =
                          !serverStore.workspaceEnabled(p!.id);
                      serverStore.setWorkspaceEnabled(p.id, next);
                    }
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'toggle_workspace',
                      child: Text(serverStore.workspaceEnabled(p!.id)
                          ? '关闭工作区'
                          : '开启工作区'),
                    ),
                  ],
                ),
            ],
          ),
          floatingActionButton: (project != null && project.id != 'global')
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.add_comment_outlined),
                  label: const Text('新建会话'),
                  onPressed: () => _startCreateSession(context, project),
                )
              : null,
          body: ListView(
            children: [
              if (sessions.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: Text('无活跃会话')),
                )
              else if (project?.id == 'global' && directory == null)
                ..._groupedGlobal(context, sessions)
              else
                ..._groupedByWorktree(
                  context,
                  sessions,
                  scopedWorktree,
                  project?.sandboxes ?? const [],
                ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startCreateSession(
    BuildContext context,
    ProjectModel project,
  ) async {
    if (!project.workspaceCapable ||
        !serverStore.workspaceEnabled(project.id)) {
      await _createSession(context, project.worktree);
      return;
    }
    final directory = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                title: const Text('选择工作区'),
                titleTextStyle: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              ...[project.worktree, ...project.sandboxes].map(
                (dir) => ListTile(
                  leading: const Icon(Icons.call_split),
                  title: Text(dir.split('/').last),
                  subtitle: Text(
                    dir,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => Navigator.pop(ctx, dir),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.create_new_folder_outlined),
                title: const Text('新建工作区'),
                onTap: () => Navigator.pop(ctx, ''),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || directory == null) return;
    if (directory.isEmpty) {
      await _createWorktree(
        context,
        project.worktree,
        createSessionAfterward: true,
      );
      return;
    }
    await _createSession(context, directory);
  }

  Future<void> _createSession(BuildContext context, String directory) async {
    try {
      final session = await serverStore.createSession(directory);
      if (context.mounted) context.push('/session/${session.id}');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
      }
    }
  }

  Future<void> _createWorktree(
    BuildContext context,
    String projectDir, {
    bool createSessionAfterward = false,
  }) async {
    final client = serverStore.client;
    if (client == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未连接服务器')),
        );
      }
      return;
    }
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              const Text('正在创建工作区…'),
            ],
          ),
        ),
      ),
    );
    try {
      final result = await client.createWorktree(projectDir);
      if (context.mounted) Navigator.of(context).pop();
      unawaited(serverStore.refresh());
      if (!createSessionAfterward && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已创建工作区：${result.name}')),
        );
      }
      if (context.mounted && createSessionAfterward) {
        await _createSession(context, result.directory);
      }
    } catch (e) {
      if (context.mounted) Navigator.of(context).pop();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('创建失败：$e')),
        );
      }
    }
  }

  void _confirmRemoveWorktree(
    BuildContext context,
    String projectWorktree,
    String worktreeDir,
  ) {
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
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () async {
              final client = serverStore.client;
              if (client == null) {
                if (ctx.mounted) Navigator.pop(ctx);
                return;
              }
              try {
                await client.removeWorktree(
                  projectWorktree,
                  worktreeDir: worktreeDir,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                unawaited(serverStore.refresh());
                if (ctx.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('已删除工作区「$wtName」')));
                }
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('删除失败：$e')));
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
      out.addAll(
        entry.value.map(
          (s) => _SessionRow(
            session: s,
            agentState: serverStore.agentIndicatorStateOf(s.id),
            preview: serverStore.lastMessageOf(s.id),
            onTap: () => context.push('/session/${s.id}'),
          ),
        ),
      );
    }
    return out;
  }

  /// Section sessions by worktree (directory). Section headers are shown only
  /// when the project spans more than one worktree, so single-worktree
  /// projects keep a flat list. The main worktree is pinned first, followed by
  /// sandboxes in server creation order; within a group, sessions keep the
  /// global recency order.
  List<Widget> _groupedByWorktree(
    BuildContext context,
    List<SessionModel> all,
    String projectWorktree,
    List<String> sandboxes,
  ) {
    final byDir = <String, List<SessionModel>>{};
    for (final s in all) {
      byDir.putIfAbsent(s.directory, () => []).add(s);
    }
    final sandboxOrder = <String, int>{
      for (var i = 0; i < sandboxes.length; i++) sandboxes[i]: i,
    };
    final groups = byDir.entries.toList()
      ..sort(
        (a, b) => compareWorktreePaths(
          a.key,
          b.key,
          mainWorktree: projectWorktree,
          sandboxOrder: sandboxOrder,
        ),
      );
    final out = <Widget>[];
    for (final entry in groups) {
      if (byDir.length > 1) {
        final name = entry.key.isEmpty ? 'global' : entry.key.split('/').last;
        // Only non-main worktrees (sandboxes) can be removed.
        final canDelete = entry.key.isNotEmpty && entry.key != projectWorktree;
        out.add(
          _SectionHeader(
            name: name,
            count: entry.value.length,
            onDelete: canDelete
                ? () => _confirmRemoveWorktree(
                    context,
                    projectWorktree,
                    entry.key,
                  )
                : null,
          ),
        );
      }
      out.addAll(
        entry.value.map(
          (s) => _SessionRow(
            session: s,
            agentState: serverStore.agentIndicatorStateOf(s.id),
            preview: serverStore.lastMessageOf(s.id),
            onTap: () => context.push('/session/${s.id}'),
          ),
        ),
      );
    }
    return out;
  }
}

class _ProjectAppBarTitle extends StatelessWidget {
  final String name;
  final ProjectIcon? icon;
  final String worktree;
  final int sessionCount;
  final bool workspaceEnabled;
  const _ProjectAppBarTitle({
    required this.name,
    required this.icon,
    required this.worktree,
    required this.sessionCount,
    required this.workspaceEnabled,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Row(
      children: [
        ProjectAvatar(name: name, icon: icon, size: 42),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                worktree,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono.copyWith(fontSize: 11, color: muted),
              ),
              const SizedBox(height: 2),
              Text(
                '$sessionCount 个未存档会话',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: muted),
              ),
              if (workspaceEnabled) ...[
                const SizedBox(height: 2),
                Text('工作区：开启',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: muted)),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String name;
  final int count;
  final VoidCallback? onDelete;
  const _SectionHeader({
    required this.name,
    required this.count,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.call_split,
            size: 14,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono.copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.outline,
            ),
          ),
          if (onDelete != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  Icons.delete_outline,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  final SessionModel session;
  final AgentIndicatorState agentState;
  final String? preview;
  final VoidCallback onTap;
  const _SessionRow({
    required this.session,
    required this.agentState,
    required this.preview,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return ListTile(
      onTap: onTap,
      dense: true,
      title: Row(
        children: [
          AgentStatusIndicator(state: agentState),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              session.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            relTime(session.updated),
            style: TextStyle(fontSize: 11.5, color: muted),
          ),
        ],
      ),
      subtitle: preview == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(left: 17, top: 2),
              child: Text(
                preview!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: muted),
              ),
            ),
    );
  }
}
