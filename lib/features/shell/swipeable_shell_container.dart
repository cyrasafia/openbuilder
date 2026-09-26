import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class SwipeableShellContainer extends StatefulWidget {
  final StatefulNavigationShell navigationShell;
  final List<Widget> children;

  const SwipeableShellContainer({
    super.key,
    required this.navigationShell,
    required this.children,
  });

  @override
  State<SwipeableShellContainer> createState() =>
      _SwipeableShellContainerState();
}

class _SwipeableShellContainerState extends State<SwipeableShellContainer> {
  late final PageController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        PageController(initialPage: widget.navigationShell.currentIndex);
  }

  @override
  void didUpdateWidget(covariant SwipeableShellContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = widget.navigationShell.currentIndex;
    if (_controller.hasClients) {
      final page = _controller.page;
      if (page != null && page.round() != index) {
        _controller.animateToPage(
          index,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // See MainShell._goBranch: tab branches are keep-alive pages, so unfocus on
  // a swipe-initiated branch change too — otherwise the IME stays open over a
  // tab with no visible text field.
  void _onPageChanged(int i) {
    FocusManager.instance.primaryFocus?.unfocus();
    widget.navigationShell.goBranch(i);
  }

  @override
  Widget build(BuildContext context) {
    final current = widget.navigationShell.currentIndex;
    return PageView(
      controller: _controller,
      physics: const ClampingScrollPhysics(),
      onPageChanged: _onPageChanged,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          TickerMode(
            enabled: i == current,
            child: widget.children[i],
          ),
      ],
    );
  }
}
