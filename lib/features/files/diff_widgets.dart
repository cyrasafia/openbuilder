import 'package:flutter/material.dart';

import '../../ui/theme.dart';

/// "+N −M" change-stat indicator shared by the diff list and diff detail
/// (hunk header) views.
class DiffStat extends StatelessWidget {
  final int add;
  final int del;
  const DiffStat({super.key, required this.add, required this.del});

  @override
  Widget build(BuildContext context) {
    final a = Theme.of(context).extension<AppColors>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '+$add',
          style: TextStyle(color: a.diffAddFg, fontSize: 13),
        ),
        const SizedBox(width: 8),
        Text(
          '−$del',
          style: TextStyle(color: a.diffDelFg, fontSize: 13),
        ),
      ],
    );
  }
}