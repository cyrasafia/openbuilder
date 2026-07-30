import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../ui/l10n_ext.dart';

/// Max pinch-zoom scale. [cacheWidth] is sized to stay crisp up to this factor,
/// which also bounds decoded-bitmap memory for pathological source sizes.
const _maxScale = 5.0;

class ImageView extends StatelessWidget {
  final Uint8List? bytes;
  final String? text;
  final bool isSvg;

  const ImageView({super.key, Uint8List? bytes, String? text, required this.isSvg})
      : assert(bytes != null || text != null),
        bytes = bytes,
        text = text;

  @override
  Widget build(BuildContext context) {
    if (isSvg) {
      return InteractiveViewer(
        minScale: 0.5,
        maxScale: _maxScale,
        child: Center(
          child: SvgPicture.string(
            text!,
            errorBuilder: (ctx, _, _) => _errorPlaceholder(ctx),
          ),
        ),
      );
    }
    final b = bytes;
    if (b == null) return _errorPlaceholder(context);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = (MediaQuery.sizeOf(context).width * dpr * _maxScale).toInt();
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: _maxScale,
      child: Center(
        child: Image.memory(
          b,
          cacheWidth: cacheWidth,
          errorBuilder: (ctx, _, _) => _errorPlaceholder(ctx),
        ),
      ),
    );
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
