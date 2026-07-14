import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';

class MainShell extends StatefulWidget {
  final StatefulNavigationShell shell;
  const MainShell({super.key, required this.shell});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  Timer? _pauseTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _pauseTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // Defer SSE teardown by 30s — if the user returns quickly (e.g. quick
        // app switch / notification peek) we avoid a full reconnect cycle.
        _pauseTimer?.cancel();
        _pauseTimer = Timer(const Duration(seconds: 30), () {
          serverStore.pause();
        });
        break;
      case AppLifecycleState.resumed:
        _pauseTimer?.cancel();
        _pauseTimer = null;
        serverStore.resume();
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: serverStore,
        builder: (context, _) => Column(
          children: [
            Expanded(child: widget.shell),
            if (serverStore.error != null) _ErrorBanner(error: serverStore.error!),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.shell.currentIndex,
        onDestinationSelected: (i) =>
            widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '会话',
          ),
          NavigationDestination(
            icon: Icon(Icons.folder_copy_outlined),
            selectedIcon: Icon(Icons.folder_copy),
            label: '项目',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}

/// Error banner shown when the server connection fails (replaces the old
/// reconnecting banner — on-demand SSE no longer has a global reconnect state).
class _ErrorBanner extends StatelessWidget {
  final String error;
  const _ErrorBanner({required this.error});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.errorContainer,
      child: Text(
        error,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
