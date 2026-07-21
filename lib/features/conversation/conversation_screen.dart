import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:cross_file/cross_file.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../core/attachments/attachment_pipeline.dart';
import '../../core/session/conversation_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

class ConversationScreen extends StatefulWidget {
  final String sessionId;
  const ConversationScreen({super.key, required this.sessionId});

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _scrollController = ScrollController();
  final _ctl = TextEditingController();
  bool _cmdMode = false;
  final List<AttachmentPreview> _attachments = [];
  List<CommandInfo> _commands = const [];
  bool _cmdLoaded = false;
  bool _cmdLoading = false;
  String? _cmdError;
  bool _didForceReload = false;
  int _lastMsgCount = 0;
  static const _kScrollThreshold = 200.0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    serverStore.setActiveConversation(null);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _ctl.dispose();
    super.dispose();
  }

  /// Reversed ListView: visual top = maxScrollExtent. When near the top,
  /// trigger lazy backward pagination.
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - _kScrollThreshold) {
      _maybeLoadEarlier();
    }
  }

  void _maybeLoadEarlier() {
    final conv = serverStore.conversationForRead(widget.sessionId);
    if (conv == null) return;
    if (!conv.hasMore || conv.loadingEarlier) return;
    conv.loadOnePage().then((madeProgress) {
      // IR-1: stop the chain on failure (no progress) to prevent request
      // storms when offline. The user can retry by scrolling away and back.
      if (!mounted || !madeProgress) return;
      // Chain: if the viewport isn't filled yet (still at top), keep loading.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final pos = _scrollController.position;
        final c = serverStore.conversationForRead(widget.sessionId);
        if (c == null || !c.hasMore || c.loadingEarlier) return;
        if (pos.pixels >= pos.maxScrollExtent - _kScrollThreshold) {
          _maybeLoadEarlier();
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    serverStore.setActiveConversation(widget.sessionId);
    if (!_didForceReload) {
      _didForceReload = true;
      serverStore.conversationFor(widget.sessionId, force: true);
    }
    final session = serverStore.sessionById(widget.sessionId);
    final conv = serverStore.conversationFor(widget.sessionId);
    if (conv == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('会话不可用（未连接服务器）')),
      );
    }
    final directory = session?.directory ?? '';
    return Scaffold(
      appBar: AppBar(
        title: ListenableBuilder(
          listenable: serverStore,
          builder: (context, _) {
            final s = serverStore.sessionById(widget.sessionId);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(s?.title ?? '会话',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16)),
                if (s != null)
                  Text(
                    '${serverStore.projectDisplayOf(s)} › ${serverStore.worktreeDisplayOf(s)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.mono.copyWith(
                        fontSize: 11,
                        color: Theme.of(context).colorScheme.outline),
                  ),
              ],
            );
          },
        ),
        actions: [
          ListenableBuilder(
            listenable: serverStore,
            builder: (context, _) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: SseStatusDot(
                connected: serverStore.sseConnected,
                reconnecting: serverStore.sseReconnecting,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.folder_outlined),
            tooltip: '文件',
            onPressed: () => context.push(
              '/session/${widget.sessionId}/files'
              '?directory=${Uri.encodeQueryComponent(directory)}',
            ),
          ),
          IconButton(
            icon: const Icon(Icons.compare),
            tooltip: 'Diff',
            onPressed: () => context.push(
              '/session/${widget.sessionId}/diff'
              '?directory=${Uri.encodeQueryComponent(directory)}',
            ),
          ),
          _MoreMenu(
            sessionId: widget.sessionId,
            directory: directory,
            session: session,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: conv,
        builder: (context, _) {
          if (conv.loading && !conv.loaded && conv.messages.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (!conv.loading && conv.error != null && conv.messages.isEmpty) {
            return Center(child: Text('加载失败：${conv.error}'));
          }
          // Reversed ListView pins to the newest message (bottom) on open,
          // so we enter directly at the latest part with no top→bottom flash.
          // Todos/permissions live in a separate footer pinned to the page
          // bottom (see _FooterPanel), out of the scrolling message stream.
          final list = ListView(
            reverse: true,
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            children: [
              const SizedBox(height: 8),
              if (conv.busy || conv.loading) const _TypingDots(),
              ...conv.renderableMessages.map(_message),
              if (conv.loadingEarlier)
                const _LoadingEarlierRow()
              else if (conv.loadEarlierError && conv.hasMore)
                _LoadEarlierErrorRow(onRetry: _maybeLoadEarlier),
            ],
          );
          final msgCount = conv.renderableMessages.length;
          if (msgCount != _lastMsgCount) {
            _lastMsgCount = msgCount;
            _scheduleAutoScroll();
          }
          final showFooter =
              conv.permissions.isNotEmpty ||
              conv.questions.isNotEmpty ||
              conv.todos.any((t) => !t.done);
          return Column(
            children: [
              if (conv.sessionError != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: _errorBanner(conv.sessionError!,
                      onDismiss: conv.clearSessionError),
                ),
              Expanded(child: list),
              if (showFooter)
                _FooterPanel(
                  todos: conv.todos,
                  permissions: conv.permissions,
                  questions: conv.questions,
                  store: conv,
                ),
              if (_cmdMode)
                _CommandHints(
                  query: _ctl.text,
                  commands: _commands,
                  loading: _cmdLoading,
                  error: _cmdError,
                  onPick: _pickCommand,
                ),
              _BottomBar(
                sessionId: widget.sessionId,
                directory: directory,
                ctl: _ctl,
                busy: conv.busy,
                onAbort: () => _abort(directory),
                onChanged: (t) {
                  final mode = t.startsWith('/') && !t.contains(' ');
                  if (mode && !_cmdLoaded && !_cmdLoading) {
                    _loadCommands();
                  }
                  setState(() => _cmdMode = mode);
                },
                onSend: _send,
                attachments: _attachments,
                onPickAttachments: _pickAttachments,
                onRemoveAttachment: _removeAttachment,
              ),
            ],
          );
        },
      ),
    );
  }

  void _pickCommand(String cmd) {
    _ctl.text = '$cmd ';
    _ctl.selection = TextSelection.fromPosition(
        TextPosition(offset: _ctl.text.length));
    setState(() => _cmdMode = false);
  }

  Future<void> _loadCommands() async {
    if (_cmdLoaded || _cmdLoading) return;
    final client = serverStore.client;
    if (client == null) return;
    final dir = serverStore.sessionById(widget.sessionId)?.directory;
    setState(() => _cmdLoading = true);
    try {
      final cmds = await client.getCommands(directory: dir);
      if (mounted) {
        setState(() {
          _commands = cmds;
          _cmdLoaded = true;
          _cmdLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cmdError = e.toString();
          _cmdLoaded = true;
          _cmdLoading = false;
        });
      }
    }
  }

  Future<void> _pickAttachments() async {
    List<XFile> picked;
    try {
      picked = await AttachmentPicker.pick(context);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选取失败：$e')));
      }
      return;
    }
    if (picked.isEmpty) return;
    // CR-6：并行 resolve（含压缩）；逐条收集错误
    final results = await Future.wait(picked.map((x) async {
      try {
        return (preview: await AttachmentPipeline.resolve(x), error: null);
      } on AttachmentTooLargeException catch (e) {
        return (preview: null, error: e);
      } catch (e) {
        return (preview: null, error: e);
      }
    }));
    final resolved = <AttachmentPreview>[];
    for (final r in results) {
      if (r.preview != null) {
        resolved.add(r.preview!);
      } else if (r.error is AttachmentTooLargeException) {
        final e = r.error! as AttachmentTooLargeException;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                  '「${e.name}」过大（${(e.len / 1048576).toStringAsFixed(1)}MB），未添加')));
        }
      } else if (r.error != null) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('读取失败：${r.error}')));
        }
      }
    }
    if (resolved.isNotEmpty) setState(() => _attachments.addAll(resolved));
  }

  void _removeAttachment(int i) => setState(() => _attachments.removeAt(i));

  Future<void> _send() async {
    final text = _ctl.text.trim();
    final startsShell = text.startsWith('!');
    if (startsShell && _attachments.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('shell 命令（!）忽略附件，请去掉 ! 后重发')));
      }
      return;
    }
    if (text.isEmpty && _attachments.isEmpty) return;
    final conv = serverStore.conversationFor(widget.sessionId);
    final client = serverStore.client;
    if (conv == null || client == null) return;
    serverStore.ensureSseForSession(widget.sessionId);
    final session = serverStore.sessionById(widget.sessionId);
    final directory = session?.directory;
    final attachments = List<AttachmentPreview>.from(_attachments);
    _ctl.clear();
    setState(() {
      _cmdMode = false;
      _attachments.clear();
    });
    try {
      if (startsShell) {
        final command = text.substring(1).trim();
        if (command.isNotEmpty) {
          await client.shell(widget.sessionId,
              directory: directory,
              agent: session?.agent,
              command: command);
          conv.setStatus('busy');
        }
      } else {
        final parts = <Map<String, dynamic>>[];
        if (text.isNotEmpty) parts.add({'type': 'text', 'text': text});
        for (final a in attachments) {
          parts.add({
            'type': 'file',
            'mime': a.mime,
            'url': a.dataUrl,
            'filename': a.filename,
          });
        }
        conv.addOptimisticUserMessage(text, attachments: attachments);
        serverStore.reflectPreviewFrom(widget.sessionId);
        final totalLen = parts.fold<int>(
            0, (s, p) => s + (p['url']?.toString().length ?? 0));
        await client.prompt(
          widget.sessionId,
          directory: directory,
          agent: session?.agent,
          parts: parts,
          sendTimeout: totalLen > 2 * 1024 * 1024
              ? const Duration(seconds: 120)
              : null,
        );
        conv.setStatus('busy');
      }
    } catch (e) {
      conv.removeOptimisticMessages();
      serverStore.reflectPreviewFrom(widget.sessionId);
      _ctl.text = text;
      setState(() {
        _cmdMode = startsShell;
        _attachments
          ..clear()
          ..addAll(attachments);
      });
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败：$e')));
      }
    }
    _scheduleAutoScroll();
  }

  Future<void> _abort(String directory) async {
    final client = serverStore.client;
    if (client == null) return;
    try {
      await client.abort(widget.sessionId, directory: directory);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('终止失败：$e')));
      }
      rethrow;
    }
  }

  Widget _message(DisplayMessage m) {
    if (m.info.role == 'user') {
      return Padding(
        key: ValueKey(m.info.id),
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
      key: ValueKey(m.info.id),
      padding: const EdgeInsets.only(right: 24, top: 10, bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _parts(m.parts, user: false),
          if (m.info.error != null) _errorBanner(m.info.error!),
        ],
      ),
    );
  }

  Widget _errorBanner(Map<String, dynamic> error, {VoidCallback? onDismiss}) {
    final name = (error['name'] ?? 'Error').toString();
    final data = error['data'];
    final message = data is Map
        ? (data['message'] ?? data.toString()).toString()
        : data?.toString() ?? '';
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF85149).withAlpha(15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFF85149).withAlpha(60)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, size: 16, color: Color(0xFFF85149)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message.isNotEmpty ? '$name: $message' : name,
              style: const TextStyle(fontSize: 13, color: Color(0xFFF85149)),
            ),
          ),
          if (onDismiss != null) ...[
            const SizedBox(width: 8),
            InkWell(
              onTap: onDismiss,
              child: const Icon(Icons.close, size: 16, color: Color(0xFFF85149)),
            ),
          ],
        ],
      ),
    );
  }

  void _scheduleAutoScroll() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      // Reversed list: the newest (bottom) is at offset 0.
      final atBottom = pos.pixels <= 50;
      if (atBottom) {
        _scrollController.jumpTo(pos.minScrollExtent);
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
        final baseColor =
            user ? const Color(0xFFD8F3E0) : Theme.of(context).colorScheme.onSurface;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // User bubble is always dark green — code blocks inside it must use
        // dark backgrounds regardless of theme, or light text on light bg
        // becomes unreadable.
        final codeBlockBg = user
            ? const Color(0xFF142A1E)
            : (isDark ? const Color(0xFF161B22) : const Color(0xFFF0F2F5));
        final codeBlockBorder = user
            ? const Color(0xFF2A4A38)
            : (isDark ? const Color(0xFF30363D) : const Color(0xFFDADDE3));
        final codeFg = (user || isDark)
            ? const Color(0xFFEC407A)
            : const Color(0xFFC2185B);
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: MarkdownBody(
            data: p.text,
            selectable: true,
            styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
              p: TextStyle(fontSize: 14, height: 1.45, color: baseColor),
              pPadding: const EdgeInsets.only(bottom: 6),
              strong: TextStyle(fontWeight: FontWeight.w600, color: baseColor),
              code: TextStyle(
                fontSize: 13,
                fontFamily: 'monospace',
                color: codeFg,
              ),
              codeblockDecoration: BoxDecoration(
                color: codeBlockBg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: codeBlockBorder),
              ),
              codeblockPadding: const EdgeInsets.all(12),
              listBullet: TextStyle(color: baseColor),
              blockquote: TextStyle(color: baseColor, fontStyle: FontStyle.italic),
              blockquoteDecoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: Theme.of(context).colorScheme.outline, width: 3),
                ),
              ),
              blockquotePadding: const EdgeInsets.only(left: 12),
            ),
          ),
        );
      case 'reasoning':
        return _Reasoning(text: p.text);
      case 'tool':
        return _ToolChip(part: p);
      case 'file':
        return _FileChip(part: p, user: user);
      default:
        return const SizedBox.shrink();
    }
  }
}

