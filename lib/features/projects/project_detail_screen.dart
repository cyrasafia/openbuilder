import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_state.dart';
import '../../core/logging/app_logger.dart';
import '../../core/net/net_error.dart';
import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'emoji_icons.dart';
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
        final loc = l(context);
        if (project == null && directory == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(child: Text(loc.projectNotFound)),
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
        final p = project;
        final wsCapable = p?.workspaceCapable ?? false;
        final wsEnabled = wsCapable && serverStore.workspaceEnabled(p!.id);
        final canEdit = p != null && p.id != 'global';
        final isGlobal = project?.id == 'global';
        final showCreateSession =
            project != null && (!isGlobal || directory != null);

        return Scaffold(
          body: Column(
            children: [
              _ProjectCard(
                name: scopedTitle,
                icon: project?.icon,
                worktree: scopedWorktree,
                sessionCount: sessions.length,
                workspaceCapable: wsCapable,
                workspaceEnabled: wsEnabled,
                canEdit: canEdit,
                onBack: () => Navigator.maybeOf(context)?.maybePop(),
                onToggleWorkspace: wsCapable
                    ? () => serverStore.setWorkspaceEnabled(
                        p!.id,
                        !serverStore.workspaceEnabled(p.id),
                      )
                    : null,
                onEdit: canEdit ? () => _showEditProject(context, p) : null,
              ),
              Expanded(
                child: MediaQuery.removePadding(
                  context: context,
                  removeTop: true,
                  child: ListView(
                    children: [
                      if (sessions.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Text(loc.projectNoActiveSessions),
                          ),
                        )
                      else if (project?.id == 'global' && directory == null)
                        ..._groupedGlobal(context, sessions)
                      else
                        ..._groupedByWorktree(
                          context,
                          sessions,
                          scopedWorktree,
                          project?.sandboxes ?? const [],
                          alwaysShowHeaders: wsEnabled && directory == null,
                        ),
                      const SizedBox(height: 88),
                    ],
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: showCreateSession
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.add_comment_outlined),
                  label: Text(loc.projectNewSession),
                  onPressed: () {
                    if (isGlobal) {
                      _createSession(context, directory!);
                    } else {
                      _startCreateSession(context, project);
                    }
                  },
                )
              : null,
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
    final workspaces = project.sandboxes.isNotEmpty
        ? project.sandboxes
        : [project.worktree];
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
                title: Text(l(ctx).projectSelectWorkspace),
                titleTextStyle: Theme.of(
                  ctx,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              ...workspaces.map(
                (dir) => ListTile(
                  leading: const Icon(Icons.call_split),
                  title: Text(
                    dir == project.worktree
                        ? l(ctx).projectMainWorkspace
                        : dir.split('/').last,
                  ),
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
                title: Text(l(ctx).projectNewWorkspace),
                onTap: () => Navigator.pop(ctx, ''),
              ),
            ],
          ),
        ),
      ),
    );
    if (!context.mounted || directory == null) return;
    if (directory.isEmpty) {
      _confirmCreateWorktreeSession(context, project);
      return;
    }
    await _createSession(context, directory);
  }

  Future<void> _createSession(BuildContext context, String directory) async {
    try {
      final session = await serverStore.createSession(directory);
      unawaited(_applyDefaultAgentModel(session.id, directory));
      if (context.mounted) context.push('/session/${session.id}');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).createFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    }
  }

  Future<void> _applyDefaultAgentModel(
    String sessionId,
    String directory,
  ) async {
    final client = serverStore.client;
    if (client == null) return;
    bool switched = false;
    try {
      final results = await Future.wait([
        client.listAgents(directory: directory),
        client.listConfigProviders(directory: directory),
      ]);
      final agents = results[0] as List<AgentInfo>;
      final models = results[1] as List<ModelInfo>;
      final session = serverStore.sessionById(sessionId);
      if (agents.isNotEmpty && session?.agent != agents.first.name) {
        await client.switchAgent(sessionId, agents.first.name);
        switched = true;
      }
      if (models.isEmpty) {
        if (switched) unawaited(serverStore.refresh());
        return;
      }
      final saved = defaultAgentModelStore.getDefaultModel(
        connectionStore.activeId,
      );
      ModelRef targetModel;
      if (saved != null) {
        final match = models.where(
          (m) => m.id == saved.id && m.providerID == saved.providerID,
        );
        if (match.isNotEmpty) {
          targetModel = saved;
        } else {
          targetModel = ModelRef(
            id: models.first.id,
            providerID: models.first.providerID,
          );
        }
      } else {
        targetModel = ModelRef(
          id: models.first.id,
          providerID: models.first.providerID,
        );
      }
      if (session?.model?.id != targetModel.id ||
          session?.model?.providerID != targetModel.providerID) {
        await client.switchModel(sessionId, targetModel);
        switched = true;
      }
      if (switched) unawaited(serverStore.refresh());
    } catch (e) {
      AppLogger.I.e('ApplyDefaultAgentModel', e.toString());
    }
  }

  void _confirmCreateWorktreeSession(BuildContext context, ProjectModel project) {
    var creating = false;
    var worktreeStepFailed = false;
    String? pendingWorktreeDir;
    String? errorText;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => PopScope(
          canPop: !creating,
          child: AlertDialog(
            title: Text(l(ctx).projectNewWorkspace),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  pendingWorktreeDir == null
                      ? l(ctx).projectNewWorkspaceConfirm
                      : l(ctx).projectWorkspaceCreatedRetry,
                ),
                if (errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    errorText!,
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: creating ? null : () => Navigator.pop(ctx),
                child: Text(l(ctx).cancel),
              ),
              FilledButton(
                onPressed: creating
                    ? null
                    : () async {
                        setState(() {
                          creating = true;
                          errorText = null;
                        });
                        try {
                          final pending = pendingWorktreeDir;
                          final session = pending == null
                              ? await serverStore.createSessionInNewWorktree(
                                  project.worktree,
                                  reconcileFirst: worktreeStepFailed,
                                )
                              : await serverStore.createSession(pending);
                          unawaited(serverStore.refresh());
                          unawaited(
                            _applyDefaultAgentModel(
                              session.id,
                              session.directory,
                            ),
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            context.push('/session/${session.id}');
                          }
                        } catch (e) {
                          if (e is SessionInWorktreeException) {
                            pendingWorktreeDir = e.worktreeDirectory;
                          } else {
                            final kind = friendlyErrorRaw(e);
                            worktreeStepFailed =
                                kind == FriendlyErrorKind.timeout ||
                                kind == FriendlyErrorKind.connect;
                          }
                          if (ctx.mounted) {
                            setState(() {
                              creating = false;
                              errorText = l(ctx).createFailed(
                                friendlyMessage(l(ctx), e),
                              );
                            });
                          }
                        }
                      },
                child: creating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l(ctx).create),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _confirmRemoveWorktree(
    BuildContext context,
    String projectWorktree,
    String worktreeDir,
  ) {
    final wtName = worktreeDir.split('/').last;
    var deleting = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => PopScope(
          canPop: !deleting,
          child: AlertDialog(
            title: Text(l(ctx).projectDeleteWorkspace),
            content: Text(l(ctx).projectDeleteWorkspaceConfirm(wtName)),
            actions: [
              TextButton(
                onPressed: deleting ? null : () => Navigator.pop(ctx),
                child: Text(l(ctx).cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: deleting
                    ? null
                    : () async {
                        setState(() => deleting = true);
                        try {
                          await serverStore.removeWorktree(
                            projectWorktree,
                            worktreeDir: worktreeDir,
                          );
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l(context).projectWorktreeDeleted(wtName),
                                ),
                              ),
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setState(() => deleting = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  l(context).deleteFailed(
                                    friendlyMessage(l(context), e),
                                  ),
                                ),
                              ),
                            );
                          }
                        }
                      },
                child: deleting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(l(ctx).delete),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditProject(BuildContext context, ProjectModel project) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _ProjectEditSheet(project: project),
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

  /// Section sessions by worktree (directory). Section headers are shown when
  /// the project spans more than one worktree, or when [alwaysShowHeaders] is
  /// true (e.g. a workspace-enabled project viewed at the project level, so
  /// the "主工作区" header still surfaces even with a single populated
  /// worktree). Single-worktree projects with headers suppressed keep a flat
  /// list. Ordering (main worktree first, then sandboxes, recency within a
  /// group) comes from [groupSessionsByWorktree] so it matches the project
  /// list tab.
  List<Widget> _groupedByWorktree(
    BuildContext context,
    List<SessionModel> all,
    String projectWorktree,
    List<String> sandboxes, {
    bool alwaysShowHeaders = false,
  }) {
    final groups = groupSessionsByWorktree(
      all,
      mainWorktree: projectWorktree,
      sandboxOrder: {
        for (var i = 0; i < sandboxes.length; i++) sandboxes[i]: i,
      },
    );
    final showHeaders = groups.length > 1 || alwaysShowHeaders;
    final out = <Widget>[];
    for (final g in groups) {
      if (showHeaders) {
        final name = g.directory == projectWorktree
            ? l(context).projectMainWorkspace
            : (g.directory.isEmpty ? 'global' : g.directory.split('/').last);
        // Only non-main worktrees (sandboxes) can be removed.
        final canDelete =
            g.directory.isNotEmpty && g.directory != projectWorktree;
        out.add(
          _SectionHeader(
            name: name,
            count: g.sessions.length,
            onDelete: canDelete
                ? () => _confirmRemoveWorktree(
                    context,
                    projectWorktree,
                    g.directory,
                  )
                : null,
          ),
        );
      }
      out.addAll(
        g.sessions.map(
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

class _ProjectCard extends StatelessWidget {
  final String name;
  final ProjectIcon? icon;
  final String worktree;
  final int sessionCount;
  final bool workspaceCapable;
  final bool workspaceEnabled;
  final bool canEdit;
  final VoidCallback onBack;
  final VoidCallback? onToggleWorkspace;
  final VoidCallback? onEdit;

  const _ProjectCard({
    required this.name,
    required this.icon,
    required this.worktree,
    required this.sessionCount,
    required this.workspaceCapable,
    required this.workspaceEnabled,
    required this.canEdit,
    required this.onBack,
    this.onToggleWorkspace,
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.outline;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(
          bottom: BorderSide(color: scheme.outlineVariant.withAlpha(90)),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _topBar(context),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ProjectAvatar(name: name, icon: icon, size: 56),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            worktree,
                            style: AppTheme.mono.copyWith(
                              fontSize: 12,
                              color: muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _StatChip(
                      icon: Icons.chat_bubble_outline,
                      label: l(context).projectSessionCount(sessionCount),
                    ),
                    if (workspaceEnabled)
                      _StatChip(
                        icon: Icons.call_split,
                        label: l(context).projectWorkspaceOn,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _topBar(BuildContext context) {
    final hasMenu = onToggleWorkspace != null || onEdit != null;
    final scheme = Theme.of(context).colorScheme;
    final loc = l(context);
    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          onPressed: onBack,
        ),
        const Spacer(),
        if (hasMenu)
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'edit':
                  onEdit?.call();
                case 'toggle_workspace':
                  onToggleWorkspace?.call();
              }
            },
            itemBuilder: (_) => [
              if (onEdit != null)
                PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      const Icon(Icons.edit_outlined, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        loc.projectEdit,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              if (onToggleWorkspace != null)
                PopupMenuItem(
                  value: 'toggle_workspace',
                  child: Row(
                    children: [
                      const Icon(Icons.workspaces_outline, size: 20),
                      const SizedBox(width: 12),
                      Text(
                        workspaceEnabled
                            ? loc.projectCloseWorkspace
                            : loc.projectOpenWorkspace,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StatChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: scheme.outline),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
        ],
      ),
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

/// Bottom sheet for editing a project's name and icon (emoji / image override).
class _ProjectEditSheet extends StatefulWidget {
  final ProjectModel project;
  const _ProjectEditSheet({required this.project});

  @override
  State<_ProjectEditSheet> createState() => _ProjectEditSheetState();
}

class _ProjectEditSheetState extends State<_ProjectEditSheet> {
  late final TextEditingController _nameCtrl;
  late final List<String> _emojiChoices;
  String? _override;
  String? _selectedEmoji;
  bool _emojiBusy = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.project.displayName);
    _override = widget.project.icon?.override;
    _emojiChoices = pickRandomEmojiAssets(5);
    _resolveSelectedEmoji();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _resolveSelectedEmoji() async {
    final current = _override;
    if (current == null || current.isEmpty) return;
    try {
      for (final asset in _emojiChoices) {
        final dataUrl = await emojiAssetToDataUrl(asset);
        if (!mounted || _override != current) return;
        if (dataUrl == current) {
          setState(() => _selectedEmoji = asset);
          return;
        }
      }
    } catch (_) {
      // Best-effort highlight; ignore asset load failures.
    }
  }

  ProjectIcon get _previewIcon => ProjectIcon(
    url: widget.project.icon?.url,
    override: _override,
    color: widget.project.icon?.color,
  );

  Future<void> _pickEmoji(String assetPath) async {
    if (_emojiBusy || _selectedEmoji == assetPath) return;
    setState(() => _emojiBusy = true);
    try {
      final dataUrl = await emojiAssetToDataUrl(assetPath);
      if (!mounted) return;
      setState(() {
        _override = dataUrl;
        _selectedEmoji = assetPath;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l(context).projectEmojiPickFailed(e.toString())),
        ),
      );
    } finally {
      if (mounted) setState(() => _emojiBusy = false);
    }
  }

  Future<void> _pickImage() async {
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final mime = x.mimeType ?? 'image/png';
      if (!mounted) return;
      setState(() {
        _override = 'data:$mime;base64,${base64Encode(bytes)}';
        _selectedEmoji = null;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l(context).projectImagePickFailed(e.toString())),
        ),
      );
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l(context).projectNameEmpty)));
      return;
    }
    setState(() => _saving = true);
    final original = widget.project;
    final iconChanged = _override != original.icon?.override;
    final nameChanged = name != original.displayName;

    try {
      await serverStore.updateProject(
        original.id,
        name: nameChanged ? name : null,
        updateIcon: iconChanged,
        iconUrl: original.icon?.url,
        iconOverride: _override ?? '',
        iconColor: '',
      );
      if (mounted) Navigator.of(context).maybePop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l(context).saveFailed(friendlyMessage(l(context), e)),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l(context).projectEdit,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProjectAvatar(
                name: _nameCtrl.text.isEmpty
                    ? widget.project.displayName
                    : _nameCtrl.text,
                icon: _previewIcon,
                size: 56,
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final asset in _emojiChoices)
                          GestureDetector(
                            onTap: _emojiBusy ? null : () => _pickEmoji(asset),
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: _selectedEmoji == asset
                                    ? Border.all(
                                        color: scheme.onSurface,
                                        width: 2.5,
                                      )
                                    : null,
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.asset(
                                  asset,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        TextButton.icon(
                          onPressed: _pickImage,
                          icon: const Icon(Icons.image_outlined, size: 18),
                          label: Text(l(context).projectPickImage),
                        ),
                        if (_override != null)
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _override = null;
                              _selectedEmoji = null;
                            }),
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: Text(l(context).projectRemoveImage),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: InputDecoration(
              labelText: l(context).projectNameLabel,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.label_outline),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving
                    ? null
                    : () => Navigator.of(context).maybePop(),
                child: Text(l(context).cancel),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check),
                label: Text(l(context).save),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
