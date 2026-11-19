import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../app_state.dart';
import '../../core/attachments/local_image_cache.dart';
import '../../data/api/opencode_client.dart';
import '../files/file_browsing_container.dart';
import '../files/image_view.dart';
import 'message_autolink.dart';

/// Agent inline images (design-agent-inline-image).
///
/// The agent embeds server filesystem paths as standard Markdown image
/// syntax in assistant text (`![QR](auth-qrcode.png)`). An [InlinePattern]
/// claims those matches before the built-in pipeline parses them
/// (mask-before-parse), so http(s)/data images keep the untouched default
/// rendering; every match this builder receives resolves to a bitmap, an
/// SVG, or a file chip fetched via `readFileStream`.

/// Cheap gate: only messages containing a Markdown image marker get an
/// inlinePatterns assembly at all.
bool textMayContainLocalImage(String text) => text.contains('![');

/// Claims `![alt](src)` where src carries no URI scheme. The negative
/// lookahead excludes http(s)/data/file/… up front, so those fall through to
/// the built-in ImageMd pipeline unchanged (S5/S6/S7). Src ends at the first
/// `)`, mirroring the built-in balanced-paren scan on the common shapes;
/// paths containing `(` truncate early — known, documented edge.
final RegExp localImagePattern = RegExp(
  r'!\[([^\[\]]*)\]\((?![A-Za-z][A-Za-z\d+.\-]*:)([^\s)]+)\)',
);

final RegExp _controlChars = RegExp(r'[\u0000-\u001f\u007f]');

enum InlineImageKind { bitmap, svg, chip }

class InlineImageSpec {
  final String path;
  final String directory;

  /// Path form for file-route taps: relative srcs keep the relative path,
  /// absolute srcs keep the original absolute path (resolveLocalImage splits
  /// them into directory+path for the fetch, but the route wants the whole
  /// thing back so the project-root prefix can be stripped).
  final String linkPath;
  final InlineImageKind kind;

  const InlineImageSpec({
    required this.path,
    required this.directory,
    required this.linkPath,
    required this.kind,
  });
}

const double _inlineImageMaxHeight = 220;

/// Resolves a claimed image src against the session directory.
///
/// Relative paths resolve against [sessionDirectory]; absolute paths split
/// into `directory=dirname` + `path=basename`, which lets the server read
/// files outside the project (matches the official client). Returns null
/// when the src cannot be fetched at all — the builder must still produce a
/// widget, which then renders the failure row.
InlineImageSpec? resolveLocalImage(String src, String sessionDirectory) {
  final s = src.trim();
  if (s.isEmpty) return null;
  if (_controlChars.hasMatch(s) || s.startsWith('//')) return null;
  if (sessionDirectory.isEmpty) return null;
  final String path;
  final String directory;
  if (s.startsWith('/')) {
    final slash = s.lastIndexOf('/');
    path = s.substring(slash + 1);
    directory = slash == 0 ? '/' : s.substring(0, slash);
  } else {
    path = s;
    directory = sessionDirectory;
  }
  final ext = path.contains('.')
      ? path.substring(path.lastIndexOf('.') + 1).toLowerCase()
      : '';
  const bitmaps = {'png', 'jpeg', 'jpg', 'gif', 'webp', 'bmp'};
  final kind = bitmaps.contains(ext)
      ? InlineImageKind.bitmap
      : ext == 'svg'
          ? InlineImageKind.svg
          : InlineImageKind.chip;
  return InlineImageSpec(
    path: path,
    directory: directory,
    linkPath: s,
    kind: kind,
  );
}