class _TodoCard extends StatelessWidget {
  final List<Todo> todos;
  final bool collapsed;
  final VoidCallback? onToggle;
  const _TodoCard(
      {required this.todos, this.collapsed = false, this.onToggle});

  @override
  Widget build(BuildContext context) {
    final done = todos.where((t) => t.done).length;
    final pct = todos.isEmpty ? 0.0 : done / todos.length;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Row(children: [
              const Icon(Icons.checklist, size: 16),
              const SizedBox(width: 6),
              const Text('任务',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('$done/${todos.length}',
                  style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.outline)),
              if (onToggle != null) ...[
                const SizedBox(width: 6),
                Icon(collapsed ? Icons.expand_more : Icons.expand_less,
                    size: 18, color: Theme.of(context).colorScheme.outline),
              ],
            ]),
          ),
          if (!collapsed) ...[
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
        ],
      ),
    );
  }

  Widget _todoRow(Todo t) {
    final icon = t.cancelled
        ? Icons.cancel
        : t.done
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

class _FooterPanel extends StatefulWidget {
  final List<Todo> todos;
  final List<Permission> permissions;
  final List<QuestionRequest> questions;
  final ConversationStore store;
  const _FooterPanel({
    required this.todos,
    required this.permissions,
    required this.questions,
    required this.store,
  });

  @override
  State<_FooterPanel> createState() => _FooterPanelState();
}

class _FooterPanelState extends State<_FooterPanel> {
  bool _todoExpanded = false;

  @override
  Widget build(BuildContext context) {
    final totalPending = widget.permissions.length + widget.questions.length;
    final children = <Widget>[];
    if (widget.permissions.isNotEmpty) {
      children.add(_PermissionCard(
        key: ValueKey(widget.permissions.first.id),
        permission: widget.permissions.first,
        store: widget.store,
        queueTotal: totalPending,
      ));
    } else if (widget.questions.isNotEmpty) {
      children.add(_QuestionCard(
        key: ValueKey(widget.questions.first.id),
        question: widget.questions.first,
        store: widget.store,
        queueTotal: totalPending,
      ));
    }
    if (widget.todos.isNotEmpty) {
      children.add(_TodoCard(
        todos: widget.todos,
        collapsed: !_todoExpanded,
        onToggle: () => setState(() => _todoExpanded = !_todoExpanded),
      ));
    }
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor),
        ),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.4,
      ),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: children),
        ),
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
    final summary = part.toolSummary;
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
          Flexible(
            child: Text(
              summary,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.mono.copyWith(
                  fontSize: 12, fontWeight: FontWeight.w400),
            ),
          ),
        ],
      ),
    );
  }
}

