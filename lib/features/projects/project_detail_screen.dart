import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../app_state.dart';
import '../../core/logging/app_logger.dart';
import '../../domain/models.dart';
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
                  label: const Text('新建会话'),
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
    final workspaces =
        project.sandboxes.isNotEmpty ? project.sandboxes : [project.worktree];
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
              ...workspaces.map(
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
      unawaited(_applyDefaultAgentModel(session.id, directory));
      if (context.mounted) context.push('/session/${session.id}');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('创建失败：$e')));
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
    var deleting = false;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => PopScope(
          canPop: !deleting,
          child: AlertDialog(
            title: const Text('删除工作区'),
            content: Text('确定删除工作区「$wtName」？\n该工作区下的会话将一并移除。'),
            actions: [
              TextButton(
                onPressed: deleting ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(ctx).colorScheme.error,
                ),
                onPressed: deleting
                    ? null
                    : () async {
                        final client = serverStore.client;
                        if (client == null) {
                          if (ctx.mounted) Navigator.pop(ctx);
                          return;
                        }
                        setState(() => deleting = true);
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
                            ).showSnackBar(
                              SnackBar(content: Text('已删除工作区「$wtName」')),
                            );
                          }
                        } catch (e) {
                          if (ctx.mounted) {
                            setState(() => deleting = false);
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(
                              SnackBar(content: Text('删除失败：$e')),
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
                    : const Text('删除'),
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

  /// Section sessions by worktree (directory). Section headers are shown only
  /// when the project spans more than one worktree, so single-worktree
  /// projects keep a flat list. Ordering (main worktree first, then sandboxes,
  /// recency within a group) comes from [groupSessionsByWorktree] so it matches
  /// the project list tab.
  List<Widget> _groupedByWorktree(
    BuildContext context,
    List<SessionModel> all,
    String projectWorktree,
    List<String> sandboxes,
  ) {
    final groups = groupSessionsByWorktree(
      all,
      mainWorktree: projectWorktree,
      sandboxOrder: {
        for (var i = 0; i < sandboxes.length; i++) sandboxes[i]: i,
      },
    );
    final multi = groups.length > 1;
    final out = <Widget>[];
    for (final g in groups) {
      if (multi) {
        final name =
            g.directory.isEmpty ? 'global' : g.directory.split('/').last;
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
                      label: '$sessionCount 个会话',
                    ),
                    if (workspaceEnabled)
                      const _StatChip(
                        icon: Icons.call_split,
                        label: '工作区已开启',
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
                        '编辑项目',
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
                        workspaceEnabled ? '关闭工作区' : '开启工作区',
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
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurface),
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
        SnackBar(content: Text('选择 emoji 失败：$e')),
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
        SnackBar(content: Text('选择图片失败：$e')),
      );
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('项目名称不能为空')),
      );
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
          SnackBar(content: Text('保存失败：$e')),
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
            '编辑项目',
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
                            onTap: _emojiBusy
                                ? null
                                : () => _pickEmoji(asset),
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
                          label: const Text('选择图片'),
                        ),
                        if (_override != null)
                          TextButton.icon(
                            onPressed: () => setState(() {
                              _override = null;
                              _selectedEmoji = null;
                            }),
                            icon: const Icon(Icons.restart_alt, size: 18),
                            label: const Text('移除图片'),
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
            decoration: const InputDecoration(
              labelText: '项目名称',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.label_outline),
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
                child: const Text('取消'),
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
                label: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
