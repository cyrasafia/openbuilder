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
                fontWeight: FontWeight.w700,
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

enum _Status { idle, busy, retry }

class StatusDot extends StatelessWidget {
  final String type; // idle | busy | retry
  final double size;
  const StatusDot({super.key, required this.type, this.size = 9});

  @override
  Widget build(BuildContext context) {
    final s = _map(type);
    const busy = Color(0xFF4ADE80);
    const retry = Color(0xFFF0883E);
    const idle = Color(0xFF8B949E);
    final color = s == _Status.busy
        ? busy
        : s == _Status.retry
            ? retry
            : idle;
    if (s == _Status.busy || s == _Status.retry) {
      return _Pulse(color: color, size: size);
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
  }

  _Status _map(String t) {
    switch (t) {
      case 'busy':
        return _Status.busy;
      case 'retry':
        return _Status.retry;
      default:
        return _Status.idle;
    }
  }
}

class _Pulse extends StatefulWidget {
  final Color color;
  final double size;
  const _Pulse({required this.color, required this.size});

  @override
  State<_Pulse> createState() => _PulseState();
}

class _PulseState extends State<_Pulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
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
        final a = 0.4 + 0.6 * _c.value;
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: widget.color.withAlpha((255 * a).round()),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withAlpha((120 * a).round()),
                blurRadius: 5,
              ),
            ],
          ),
        );
      },
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

/// A subtle SSE connection status indicator (small dot) for app bars.
/// Green = connected, amber = reconnecting, red = disconnected.
class SseStatusDot extends StatelessWidget {
  final bool connected;
  final bool reconnecting;
  const SseStatusDot({super.key, required this.connected, this.reconnecting = false});

  @override
  Widget build(BuildContext context) {
    final (color, tooltip) = switch ((connected, reconnecting)) {
      (true, _) => (const Color(0xFF3FB950), 'SSE 已连接'),
      (false, true) => (const Color(0xFFF0883E), 'SSE 重连中'),
      (false, false) => (const Color(0xFFF85149), 'SSE 未连接'),
    };
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
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
      ),
    );
  }
}