String _baseName(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

/// Default loader: read the bytes off the connected server via the same
/// download channel as the file viewer.
Future<Uint8List?> _defaultLoader(InlineImageSpec spec) async {
  final c = serverStore.client;
  if (c == null) return null;
  final f = await c.readFileStream(directory: spec.directory, path: spec.path);
  return f.bytes;
}

/// Builds the span for one [localImagePattern] match. Always produces a
/// widget — spec-less matches render the failure row (S12).
InlineSpan buildInlineImageSpan(
  BuildContext context,
  RegExpMatch match,
  TextStyle style,
  String directory, {
  required void Function(String href) onOpenFile,
  Future<Uint8List?> Function(InlineImageSpec spec)? loader,
}) {
  final alt = (match.group(1) ?? '').trim();
  final src = match.group(2) ?? '';
  final spec = resolveLocalImage(src, directory);
  final name = alt.isNotEmpty ? alt : _baseName(src);
  Future<Uint8List?> Function()? effectiveLoader;
  if (spec != null) {
    effectiveLoader = loader != null
        ? () => loader(spec)
        : () => _defaultLoader(spec);
  }
  return WidgetSpan(
    alignment: PlaceholderAlignment.middle,
    child: InlineAgentImage(
      spec: spec,
      displayName: name,
      loader: effectiveLoader,
      onOpenFile: onOpenFile,
    ),
  );
}

/// Inline display of one agent-sent image: load/grow states, tap to zoom.
class InlineAgentImage extends StatefulWidget {
  final InlineImageSpec? spec;
  final String displayName;
  final Future<Uint8List?> Function()? loader;
  final void Function(String href)? onOpenFile;

  const InlineAgentImage({
    super.key,
    required this.spec,
    required this.displayName,
    this.loader,
    this.onOpenFile,
  });

  @override
  State<InlineAgentImage> createState() => _InlineAgentImageState();
}

class _InlineAgentImageState extends State<InlineAgentImage> {
  late Future<Uint8List?>? _future;

  @override
  void initState() {
    super.initState();
    _future = _start();
  }

  @override
  void didUpdateWidget(InlineAgentImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spec?.path != oldWidget.spec?.path ||
        widget.spec?.directory != oldWidget.spec?.directory) {
      _future = _start();
    }
  }

  Future<Uint8List?>? _start() {
    final spec = widget.spec;
    final loader = widget.loader;
    if (spec == null || loader == null) return null;
    if (spec.kind == InlineImageKind.chip) return null;
    return LocalImageCache.instance.fetch(
      '${spec.directory}\x1f${spec.path}',
      () => loader(),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.spec?.kind == InlineImageKind.chip) return _chipRow(context);
    final future = _future;
    if (future == null) return _failureRow(context);
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return _loadingBlock(context);
        }
        if (snap.hasError) return _failureRow(context);
        final bytes = snap.data;
        if (bytes == null) return _failureRow(context);
        final kind = widget.spec?.kind ?? InlineImageKind.bitmap;
        if (kind == InlineImageKind.svg) {
          if (bytes.length > kInlineParseLimit) return _failureRow(context);
          return _svgImage(context, bytes);
        }
        return _bitmapImage(context, bytes);
      },
    );
  }

  Widget _loadingBlock(BuildContext context) {
    return Container(
      height: 120,
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  Widget _bitmapImage(BuildContext context, Uint8List bytes) {
    return GestureDetector(
      onTap: () => _openFullScreen(context, bytes, false, null),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 64,
            maxHeight: _inlineImageMaxHeight,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.memory(
              bytes,
              cacheHeight:
                  (_inlineImageMaxHeight * MediaQuery.devicePixelRatioOf(
                    context,
                  )).round(),
              errorBuilder: (_, _, _) => _failureRow(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _svgImage(BuildContext context, Uint8List bytes) {
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return _failureRow(context);
    }
    return GestureDetector(
      onTap: () => _openFullScreen(context, bytes, true, text),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width - 64,
            maxHeight: _inlineImageMaxHeight,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SvgPicture.string(text, fit: BoxFit.contain),
          ),
        ),
      ),
    );
  }

  Widget _failureRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.broken_image_outlined, size: 20, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              widget.displayName,
              style: TextStyle(fontSize: 12, color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipRow(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return GestureDetector(
      onTap: () {
        final linkPath = widget.spec?.linkPath;
        if (linkPath == null || linkPath.isEmpty) return;
        widget.onOpenFile?.call(fileHref(linkPath, null));
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.insert_drive_file, size: 16, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                widget.spec?.linkPath ?? widget.displayName,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: color,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _openFullScreen(
    BuildContext context,
    Uint8List bytes,
    bool isSvg,
    String? svgText,
  ) {
    Navigator.of(context).push(
      slideLeftRoute(
        Scaffold(
          backgroundColor: Colors.black87,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: SafeArea(
            child: ImageView(bytes: bytes, text: svgText, isSvg: isSvg),
          ),
        ),
      ),
    );
  }
}
