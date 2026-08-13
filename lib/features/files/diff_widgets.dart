import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// "+N −M" change-stat indicator shared by the diff list and diff detail
/// (hunk header) views.
///
/// When [addWidth] / [delWidth] are provided, each column is rendered as a
/// fixed-width right-aligned box so that the add column and the del column
/// line up vertically across rows (e.g. the list header totals vs. each file
/// row). When omitted, the columns size to their natural width.
///
/// Callers that want to pre-measure the column width (e.g. to align across
/// rows) must measure with [statStyle] so the measured width matches the
/// rendered width.
class DiffStat extends StatelessWidget {
  /// Base text style used for both rendering and external width measurement.
  /// Monospace so digits are uniform-width and the add/del columns stay
  /// aligned regardless of the ambient `DefaultTextStyle` font family.
  static const statStyle = AppTheme.mono;

  final int add;
  final int del;
  final double? addWidth;
  final double? delWidth;
  const DiffStat({
    super.key,
    required this.add,
    required this.del,
    this.addWidth,
    this.delWidth,
  });

  @override
  Widget build(BuildContext context) {
    final a = Theme.of(context).extension<AppColors>()!;
    final base = const TextStyle(fontSize: 13).merge(statStyle);
    final addText = Text(
      '+$add',
      textAlign: addWidth != null ? TextAlign.right : null,
      style: base.copyWith(color: a.diffAddFg),
    );
    final delText = Text(
      '−$del',
      textAlign: delWidth != null ? TextAlign.right : null,
      style: base.copyWith(color: a.diffDelFg),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        addWidth != null
            ? SizedBox(width: addWidth, child: addText)
            : addText,
        const SizedBox(width: 8),
        delWidth != null
            ? SizedBox(width: delWidth, child: delText)
            : delText,
      ],
    );
  }
}