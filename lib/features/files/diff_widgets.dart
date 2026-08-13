import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// "+N −M" change-stat indicator shared by the diff list and diff detail
/// (hunk header) views.
///
/// The two counts are rendered at their natural width, the deletion count
/// immediately following the addition count. The whole cluster is meant to
/// be placed by the caller in a right-aligned position (e.g. ListTile
/// `trailing` or after a `Spacer`).
class DiffStat extends StatelessWidget {
  /// Base text style used for rendering.
  /// Monospace so digits are uniform-width.
  static const statStyle = AppTheme.mono;

  final int add;
  final int del;
  const DiffStat({
    super.key,
    required this.add,
    required this.del,
  });

  @override
  Widget build(BuildContext context) {
    final a = Theme.of(context).extension<AppColors>()!;
    final base = const TextStyle(fontSize: 13).merge(statStyle);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('+$add', style: base.copyWith(color: a.diffAddFg)),
        const SizedBox(width: 8),
        Text('−$del', style: base.copyWith(color: a.diffDelFg)),
      ],
    );
  }
}