class _FileChip extends StatelessWidget {
  final DisplayPart part;
  final bool user;
  const _FileChip({required this.part, this.user = false});

  bool get _isHttpUrl {
    final url = part.fileUrl;
    if (url == null) return false;
    return url.startsWith('http://') || url.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    // CR-2：仅乐观侧有 96px previewThumb；接收侧不解码 data URL（避免内存膨胀/首帧掉帧）
    final thumb = part.previewThumb;
    if (thumb != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 6),
        child: GestureDetector(
          onTap: () => _showFullScreen(context),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(thumb,
                width: 120, height: 120, fit: BoxFit.cover),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.insert_drive_file,
              size: 16, color: Theme.of(context).colorScheme.outline),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              part.filename ?? part.fileUrl ?? '[附件]',
              style: AppTheme.mono.copyWith(fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (_isHttpUrl) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => _openUrl(context),
              child: Icon(Icons.open_in_new,
                  size: 14, color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ],
      ),
    );
  }

  // CR-5：launchUrl 失败提示 + try/catch
  Future<void> _openUrl(BuildContext context) async {
    final url = part.fileUrl;
    if (url == null) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri);
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开链接')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('无法打开链接：$e')));
      }
    }
  }

  // CR-2(c)：全屏解码 part.fileUrl 全尺寸（点击一次性，不缓存进 previewThumb）
  void _showFullScreen(BuildContext context) {
    final url = part.fileUrl;
    if (url == null) return;
    Uint8List? bytes;
    if (url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma < 0) return;
      try {
        bytes = base64Decode(url.substring(comma + 1));
      } catch (_) {
        return;
      }
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => GestureDetector(
        onTap: () => Navigator.pop(ctx),
        child: Scaffold(
          backgroundColor: Colors.black87,
          body: Center(
            child: bytes != null
                ? Image.memory(bytes, fit: BoxFit.contain)
                : Image.network(url, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }
}

class _AttachmentPreviewBar extends StatelessWidget {
  final List<AttachmentPreview> attachments;
  final ValueChanged<int> onRemove;
  const _AttachmentPreviewBar(
      {required this.attachments, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 60,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) {
          final a = attachments[i];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              a.isImage && a.previewThumb != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.memory(a.previewThumb!,
                          width: 48, height: 48, fit: BoxFit.cover),
                    )
                  : Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(Icons.insert_drive_file, size: 20),
                    ),
              Positioned(
                right: -2,
                top: -2,
                child: GestureDetector(
                  onTap: () => onRemove(i),
                  child: Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(2),
                    child: const Icon(Icons.close, size: 14),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PermissionCard extends StatefulWidget {
  final Permission permission;
  final ConversationStore store;
  final int queueTotal;
  const _PermissionCard({
    super.key,
    required this.permission,
    required this.store,
    this.queueTotal = 1,
  });

  @override
  State<_PermissionCard> createState() => _PermissionCardState();
}

class _PermissionCardState extends State<_PermissionCard> {
  bool _replying = false;

  Future<void> _respond(String response) async {
    setState(() => _replying = true);
    try {
      await widget.store.respondPermission(widget.permission, response);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回复失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

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
            if (widget.queueTotal > 1) ...[
              const Spacer(),
              Text('1/${widget.queueTotal} 待处理',
                  style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context).colorScheme.outline)),
            ],
          ]),
          const SizedBox(height: 8),
          Text(widget.permission.title,
              style: AppTheme.mono.copyWith(fontSize: 12.5)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                    foregroundColor: Colors.red,
                    backgroundColor: Colors.red.withAlpha(25)),
                onPressed: _replying ? null : () => _respond('reject'),
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: _replying ? null : () => _respond('always'),
                child: const Text('始终允许'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _replying ? null : () => _respond('once'),
                child: _replying
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('允许一次'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QuestionCard extends StatefulWidget {
  final QuestionRequest question;
  final ConversationStore store;
  final int queueTotal;
  const _QuestionCard({
    super.key,
    required this.question,
    required this.store,
    this.queueTotal = 1,
  });

  @override
  State<_QuestionCard> createState() => _QuestionCardState();
}

class _QuestionCardState extends State<_QuestionCard> {
  final Map<int, Set<String>> _selected = {};
  bool _replying = false;

  void _toggle(int qIdx, String label) {
    final q = widget.question.questions[qIdx];
    setState(() {
      final sel = _selected.putIfAbsent(qIdx, () => {});
      if (sel.contains(label)) {
        sel.remove(label);
      } else {
        if (!q.multiple) sel.clear();
        sel.add(label);
      }
    });
  }

  Future<void> _reply() async {
    final answers = <List<String>>[];
    for (var i = 0; i < widget.question.questions.length; i++) {
      answers.add((_selected[i] ?? const {}).toList());
    }
    setState(() => _replying = true);
    try {
      await widget.store.replyQuestion(widget.question, answers);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('回复失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  Future<void> _reject() async {
    setState(() => _replying = true);
    try {
      await widget.store.rejectQuestion(widget.question);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('拒绝失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _replying = false);
    }
  }

  /// At least one option selected for every question.
  bool get _canSubmit {
    for (var i = 0; i < widget.question.questions.length; i++) {
      if ((_selected[i] ?? const {}).isEmpty) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer.withAlpha(100),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.tertiary.withAlpha(120)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.queueTotal > 1) ...[
            Align(
              alignment: Alignment.centerRight,
              child: Text('1/${widget.queueTotal} 待处理',
                  style: TextStyle(fontSize: 11.5, color: scheme.outline)),
            ),
            const SizedBox(height: 4),
          ],
          for (var i = 0; i < widget.question.questions.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            _questionBlock(i),
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                    foregroundColor: Colors.red,
                    backgroundColor: Colors.red.withAlpha(25)),
                onPressed: _replying ? null : _reject,
                child: const Text('拒绝'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _replying || !_canSubmit ? null : _reply,
                child: _replying
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('提交'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _questionBlock(int qIdx) {
    final q = widget.question.questions[qIdx];
    final sel = _selected[qIdx] ?? const <String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          Icon(Icons.help_outline,
              size: 16, color: Theme.of(context).colorScheme.tertiary),
          const SizedBox(width: 6),
          Text(q.header,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: 6),
        Text(q.question, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
        const SizedBox(height: 8),
        for (final opt in q.options)
          InkWell(
            onTap: _replying ? null : () => _toggle(qIdx, opt.label),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: sel.contains(opt.label)
                    ? Theme.of(context).colorScheme.tertiary.withAlpha(60)
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: sel.contains(opt.label)
                      ? Theme.of(context).colorScheme.tertiary
                      : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    sel.contains(opt.label)
                        ? (q.multiple ? Icons.check_box : Icons.radio_button_checked)
                        : (q.multiple ? Icons.check_box_outline_blank : Icons.radio_button_unchecked),
                    size: 18,
                    color: Theme.of(context).colorScheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(opt.label,
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w400)),
                        if (opt.description.isNotEmpty)
                          Text(opt.description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11,
                                  color: Theme.of(context).colorScheme.outline)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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

/// Loading indicator shown at the visual top of the message list while
/// fetching an older page (scroll-up lazy pagination).
class _LoadingEarlierRow extends StatelessWidget {
  const _LoadingEarlierRow();

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '加载中',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Error hint shown at the visual top when a backward page load failed
/// (IR-R4). Tapping or scrolling retries (scrolling triggers _onScroll →
/// _maybeLoadEarlier; loadOnePage clears the error flag on entry).
class _LoadEarlierErrorRow extends StatelessWidget {
  final VoidCallback? onRetry;
  const _LoadEarlierErrorRow({this.onRetry});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Text(
            '加载失败，点按或上滑重试',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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

/// Combined bottom bar: agent/model chips row + compose input row,
/// sharing a single background and bottom safe-area padding.
class _BottomBar extends StatelessWidget {
  final String sessionId;
  final String directory;
  final TextEditingController ctl;
  final bool busy;
  final Future<void> Function() onAbort;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final List<AttachmentPreview> attachments;
  final VoidCallback onPickAttachments;
  final ValueChanged<int> onRemoveAttachment;

  const _BottomBar({
    required this.sessionId,
    required this.directory,
    required this.ctl,
    required this.busy,
    required this.onAbort,
    required this.onChanged,
    required this.onSend,
    required this.attachments,
    required this.onPickAttachments,
    required this.onRemoveAttachment,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
            top: BorderSide(
                color: Theme.of(context).dividerTheme.color ??
                    const Color(0xFF33373E))),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (attachments.isNotEmpty)
            _AttachmentPreviewBar(
              attachments: attachments,
              onRemove: onRemoveAttachment,
            ),
          _ComposeBar(
            ctl: ctl,
            busy: busy,
            onAbort: onAbort,
            onChanged: onChanged,
            onSend: onSend,
            attachments: attachments,
            onPickAttachments: onPickAttachments,
          ),
          _AgentModelBar(
            sessionId: sessionId,
            directory: directory,
          ),
        ],
      ),
    );
  }
}

class _ComposeBar extends StatefulWidget {
  final TextEditingController ctl;
  final ValueChanged<String> onChanged;
  final VoidCallback onSend;
  final bool busy;
  final Future<void> Function() onAbort;
  final List<AttachmentPreview> attachments;
  final VoidCallback onPickAttachments;
  const _ComposeBar({
    required this.ctl,
    required this.onChanged,
    required this.onSend,
    required this.busy,
    required this.onAbort,
    required this.attachments,
    required this.onPickAttachments,
  });

  @override
  State<_ComposeBar> createState() => _ComposeBarState();
}

class _ComposeBarState extends State<_ComposeBar> {
  bool _aborting = false;

  @override
  void didUpdateWidget(_ComposeBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_aborting && oldWidget.busy && !widget.busy) {
      _aborting = false;
    }
  }

  Future<void> _onStopPressed() async {
    if (_aborting) return;
    setState(() => _aborting = true);
    try {
      await widget.onAbort();
    } catch (_) {
      if (mounted) setState(() => _aborting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final showStop = widget.busy &&
        widget.ctl.text.trim().isEmpty &&
        widget.attachments.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(left: 12, right: 8, top: 8, bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: widget.ctl,
              onChanged: widget.onChanged,
              onSubmitted: (_) => widget.onSend(),
              minLines: 1,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: '/ 命令　! shell　发指令…',
                isDense: true,
                prefixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '附件',
                  onPressed: widget.onPickAttachments,
                ),
                prefixIconColor:
                    Theme.of(context).colorScheme.onSurfaceVariant,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                filled: true,
              ),
            ),
          ),
          const SizedBox(width: 6),
          showStop
              ? IconButton.filled(
                  onPressed: _onStopPressed,
                  icon: _aborting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.stop_rounded),
                  tooltip: '停止推理',
                  style: IconButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                )
              : IconButton.filled(
                  onPressed: widget.onSend,
                  icon: const Icon(Icons.send),
                  tooltip: '发送',
                ),
        ],
      ),
    );
  }
}

class _CommandHints extends StatelessWidget {
  final String query;
  final List<CommandInfo> commands;
  final bool loading;
  final String? error;
  final ValueChanged<String> onPick;
  const _CommandHints({
    required this.query,
    required this.commands,
    required this.loading,
    this.error,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    final q = query.toLowerCase();
    final matches = commands
        .where((c) => c.slash.toLowerCase().startsWith(q))
        .toList();
    if (matches.isEmpty) {
      if (loading) {
        return _shell(
          context,
          const ListTile(
            dense: true,
            leading: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            title: Text('加载可用命令…', style: TextStyle(fontSize: 13)),
          ),
        );
      }
      return const SizedBox.shrink();
    }
    return _shell(
      context,
      ListView(
        shrinkWrap: true,
        children: matches
            .map((c) => ListTile(
                  dense: true,
                  leading: const Icon(Icons.terminal, size: 18),
                  title: Text(c.slash,
                      style: AppTheme.mono.copyWith(fontSize: 13)),
                  subtitle: c.description.isNotEmpty
                      ? Text(
                          c.description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        )
                      : null,
                  onTap: () => onPick(c.slash),
                ))
            .toList(),
      ),
    );
  }

  Widget _shell(BuildContext context, Widget child) => Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.3),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border:
              Border(top: BorderSide(color: Theme.of(context).dividerColor)),
        ),
        child: child,
      );
}

class _MoreMenu extends StatelessWidget {
  final String sessionId;
  final String directory;
  final SessionModel? session;
  const _MoreMenu({
    required this.sessionId,
    required this.directory,
    this.session,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: '更多',
      onSelected: (v) => _onSelected(context, v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'refresh', child: Text('刷新')),
        PopupMenuItem(value: 'rename', child: Text('修改标题')),
        PopupMenuItem(value: 'archive', child: Text('归档')),
      ],
    );
  }

  Future<void> _onSelected(BuildContext context, String value) async {
    switch (value) {
      case 'refresh':
        final conv = serverStore.conversationFor(sessionId);
        if (conv != null) unawaited(conv.reload());
      case 'rename':
        await _showRenameDialog(context);
      case 'archive':
        final client = serverStore.client;
        if (client == null) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('归档会话'),
            content: const Text('归档后会话从列表隐藏，可稍后恢复。'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('归档')),
            ],
          ),
        );
        if (ok == true) {
          try {
            await client.archive(sessionId,
                directory: directory,
                archived: DateTime.now().millisecondsSinceEpoch);
            if (context.mounted) context.pop();
          } catch (e) {
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(SnackBar(content: Text('归档失败：$e')));
            }
          }
        }
    }
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final client = serverStore.client;
    if (client == null) return;
    final ctl =
        TextEditingController(text: session?.title ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改标题'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '标题',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok == true) {
      final title = ctl.text.trim();
      if (title.isEmpty) return;
      try {
        await client.updateTitle(sessionId, title, directory: directory);
        unawaited(serverStore.refresh());
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('修改失败：$e')));
        }
      }
    }
  }
}

