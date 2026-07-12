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
                ..._groupedByWorktree(context, sessions),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
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
      BuildContext context, List<SessionModel> all) {
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
        out.add(_SectionHeader(name: name, count: entry.value.length));
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
                        fontSize: 17, fontWeight: FontWeight.w700)),
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
  const _SectionHeader({required this.name, required this.count});

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