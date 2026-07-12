import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/session/conversation_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ConversationScreen extends StatefulWidget {
  final String sessionId;
  const ConversationScreen({super.key, required this.sessionId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _scrollController = ScrollController();
  bool _didInitialScroll = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = serverStore.sessionById(widget.sessionId);
    final conv = serverStore.conversationFor(widget.sessionId);
    if (conv == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('会话不可用（未连接服务器）')),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(session?.title ?? '会话',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 16)),
            if (session != null)
              Text(
                '${serverStore.projectDisplayOf(session)} › ${serverStore.worktreeDisplayOf(session)}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mono.copyWith(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.outline),
              ),
          ],
        ),
        actions: [
          _StatusPill(listenable: conv),
          const SizedBox(width: 12),
        ],
      ),
      body: ListenableBuilder(
        listenable: conv,
        builder: (context, _) {
          if (conv.loading && !conv.loaded) {
            return const Center(child: CircularProgressIndicator());
          }
          if (conv.error != null && conv.messages.isEmpty) {
            return Center(child: Text('加载失败：${conv.error}'));
          }
          final list = ListView(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              if (conv.todos.isNotEmpty) _TodoCard(todos: conv.todos),
              ...conv.permissions.map((p) => _PermissionCard(
                    permission: p,
                    store: conv,
                  )),
              ...conv.messages.map(_message),
              if (conv.busy) const _TypingDots(),
              const SizedBox(height: 8),
            ],
          );
          _scheduleAutoScroll();
          return list;
        },
      ),
    );
  }

  Widget _message(DisplayMessage m) {
    if (m.info.role == 'user') {
      return Padding(
        padding: const EdgeInsets.only(left: 40, top: 10, bottom: 10),
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _userBubbleColor(),
              borderRadius: BorderRadius.circular(14),
            ),
            constraints: const BoxConstraints(maxWidth: 320),
            child: _parts(m.parts, user: true),
          ),
      ),
    );
  }
    return Padding(
      padding: const EdgeInsets.only(right: 24, top: 10, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _parts(m.parts, user: false),
        ],
      ),
    );
  }

  void _scheduleAutoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      final atBottom = pos.pixels >= pos.maxScrollExtent - 50;
      if (!_didInitialScroll) {
        _didInitialScroll = true;
        _scrollController.jumpTo(pos.maxScrollExtent);
      } else if (atBottom) {
        _scrollController.jumpTo(pos.maxScrollExtent);
      }
    });
  }

  Color _userBubbleColor() => const Color(0xFF1F3D2A);

  Widget _parts(List<DisplayPart> parts, {required bool user}) {
    final children = <Widget>[];
    for (final p in parts) {
      children.add(_part(p, user: user));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  Widget _part(DisplayPart p, {required bool user}) {
    switch (p.type) {
      case 'text':
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: SelectableText(
            p.text,
            style: TextStyle(
              fontSize: 14,
              height: 1.45,
              color: user ? const Color(0xFFD8F3E0) : null,
            ),
          ),
        );
      case 'reasoning':
        return _Reasoning(text: p.text);
      case 'tool':
        return _ToolChip(part: p);
      case 'file':
        return _FileChip(part: p);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _StatusPill extends StatelessWidget {
  final ConversationStore listenable;
  const _StatusPill({required this.listenable});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: listenable,
      builder: (context, _) {
        final s = listenable.status;
        final label = s == 'busy' ? '运行中' : s == 'retry' ? '重试' : '空闲';
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(type: s),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
          ],
        );
      },
    );
  }
}

class _TodoCard extends StatelessWidget {
  final List<Todo> todos;
  const _TodoCard({required this.todos});

  @override
  Widget build(BuildContext context) {
    final done = todos.where((t) => t.done).length;
    final pct = todos.isEmpty ? 0.0 : done / todos.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.checklist, size: 16),
            const SizedBox(width: 6),
            const Text('任务',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            const Spacer(),
            Text('$done/${todos.length}',
                style: TextStyle(
                    fontSize: 12, color: Theme.of(context).colorScheme.outline)),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 5,
              backgroundColor: const Color(0xFF23272E),
              valueColor: AlwaysStoppedAnimation(
                  Theme.of(context).colorScheme.primary),
            ),
          ),
          const SizedBox(height: 12),
          ...todos.map(_todoRow),
        ],
      ),
    );
  }

  Widget _todoRow(Todo t) {
    final icon = t.done
        ? Icons.check_box
        : t.active
            ? Icons.indeterminate_check_box
            : Icons.check_box_outline_blank;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(t.content,
                style: TextStyle(
                    fontSize: 12.5,
                    decoration:
                        t.done ? TextDecoration.lineThrough : TextDecoration.none,
                    color: t.done ? const Color(0xFF8B949E) : null)),
          ),
        ],
      ),
    );
  }
}

class _Reasoning extends StatefulWidget {
  final String text;
  const _Reasoning({required this.text});

  @override
  State<_Reasoning> createState() => _ReasoningState();
}

class _ReasoningState extends State<_Reasoning> {
  bool expanded = false;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: InkWell(
        onTap: () => setState(() => expanded = !expanded),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.psychology_outlined, size: 14, color: muted),
                const SizedBox(width: 6),
                Text(expanded ? '收起思考' : '展开思考',
                    style: TextStyle(fontSize: 11.5, color: muted)),
              ]),
              if (expanded) ...[
                const SizedBox(height: 6),
                Text(widget.text,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: muted,
                        fontStyle: FontStyle.italic,
                        height: 1.45)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ToolChip extends StatelessWidget {
  final DisplayPart part;
  const _ToolChip({required this.part});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (part.toolStatus) {
      'completed' => (Icons.check_circle, const Color(0xFF3FB950)),
      'running' => (Icons.play_arrow, const Color(0xFF4ADE80)),
      'error' => (Icons.error, const Color(0xFFF85149)),
      _ => (Icons.hourglass_top, const Color(0xFF8B949E)),
    };
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(part.tool ?? 'tool',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  final DisplayPart part;
  const _FileChip({required this.part});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.attach_file,
              size: 14, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 4),
          Text(part.tool ?? part.text,
              style: AppTheme.mono.copyWith(fontSize: 12)),
        ],
      ),
    );
  }
}

class _PermissionCard extends StatelessWidget {
  final Permission permission;
  final ConversationStore store;
  const _PermissionCard({required this.permission, required this.store});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withAlpha(120),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: Theme.of(context).colorScheme.primary.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.shield_outlined,
                size: 16, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
            const Text('权限请求',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 8),
          Text(permission.title,
              style: AppTheme.mono.copyWith(fontSize: 12.5)),
          const SizedBox(height: 12),
          Row(children: [
            FilledButton(
              onPressed: () => store.respondPermission(permission, 'allow'),
              child: const Text('允许'),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                  foregroundColor: Colors.red,
                  backgroundColor: Colors.red.withAlpha(25)),
              onPressed: () => store.respondPermission(permission, 'deny'),
              child: const Text('拒绝'),
            ),
          ]),
        ],
      ),
    );
  }
}

class _TypingDots extends StatelessWidget {
  const _TypingDots();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        children: List.generate(
          3,
          (i) => Padding(
            padding: const EdgeInsets.only(right: 4),
            child: _Dot(delay: i * 300),
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatefulWidget {
  final int delay;
  const _Dot({required this.delay});

  @override
  State<_Dot> createState() => _DotState();
}

class _DotState extends State<_Dot> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _c.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) {
        final a = 0.3 + 0.7 * _c.value;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary.withAlpha((255 * a).round()),
            shape: BoxShape.circle,
          ),
        );
      },
    );
  }
}