/// Agent / Model / Thinking variant switcher bar, shown above the compose bar.
class _AgentModelBar extends StatefulWidget {
  final String sessionId;
  final String directory;

  const _AgentModelBar({
    required this.sessionId,
    required this.directory,
  });

  @override
  State<_AgentModelBar> createState() => _AgentModelBarState();
}

class _AgentModelBarState extends State<_AgentModelBar> {
  List<AgentInfo> _agents = const [];
  List<ModelInfo> _models = const [];
  bool _loading = false;
  bool _switching = false;
  String? _optimisticAgent;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  Future<void> _loadOptions() async {
    final client = serverStore.client;
    if (client == null) return;
    setState(() => _loading = true);
    try {
      final results = await Future.wait([
        client.listAgents(directory: widget.directory),
        client.listConfigProviders(directory: widget.directory),
      ]);
      if (mounted) {
        setState(() {
          _agents = results[0] as List<AgentInfo>;
          _models = results[1] as List<ModelInfo>;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载选项失败：$e')));
      }
    }
  }

  Future<void> _switchAgent(String agent) async {
    final client = serverStore.client;
    if (client == null || _switching) return;
    setState(() {
      _switching = true;
      _optimisticAgent = agent;
    });
    try {
      await client.switchAgent(widget.sessionId, agent);
      final ok = await serverStore.refresh();
      if (mounted) {
        if (ok) {
          setState(() => _optimisticAgent = null);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('已切换，刷新会话失败，将自动重试')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _optimisticAgent = null);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换 Agent 失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _switchModel(ModelInfo model, [ModelVariant? variant]) async {
    final client = serverStore.client;
    if (client == null) return;
    setState(() => _switching = true);
    try {
      await client.switchModel(
        widget.sessionId,
        ModelRef(
          id: model.id,
          providerID: model.providerID,
          variant: variant?.id,
        ),
      );
      unawaited(serverStore.refresh());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('切换模型失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _showAgentSheet() {
    if (_agents.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: _agents
              .map((a) => ListTile(
                    leading: Icon(
                      a.mode == 'primary' ? Icons.person : Icons.subdirectory_arrow_right,
                      size: 20,
                    ),
                    title: Text(a.name),
                    subtitle: a.description != null && a.description!.isNotEmpty
                        ? Text(a.description!, maxLines: 1, overflow: TextOverflow.ellipsis)
                        : null,
                    trailing: serverStore.sessionById(widget.sessionId)?.agent == a.name
                        ? const Icon(Icons.check, size: 18)
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _switchAgent(a.name);
                    },
                  ))
              .toList(),
        ),
      ),
    );
  }

  void _showModelSheet() {
    if (_models.isEmpty) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _ModelPickerSheet(
        models: _models,
        sessionId: widget.sessionId,
        onSelected: (m) {
          Navigator.pop(ctx);
          _switchModel(m);
        },
        onManage: () {
          // Close the sheet first, then push from this (stable) context —
          // pushing inside the sheet builder would add /models above the
          // sheet in the root navigator, so a subsequent maybePop would pop
          // /models instead of the sheet.
          Navigator.pop(ctx);
          context.push('/models');
        },
      ),
    );
  }

  void _showVariantSheet(ModelInfo model, List<ModelVariant> variants) {
    final session = serverStore.sessionById(widget.sessionId);
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(Icons.do_not_disturb, size: 20),
              title: const Text('默认'),
              trailing: session?.model?.variant == null
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onTap: () {
                Navigator.pop(ctx);
                _switchModel(model);
              },
            ),
            ...variants.map((v) => ListTile(
                  leading: const Icon(Icons.tune, size: 20),
                  title: Text(v.id),
                  trailing: session?.model?.variant == v.id
                      ? const Icon(Icons.check, size: 18)
                      : null,
                  onTap: () {
                    Navigator.pop(ctx);
                    _switchModel(model, v);
                  },
                )),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.outline;

    if (_loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: SizedBox(
          height: 20,
          child: Center(
            child: SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: muted),
            ),
          ),
        ),
      );
    }

