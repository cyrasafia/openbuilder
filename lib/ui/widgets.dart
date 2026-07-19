import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/models.dart';

const _palette = <int>[
  0xFF4ADE80, 0xFF60A5FA, 0xFFF0883E, 0xFFC084FC, 0xFFF472B6,
  0xFF34D399, 0xFFFACC15, 0xFF22D3EE, 0xFFA78BFA,
];

Color colorForName(String name) {
  var h = 0;
  for (final c in name.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return Color(_palette[h % _palette.length]);
}

Color? namedColor(String? n) {
  switch (n) {
    case 'mint':
    case 'green':
      return const Color(0xFF4ADE80);
    case 'pink':
      return const Color(0xFFF472B6);
    case 'blue':
      return const Color(0xFF60A5FA);
    case 'orange':
      return const Color(0xFFF0883E);
    case 'purple':
      return const Color(0xFFC084FC);
    case 'yellow':
      return const Color(0xFFFACC15);
    case 'red':
      return const Color(0xFFF85149);
    case 'cyan':
      return const Color(0xFF22D3EE);
    default:
      return null;
  }
}

/// Project / repo avatar: override|url image, else monogram on a colored tile.
class ProjectAvatar extends StatelessWidget {
  final String name;
  final ProjectIcon? icon;
  final double size;

  const ProjectAvatar({
    super.key,
    required this.name,
    this.icon,
    this.size = 44,
  });

  @override
  Widget build(BuildContext context) {
    final img = _imageChild();
    final fg = colorForName(name);
    final bg = namedColor(icon?.color) ?? fg;
    return Container(
      width: size,
      height: size,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
      ),
      foregroundDecoration: img == null
          ? BoxDecoration(
              color: bg.withAlpha(40),
              borderRadius: BorderRadius.circular(size * 0.28),
              border: Border.all(color: bg.withAlpha(90), width: 1),
            )
          : null,
      child: img ??
          Center(
            child: Text(
              _initial(name),
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w600,
                fontSize: size * 0.42,
              ),
            ),
          ),
    );
  }

  Widget? _imageChild() {
    final src = icon?.image;
    if (src == null || src.isEmpty) return null;
    if (src.startsWith('data:')) {
      final idx = src.indexOf('base64,');
      if (idx == -1) return null;
      try {
        final bytes = base64.decode(src.substring(idx + 7));
        return Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
      } catch (_) {
        return null;
      }
    }
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return Image.network(src, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return null;
  }

  String _initial(String n) =>
      n.isEmpty ? '?' : n.trim().characters.first.toString().toUpperCase();
}

class AgentStatusIndicator extends StatelessWidget {
  final AgentIndicatorState state;
  const AgentStatusIndicator({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final paused = state.state == AgentRunState.paused;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final workingColor = dark
        ? const Color(0xFF4ADE80)
        : const Color(0xFF15803D);
    final retryColor = dark
        ? const Color(0xFFFB923C)
        : const Color(0xFFC2410C);
    final pausedColor = dark
        ? const Color(0xFFFBBF24)
        : const Color(0xFF92400E);
    final (color, background, label, icon) = switch (state.state) {
      AgentRunState.working => (
          workingColor,
          workingColor.withAlpha(31),
          '运行中',
          _WorkingGlyph(key: const ValueKey('working'), color: workingColor),
        ),
      AgentRunState.retrying => (
          retryColor,
          retryColor.withAlpha(31),
          '重试中',
          const _RetryGlyph(key: ValueKey('retrying')),
        ),
      AgentRunState.idle => (
          Theme.of(context).colorScheme.outline,
          Theme.of(context).colorScheme.surfaceContainerHighest,
          '空闲',
          const Icon(Icons.circle, key: ValueKey('idle'), size: 8),
        ),
      AgentRunState.paused => (
          pausedColor,
          pausedColor.withAlpha(31),
          state.pauseReason == AgentPauseReason.permission
              ? '需要授权'
              : '需要选择',
          Icon(
            state.pauseReason == AgentPauseReason.permission
                ? Icons.warning_amber_rounded
                : Icons.help_outline,
            key: ValueKey(state.pauseReason),
            size: 13,
          ),
        ),
    };
    final text = state.pendingCount > 1 ? '$label · ${state.pendingCount}' : label;
    return Semantics(
      label: 'Agent $label${state.pendingCount > 1 ? '，共 ${state.pendingCount} 项待处理' : ''}',
      excludeSemantics: true,
      child: RepaintBoundary(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          height: 24,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
            border: paused ? Border.all(color: color) : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconTheme(
                data: IconThemeData(color: color, size: 13),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 120),
                  child: icon,
                ),
              ),
              const SizedBox(width: 5),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),
                child: Text(text,
                    key: ValueKey(text),
                    style: TextStyle(
                        color: color,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkingGlyph extends StatefulWidget {
  final Color color;
  const _WorkingGlyph({super.key, required this.color});

  @override
  State<_WorkingGlyph> createState() => _WorkingGlyphState();
}

class _WorkingGlyphState extends State<_WorkingGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) {
        final value = MediaQuery.disableAnimationsOf(context)
            ? 0.5
            : Curves.easeInOut.transform(_controller.value);
        return SizedBox.square(
          dimension: 13,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Transform.scale(
                scale: 0.75 + value * 0.4,
                child: Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: widget.color.withAlpha((51 + value * 89).round()),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: widget.color,
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RetryGlyph extends StatefulWidget {
  const _RetryGlyph({super.key});

  @override
  State<_RetryGlyph> createState() => _RetryGlyphState();
}

class _RetryGlyphState extends State<_RetryGlyph>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: const Icon(Icons.autorenew, size: 13),
    );
  }
}

String relTime(int ms) {
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final d = DateTime.now().difference(dt);
  if (d.isNegative) return 'now';
  if (d.inMinutes < 1) return 'now';
  if (d.inHours < 1) return '${d.inMinutes}m';
  if (d.inDays < 1) return '${d.inHours}h';
  if (d.inDays < 7) return '${d.inDays}d';
  return '${dt.month}/${dt.day}';
}

/// A subtle SSE connection status indicator (small dot).
/// Green = connected, amber = connecting/reconnecting, hidden = disconnected.
class SseStatusDot extends StatelessWidget {
  final bool connected;
  final bool reconnecting;
  final double size;
  const SseStatusDot({super.key, required this.connected, this.reconnecting = false, this.size = 8});

  @override
  Widget build(BuildContext context) {
    // Disconnected: don't show.
    if (!connected && !reconnecting) return const SizedBox.shrink();

    final (color, tooltip) = switch ((connected, reconnecting)) {
      (true, _) => (const Color(0xFF3FB950), 'SSE 已连接'),
      (false, true) => (const Color(0xFFF0883E), 'SSE 重连中'),
      (false, false) => (const Color(0xFF3FB950), ''),
    };
    return Tooltip(
      message: tooltip,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: Theme.of(context).colorScheme.surface,
            width: 1.5,
          ),
          boxShadow: reconnecting
              ? [
                  BoxShadow(
                    color: color.withAlpha(80),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  final VoidCallback? onRetry;
  const ErrorView({this.onRetry, super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off,
                size: 48, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text('连接失败',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('请检查网络和服务器设置',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.outline)),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              FilledButton(onPressed: onRetry, child: const Text('重试')),
            ],
          ],
        ),
      ),
    );
  }
}

Widget emptyScrollable(Widget child) {
  return LayoutBuilder(
    builder: (context, constraints) => ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: constraints.maxHeight * 0.35),
        child,
      ],
    ),
  );
}
