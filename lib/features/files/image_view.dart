import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../domain/models.dart';
import '../../ui/l10n_ext.dart';

const _syncDecodeLimit = 500 * 1024;

class ImageView extends StatefulWidget {
  final FileContent file;
  final bool isSvg;

  const ImageView({super.key, required this.file, required this.isSvg});

  @override
  State<ImageView> createState() => _ImageViewState();
}

class _ImageViewState extends State<ImageView> {
  Uint8List? _bytes;
  bool _decoding = false;
  bool _cancelled = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (!widget.isSvg) _decode();
  }

  @override
  void dispose() {
    _cancelled = true;
    super.dispose();
  }

  Future<void> _decode() async {
    final raw = widget.file.content;
    if (raw.length < _syncDecodeLimit) {
      try {
        _bytes = base64Decode(raw);
      } catch (_) {
        _failed = true;
      }
      return;
    }
    _decoding = true;
    try {
      final result = await compute(_decodeBase64, raw);
      if (!mounted || _cancelled) return;
      setState(() {
        _bytes = result;
        _decoding = false;
      });
    } catch (_) {
      if (!mounted || _cancelled) return;
      setState(() {
        _decoding = false;
        _failed = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isSvg) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: SvgPicture.string(
            widget.file.content,
            errorBuilder: (ctx, _, _) => _errorPlaceholder(ctx),
          ),
        ),
      );
    }
    final bytes = _bytes;
    if (bytes != null) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: 5.0,
        child: Center(
          child: Image.memory(
            bytes,
            errorBuilder: (ctx, _, _) => _errorPlaceholder(ctx),
          ),
        ),
      );
    }
    if (_decoding) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => setState(() {
                _cancelled = true;
                _decoding = false;
              }),
              child: Text(l(context).fileLoadCancel),
            ),
          ],
        ),
      );
    }
    if (_failed) return _errorPlaceholder(context);
    return const SizedBox.shrink();
  }

  Widget _errorPlaceholder(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.broken_image_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(l(context).loadFailed),
        ],
      ),
    );
  }
}

Uint8List _decodeBase64(String raw) => base64Decode(raw);