    return ListenableBuilder(
      listenable: serverStore,
      builder: (context, _) {
        final session = serverStore.sessionById(widget.sessionId);
        final agentName = _optimisticAgent ?? session?.agent ?? '—';
        final modelName = session?.model?.id ?? '—';

        if (_optimisticAgent != null && session?.agent == _optimisticAgent) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted &&
                _optimisticAgent != null &&
                serverStore.sessionById(widget.sessionId)?.agent ==
                    _optimisticAgent) {
              setState(() => _optimisticAgent = null);
            }
          });
        }

        // Find current model's variants for thinking level button.
        // Match both providerID and id: model ids repeat across providers
        // (e.g. deepseek-v4-flash exists under both `deepseek` and
        // `ollama-cloud`), so id-only matching would pick the wrong entry.
        final currentModel = _models
            .where((m) =>
                m.id == session?.model?.id &&
                m.providerID == session?.model?.providerID)
            .toList();
        final hasVariants =
            currentModel.isNotEmpty && currentModel.first.variants.isNotEmpty;

        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 2),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                if (_agents.length == 2 &&
                    _agents.any((a) => a.name == agentName))
                  _AgentCapsuleToggle(
                    agents: _agents,
                    currentAgent: agentName,
                    onSwitch: _switching ? null : _switchAgent,
                  )
                else
                  _Chip(
                    icon: Icons.smart_toy_outlined,
                    label: agentName,
                    onTap: (_switching || _agents.length <= 1)
                        ? null
                        : _showAgentSheet,
                    muted: muted,
                  ),
                const SizedBox(width: 8),
                _Chip(
                  icon: Icons.memory,
                  label: modelName,
                  onTap: _switching ? null : _showModelSheet,
                  muted: muted,
                ),
                if (hasVariants) ...[
                  const SizedBox(width: 8),
                  _Chip(
                    icon: Icons.psychology_outlined,
                    label: session?.model?.variant ?? '默认',
                    onTap: _switching ? null : () => _showVariantSheet(currentModel.first, currentModel.first.variants),
                    muted: muted,
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Capsule-style segmented toggle for exactly 2 agents.
/// Both options are visible side-by-side; a highlight slides to the active one.
class _AgentCapsuleToggle extends StatefulWidget {
  final List<AgentInfo> agents;
  final String currentAgent;
  final ValueChanged<String>? onSwitch;

  const _AgentCapsuleToggle({
    required this.agents,
    required this.currentAgent,
    this.onSwitch,
  });

  @override
  State<_AgentCapsuleToggle> createState() => _AgentCapsuleToggleState();
}

class _AgentCapsuleToggleState extends State<_AgentCapsuleToggle>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  final GlobalKey _stackKey = GlobalKey();
  late List<GlobalKey> _optionKeys;

  double _left = 0, _width = 0;
  double _fromLeft = 0, _fromWidth = 0;
  bool _measured = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _optionKeys = List.generate(widget.agents.length, (_) => GlobalKey());
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure(true));
  }

  @override
  void didUpdateWidget(covariant _AgentCapsuleToggle old) {
    super.didUpdateWidget(old);
    if (!identical(old.agents, widget.agents)) {
      _optionKeys = List.generate(widget.agents.length, (_) => GlobalKey());
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure(true));
    } else if (old.currentAgent != widget.currentAgent) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _measure(false));
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _measure(bool initial) {
    final idx = widget.agents.indexWhere((a) => a.name == widget.currentAgent);
    final stackCtx = _stackKey.currentContext;
    if (idx < 0 || stackCtx == null) return;
    final stackBox = stackCtx.findRenderObject() as RenderBox?;
    final optionCtx = _optionKeys[idx].currentContext;
    if (stackBox == null || !stackBox.hasSize || optionCtx == null) return;
    final optionBox = optionCtx.findRenderObject() as RenderBox?;
    if (optionBox == null || !optionBox.hasSize) return;
    final pos = optionBox.localToGlobal(Offset.zero, ancestor: stackBox);
    final newLeft = pos.dx;
    final newWidth = optionBox.size.width;
    if (initial) {
      _fromLeft = _left = newLeft;
      _fromWidth = _width = newWidth;
      _measured = true;
      _ctrl.value = 1;
    } else {
      _fromLeft = _left;
      _fromWidth = _width;
      _left = newLeft;
      _width = newWidth;
      _ctrl.forward(from: 0);
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Curves.easeOutCubic.transform(_ctrl.value);
    final curLeft = _fromLeft + (_left - _fromLeft) * t;
    final curWidth = _fromWidth + (_width - _fromWidth) * t;

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.all(2),
      child: Stack(
        key: _stackKey,
        children: [
          if (_measured)
            Positioned(
              left: curLeft,
              width: curWidth,
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < widget.agents.length; i++)
                _buildOption(widget.agents[i], i, scheme),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildOption(AgentInfo a, int idx, ColorScheme scheme) {
    final active = a.name == widget.currentAgent;
    return Semantics(
      selected: active,
      button: true,
      enabled: widget.onSwitch != null && !active,
      child: GestureDetector(
        key: _optionKeys[idx],
        behavior: HitTestBehavior.opaque,
        onTap: widget.onSwitch == null || active
            ? null
            : () => widget.onSwitch!(a.name),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 14,
                color: active ? scheme.onPrimaryContainer : scheme.outline,
              ),
              const SizedBox(width: 4),
              Text(
                a.name,
                style: TextStyle(
                  fontSize: 12,
                  color: active ? scheme.onPrimaryContainer : scheme.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Model picker bottom sheet: search bar + models grouped by provider.
///
/// Grouping follows first-appearance order of `providerID` in [models] (server
/// order). Search matches model name, id, and providerID (case-insensitive).
/// When a search is active, empty providers are hidden; the query is reset on
/// close.
class _ModelPickerSheet extends StatefulWidget {
  final List<ModelInfo> models;
  final String sessionId;
  final ValueChanged<ModelInfo> onSelected;
  final VoidCallback? onManage;

  const _ModelPickerSheet({
    required this.models,
    required this.sessionId,
    required this.onSelected,
    this.onManage,
  });

  @override
  State<_ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<_ModelPickerSheet> {
  final _controller = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool _matches(ModelInfo m, String q) {
    if (q.isEmpty) return true;
    return m.name.toLowerCase().contains(q) ||
        m.id.toLowerCase().contains(q) ||
        m.providerID.toLowerCase().contains(q);
  }

  String? get _serverId => connectionStore.activeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final session = serverStore.sessionById(widget.sessionId);
    final q = _query.toLowerCase();

    // Listen to hidden-model changes so toggles in the model-management
    // page reflect here immediately.
    return ListenableBuilder(
      listenable: modelHideStore,
      builder: (context, _) {
        // Visible models: server order, grouped by providerID, excluding
        // hidden ones and search misses.
        final groups = <String, List<ModelInfo>>{};
        for (final m in widget.models) {
          if (modelHideStore.isHidden(_serverId, m.providerID, m.id)) continue;
          if (!_matches(m, q)) continue;
          (groups[m.providerID] ??= []).add(m);
        }

        return SafeArea(
          child: ConstrainedBox(
            // Cap at ~70% of the viewport height *above the open keyboard* so
            // the sheet scrolls internally when there are many models, while
            // shrinking to content (search + list) when there are few.
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: Padding(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 4, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _controller,
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(fontSize: 14),
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: '搜索模型 / provider',
                              hintStyle: TextStyle(
                                  fontSize: 14, color: scheme.outline),
                              prefixIcon: Icon(Icons.search,
                                  size: 20, color: scheme.outline),
                              suffixIcon: _query.isEmpty
                                  ? null
                                  : IconButton(
                                      visualDensity: VisualDensity.compact,
                                      iconSize: 18,
                                      icon: const Icon(Icons.close),
                                      onPressed: () {
                                        _controller.clear();
                                        setState(() => _query = '');
                                      },
                                    ),
                              border: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 10),
                            ),
                            onChanged: (v) =>
                                setState(() => _query = v.trim()),
                          ),
                        ),
                        IconButton(
                          tooltip: '模型管理',
                          icon: const Icon(Icons.tune),
                          onPressed: widget.onManage,
                        ),
                      ],
                    ),
                  ),
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Text('无匹配模型',
                          style: TextStyle(
                              fontSize: 13, color: scheme.outline)),
                    )
                  else
                    Flexible(
                      fit: FlexFit.loose,
                      child: ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: _buildGroups(groups, session, scheme),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildGroups(
    Map<String, List<ModelInfo>> groups,
    SessionModel? session,
    ColorScheme scheme,
  ) {
    final out = <Widget>[];
    for (final providerID in groups.keys) {
      final items = groups[providerID]!;
      out.add(Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 12, 4),
            child: Row(
              children: [
                Icon(Icons.dns_outlined, size: 14, color: scheme.outline),
                const SizedBox(width: 6),
                Text(
                  providerID,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.outline,
                  ),
                ),
                const SizedBox(width: 6),
                Text('${items.length}',
                    style: TextStyle(fontSize: 11, color: scheme.outline)),
              ],
            ),
          ),
          ...items.map((m) {
            final selected = session?.model?.id == m.id &&
                session?.model?.providerID == m.providerID;
            return ListTile(
              dense: true,
              leading: const Icon(Icons.memory, size: 20),
              title: Text(m.name, style: const TextStyle(fontSize: 14)),
              subtitle: Text('${m.providerID}/${m.id}',
                  style: AppTheme.mono.copyWith(fontSize: 11)),
              trailing:
                  selected ? const Icon(Icons.check, size: 18) : null,
              onTap: () => widget.onSelected(m),
            );
          }),
        ],
      ));
    }
    return out;
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color muted;

  const _Chip({
    required this.icon,
    required this.label,
    this.onTap,
    required this.muted,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: muted),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(fontSize: 12, color: muted)),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: muted),
          ],
        ),
      ),
    );
  }
}