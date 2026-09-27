import 'package:flutter/material.dart';

import 'widgets.dart';

/// 三处列表页（会话 / 项目 / 文件）共用的搜索 AppBar。
///
/// 收起态：[collapsedLeading] + 标题 + 搜索按钮 + [collapsedActions]；
/// 展开态：返回按钮（退出搜索）+ 居中输入框 + 按需清空按钮（仅有文本时
/// 展示，清空并通知 [onChanged]）。[interceptSystemBack] 时系统返回在展
/// 开态先退出搜索（PopScope 拦截）；文件页返回链已由容器接管，传 false
/// 跳过。
///
/// [expanded]/[controller] 由宿主 State 持有（文件页还参与快照恢复），
/// 控件本身无状态；[onExitSearch] 同时服务返回按钮与系统返回。
class SearchAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String searchHint;
  final bool expanded;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onExpand;
  final VoidCallback onExitSearch;
  final bool interceptSystemBack;
  final String? collapsedTitle;
  final TextStyle? collapsedTitleStyle;
  final Widget? collapsedLeading;
  final List<Widget> collapsedActions;

  const SearchAppBar({
    super.key,
    required this.searchHint,
    required this.expanded,
    required this.controller,
    required this.onChanged,
    required this.onExpand,
    required this.onExitSearch,
    this.interceptSystemBack = true,
    this.collapsedTitle,
    this.collapsedTitleStyle,
    this.collapsedLeading,
    this.collapsedActions = const [],
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final bar = AppBar(
      leading: expanded
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: searchHint,
              onPressed: onExitSearch,
            )
          : collapsedLeading,
      title: expanded
          ? TextField(
              controller: controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                hintText: searchHint,
                isDense: true,
                border: InputBorder.none,
                suffixIcon: controller.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                      )
                    : null,
              ),
              onChanged: onChanged,
            )
          : (collapsedTitle == null
              ? null
              : Text(collapsedTitle!, style: collapsedTitleStyle)),
      actions: [
        if (!expanded) ...[
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: searchHint,
            onPressed: onExpand,
          ),
          ...collapsedActions,
        ],
        appBarActionsTrailing,
      ],
    );
    if (!expanded || !interceptSystemBack) return bar;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) onExitSearch();
      },
      child: bar,
    );
  }
}