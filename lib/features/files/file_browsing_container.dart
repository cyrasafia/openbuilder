import 'dart:collection';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/attachments/file_ref.dart';
import '../../core/session/file_browsing_store.dart';
import '../../ui/l10n_ext.dart';
import 'file_list_screen.dart';
import 'file_view_screen.dart';

PageRouteBuilder<T> slideLeftRoute<T>(Widget child, {String? name}) {
  return PageRouteBuilder<T>(
    settings: RouteSettings(name: name),
    transitionDuration: const Duration(milliseconds: 300),
    pageBuilder: (_, _, _) => child,
    transitionsBuilder: (_, animation, _, child) => SlideTransition(
      position: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ).drive(Tween(begin: const Offset(1, 0), end: Offset.zero)),
      child: child,
    ),
  );
}

class FileBrowsingContainer extends StatefulWidget {
  final String sessionId;
  final String? directory;
  final FileBrowsingSnapshot? initial;
  const FileBrowsingContainer({
    super.key,
    required this.sessionId,
    this.directory,
    this.initial,
  });

  static FileBrowsingContainerState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<FileBrowsingContainerState>();

  @override
  State<FileBrowsingContainer> createState() => FileBrowsingContainerState();
}

class FileBrowsingContainerState extends State<FileBrowsingContainer> {
  static String fileRouteName(String path) => 'file:$path';

  final _navKey = GlobalKey<NavigatorState>();
  final LinkedHashMap<Object, void Function()> _collectors = LinkedHashMap();
  final Map<String, Route<dynamic>> _fileRoutes = {};
  final Map<String, OpenFileEntry Function()> _fileEntryGetters = {};
  final _FileRouteObserver _routeObserver = _FileRouteObserver();
  bool Function()? _backInterceptor;

  /// Whether this container's own (root) route transition has completed.
  /// Restore/peek flows create the inner file routes as un-animated initial
  /// routes, so the real animation window is the root route's slide-up —
  /// inner screens gate their content mount on this notifier to keep heavy
  /// first-content frames out of that window.
  final ValueNotifier<bool> transitionDone = ValueNotifier<bool>(false);
  Animation<double>? _rootAnimation;

