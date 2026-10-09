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
import '../projects/worktree_order.dart';

class ProjectsTab extends StatefulWidget {
  const ProjectsTab({super.key});

  @override
  State<ProjectsTab> createState() => _ProjectsTabState();
}

class _ProjectsTabState extends State<ProjectsTab> {
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
    _searchCtl.dispose();
    _periodicRefreshTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // See MainShell: background behind pushed routes. The search field is a
      // rare text input here, so the freeze in MainShell handles keyboard
      // frames instead of resizeToAvoidBottomInset.
      resizeToAvoidBottomInset: false,
      appBar: SearchAppBar(
        searchHint: l(context).projectSearchHint,
        expanded: _searchExpanded,
        controller: _searchCtl,
        onChanged: (v) => setState(() => _query = v.trim()),
        onExpand: () => setState(() => _searchExpanded = true),
        onExitSearch: _collapseSearch,
        collapsedTitle: l(context).tabProjects,
      ),
      body: ListenableBuilder(
        listenable: serverStore,
        builder: (context, _) {
          final hasCache = serverStore.projects.isNotEmpty ||
              serverStore.sessions.isNotEmpty;
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
          final items = _buildItems(context, _query);
          // Unfiltered row count — decides the empty-state wording: a query
          // that filtered real rows out says "no match"; a server that never
          // had rows (e.g. a session-less global-only project) says "no
          // projects" regardless of the query.
          final unfiltered = _query.isEmpty ? items : _buildItems(context, '');
          return RefreshIndicator(
            onRefresh: () async {
              final ok = await refreshOrReconnect();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l(context).refreshFailed)),
                );
              }
            },
            child: items.isEmpty
                ? emptyScrollable(
                    Text(
                        unfiltered.isNotEmpty
                            ? l(context).projectNoMatch
                            : l(context).noProjects,
                        style: const TextStyle(fontSize: 14)),
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
                      _SessionStatusSummary(states: it.states),
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
  final List<AgentIndicatorState> states;
  final int lastActivity;
  final VoidCallback onTap;
  const _ProjItem(
      {required this.name,
      required this.subtitle,
      this.icon,
      required this.states,
      required this.lastActivity,
      required this.onTap});
}

/// Matches a project-list entry against [query]: case-insensitive substring
/// hit on the display name or the path (worktree / directory).
bool _matchesQuery(String name, String path, String query) {
  if (query.isEmpty) return true;
  final q = query.toLowerCase();
  return name.toLowerCase().contains(q) || path.toLowerCase().contains(q);
}

List<_ProjItem> _buildItems(BuildContext context, String query) {
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
        if (!_matchesQuery(name, dir, query)) continue;
        // Sort key: latest `time.updated` among the directory's unarchived
        // sessions; falls back to the activity watermark (includes archived)
        // only when no unarchived sessions remain.
        final last = serverStore.globalDirOrderKey(dir);
        items.add(_ProjItem(
          name: name,
          subtitle: dir.isEmpty ? 'global' : dir,
          states: _statesFor(
            entry.value,
            mainWorktree: dir,
            worktreeOrder: const {},
          ),
          lastActivity: last,
          onTap: () => context.push(
              '/project/global?directory=${Uri.encodeQueryComponent(dir)}'),
        ));
      }
      continue;
    }
    if (!_matchesQuery(p.displayName, p.canonical, query)) continue;
    final sess = serverStore.sessions.where((s) => s.projectID == p.id);
    final worktreeDirs = serverStore.worktreeDirsOf(p.id);
    // See note above: unarchived `time.updated` max, watermark fallback.
    final last = serverStore.projectOrderKey(p.id);
    items.add(_ProjItem(
      name: p.displayName,
      subtitle: p.canonical,
      icon: p.icon,
      states: _statesFor(
        sess,
        mainWorktree: p.canonical,
        worktreeOrder: {
          for (var i = 0; i < worktreeDirs.length; i++) worktreeDirs[i]: i,
        },
      ),
      lastActivity: last,
      onTap: () => context.push('/project/${p.id}'),
    ));
  }
  items.sort((a, b) => b.lastActivity.compareTo(a.lastActivity));
  return items;
}

/// Ordered per-session agent states for [sessions], ordered the same way the
/// project detail screen is (see [groupSessionsByWorktree]) so the <=4 glyph
/// row matches the detail list top→bottom.
List<AgentIndicatorState> _statesFor(
  Iterable<SessionModel> sessions, {
  required String mainWorktree,
  required Map<String, int> worktreeOrder,
}) {
  final groups = groupSessionsByWorktree(
    sessions,
    mainWorktree: mainWorktree,
    worktreeOrder: worktreeOrder,
  );
  return [
    for (final g in groups)
      for (final s in g.sessions) serverStore.agentIndicatorStateOf(s.id),
  ];
}

// Status display order for the collapsed (>4 sessions) summary:
// 空闲 > 运行中 > 暂停 > 重试 > 失败.
const _statusOrder = <AgentRunState>[
  AgentRunState.idle,
  AgentRunState.working,
  AgentRunState.paused,
  AgentRunState.retrying,
  AgentRunState.failed,
];

/// Renders a project's session-status summary in place of the old session
/// count. With at most 4 unarchived sessions it shows one icon-only glyph per
/// session (in list order); beyond that it collapses into a count-per-status
/// badge row (icon + count only, statuses with zero sessions omitted).
class _SessionStatusSummary extends StatelessWidget {
  final List<AgentIndicatorState> states;
  const _SessionStatusSummary({required this.states});

  @override
  Widget build(BuildContext context) {
    if (states.isEmpty) return const SizedBox.shrink();
    if (states.length <= 4) {
      return Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final s in states) AgentStatusGlyph(state: s),
        ],
      );
    }
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: _statusCountChips(states),
    );
  }
}

/// Count-per-status badges ordered by [_statusOrder], skipping any status with
/// no sessions. Paused sessions needing permission take precedence over those
/// needing a choice when picking the representative icon.
List<Widget> _statusCountChips(List<AgentIndicatorState> states) {
  final count = <AgentRunState, int>{};
  var pausedPermission = false;
  for (final s in states) {
    count[s.state] = (count[s.state] ?? 0) + 1;
    if (s.state == AgentRunState.paused &&
        s.pauseReason == AgentPauseReason.permission) {
      pausedPermission = true;
    }
  }
  return [
    for (final st in _statusOrder)
      if (count[st] != null)
        AgentStatusCountChip(
          state: st == AgentRunState.paused
              ? AgentIndicatorState(AgentRunState.paused,
                  pauseReason: pausedPermission
                      ? AgentPauseReason.permission
                      : AgentPauseReason.choice)
              : AgentIndicatorState(st),
          count: count[st]!,
        ),
  ];
}
