import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../core/logging/app_logger.dart';
import '../../ui/l10n_ext.dart';

class MainShell extends StatefulWidget {
  final StatefulNavigationShell shell;
  const MainShell({super.key, required this.shell});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  Timer? _pauseTimer;
  bool _foreground = true;

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
    AppLogger.I.i('Lifecycle', state.name);
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        _foreground = false;
        // Defer SSE teardown by 30s — if the user returns quickly (e.g. quick
        // app switch / notification peek) we avoid a full reconnect cycle.
        _pauseTimer?.cancel();
        _pauseTimer = Timer(const Duration(seconds: 30), () {
          if (!_foreground) unawaited(serverStore.pause());
        });
        break;
      case AppLifecycleState.resumed:
        _foreground = true;
        _pauseTimer?.cancel();
        _pauseTimer = null;
        unawaited(serverStore.resume());
        break;
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Delegate the viewInsets freeze to a dedicated lightweight widget so that
    // MainShell.build() itself does NOT register a root-viewInsets dependency.
    // Only _ViewInsetsFreezer rebuilds on keyboard frames (a handful of
    // widgets); the Scaffold + ListenableBuilder + all tab lists below stays
    // inert. The Scaffold internally calls MediaQuery.of (in _addIfNonNull) so
    // it MUST be inside the freeze, not outside.
    return _ViewInsetsFreezer(
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: ListenableBuilder(
          listenable: serverStore,
          builder: (context, _) => Column(
            children: [
              Expanded(child: widget.shell),
              if (serverStore.showDisconnectBanner) const _DisconnectBanner(),
            ],
          ),
        ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: widget.shell.currentIndex,
        onDestinationSelected: (i) =>
            widget.shell.goBranch(i, initialLocation: i == widget.shell.currentIndex),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.chat_bubble_outline),
            selectedIcon: const Icon(Icons.chat_bubble),
            label: l(context).tabSessions,
          ),
          NavigationDestination(
            icon: const Icon(Icons.folder_copy_outlined),
            selectedIcon: const Icon(Icons.folder_copy),
            label: l(context).tabProjects,
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: const Icon(Icons.settings),
            label: l(context).tabSettings,
          ),
        ],
      ),
      ),
    );
  }
}

class _ViewInsetsFreezer extends StatelessWidget {
  const _ViewInsetsFreezer({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final parent = MediaQuery.of(context);
    return MediaQuery(
      data: parent.copyWith(
        viewInsets: EdgeInsets.zero,
        padding: parent.viewPadding,
        viewPadding: parent.viewPadding,
      ),
      child: child,
    );
  }
}

/// Plain-styled banner shown when the watchdog SSE detects a network
/// disconnect. Uses surfaceContainerHighest (theme-aware, not error style).
class _DisconnectBanner extends StatelessWidget {
  const _DisconnectBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: scheme.surfaceContainerHighest,
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.outline,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            l(context).disconnectBanner,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