  void _onRootAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _rootAnimation?.removeStatusListener(_onRootAnimationStatus);
    _rootAnimation = null;
    transitionDone.value = true;
  }

  void _onRouteGone(Route<dynamic> route) {
    _fileRoutes.removeWhere((_, r) => identical(r, route));
  }

  @override
  void initState() {
    super.initState();
    _routeObserver.onGone = _onRouteGone;
    serverStore.fileBrowsing.registerListAnchor(
      widget.sessionId,
      widget.directory,
    );
    serverStore.fileBrowsing.registerContainer(
      widget.sessionId,
      widget.directory,
      this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_rootAnimation == null && !transitionDone.value) {
      _tryInstallRootAnimationGate();
    }
  }

  void _tryInstallRootAnimationGate() {
    if (!mounted || transitionDone.value || _rootAnimation != null) return;
    final anim = ModalRoute.of(context)?.animation;
    if (anim is ProxyAnimation &&
        identical(anim.parent, kAlwaysCompleteAnimation)) {
      // Placeholder before the route's real controller attaches (declarative
      // go_router pages); reports completed forever and would open the gate
      // instantly. Retry after this frame.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _tryInstallRootAnimationGate(),
      );
      return;
    }
    if (anim == null || anim.status == AnimationStatus.completed) {
      transitionDone.value = true;
      return;
    }
    _rootAnimation = anim;
    anim.addStatusListener(_onRootAnimationStatus);
    // Cover the case where the animation completed before the listener was
    // installed (placeholder retry costs a frame).
    if (anim.status == AnimationStatus.completed) {
      _onRootAnimationStatus(AnimationStatus.completed);
    }
  }

  @override
  void dispose() {
    _rootAnimation?.removeStatusListener(_onRootAnimationStatus);
    transitionDone.dispose();
    serverStore.fileBrowsing.unregisterListAnchor(
      widget.sessionId,
      widget.directory,
    );
    serverStore.fileBrowsing.unregisterContainer(
      widget.sessionId,
      widget.directory,
      this,
    );
    super.dispose();
  }

  void registerCollector(Object key, void Function() collect) {
    _collectors[key] = collect;
  }

  void unregisterCollector(Object key) {
    _collectors.remove(key);
  }

  void registerBackInterceptor(bool Function() interceptor) {
    _backInterceptor = interceptor;
  }

  void unregisterBackInterceptor(bool Function() interceptor) {
    if (_backInterceptor == interceptor) _backInterceptor = null;
  }

  void registerFileEntry(String path, OpenFileEntry Function() getter) {
    _fileEntryGetters[path] = getter;
  }

  void unregisterFileEntry(String path, OpenFileEntry Function() getter) {
    if (_fileEntryGetters[path] == getter) _fileEntryGetters.remove(path);
  }

  OpenFileEntry? _carryEntry(String path) => _fileEntryGetters[path]?.call();

  void openFile(String path, {int? initialLine, bool mdShowSource = false}) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    final existing = _fileRoutes[path];
    OpenFileEntry? carry;
    if (existing != null) {
      carry = _carryEntry(path);
      nav.removeRoute(existing);
    }
    final forceSource = initialLine != null || mdShowSource;
    final route = slideLeftRoute(
      FileViewScreen(
        sessionId: widget.sessionId,
        path: path,
        directory: widget.directory,
        restore: forceSource
            ? OpenFileEntry(
                path: path,
                scrollOffset: 0,
                wrap: false,
                mdShowSource: true,
                initialLine: initialLine,
              )
            : carry,
      ),
      name: fileRouteName(path),
    );
    _fileRoutes[path] = route;
    nav.push(route);
  }

  bool get _peek {
    final snap = widget.initial;
    return snap != null && snap.peek && snap.openFiles.isNotEmpty;
  }

  void collapse() {
    final store = serverStore.fileBrowsing;
    store.beginCollapse(widget.sessionId, widget.directory);
    for (final collect in _collectors.values.toList().reversed) {
      collect();
    }
    store.endCollapse(widget.sessionId, widget.directory);
    Navigator.of(context, rootNavigator: true).pop();
  }

  void applyReference(FileRef ref) {
    serverStore.fileBrowsing.dispatchReference(widget.sessionId, ref);
    collapse();
  }

  void handleBack() {
    final nav = _navKey.currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    if (_backInterceptor?.call() ?? false) return;
    if (!mounted) return;
    if (!_peek) {
      serverStore.fileBrowsing.clearSnapshot(widget.sessionId, widget.directory);
    }
    Navigator.of(context, rootNavigator: true).pop();
  }

  List<Route<dynamic>> _initialRoutes() {
    final snap = widget.initial;
    final openFiles = snap?.openFiles ?? const <OpenFileEntry>[];
    final routes = <Route<dynamic>>[];
    if (!_peek) {
      routes.add(
        slideLeftRoute(
          FileListScreen(
            sessionId: widget.sessionId,
            directory: widget.directory,
            initialPath: snap?.listPath,
            restore: snap == null
                ? null
                : FileListRestore(
                    scrollOffset: snap.listScrollOffset,
                    searchQuery: snap.searchQuery,
                    searchExpanded: snap.searchExpanded,
                  ),
          ),
        ),
      );
    }
    for (final e in openFiles) {
      final route = slideLeftRoute(
        FileViewScreen(
          sessionId: widget.sessionId,
          path: e.path,
          directory: widget.directory,
          restore: e,
        ),
        name: fileRouteName(e.path),
      );
      _fileRoutes[e.path] = route;
      routes.add(route);
    }
    return routes;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) handleBack();
      },
      child: Navigator(
        key: _navKey,
        observers: [_routeObserver],
        onGenerateInitialRoutes: (_, _) => _initialRoutes(),
        onGenerateRoute: (_) => null,
      ),
    );
  }
}

class _FileRouteObserver extends NavigatorObserver {
  void Function(Route<dynamic> route)? onGone;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onGone?.call(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    onGone?.call(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) onGone?.call(oldRoute);
  }
}

/// 文件容器统一收起按钮：置于 AppBar `actions` 末尾，以竖分隔线
/// 与其它操作按钮分离。点击触发 [FileBrowsingContainerState.collapse]。
class FileCollapseAction extends StatelessWidget {
  const FileCollapseAction({super.key});

  @override
  Widget build(BuildContext context) {
    final container = FileBrowsingContainer.maybeOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: VerticalDivider(width: 1),
        ),
        IconButton(
          icon: const Icon(Icons.unfold_less),
          tooltip: l(context).fileCollapse,
          onPressed: container?.collapse,
        ),
      ],
    );
  }
}
