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
  final Set<String> _openPaths = {};
  final Map<String, FileViewJumper> _fileJumpers = {};
  bool Function()? _backInterceptor;

  @override
  void initState() {
    super.initState();
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
  void dispose() {
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

  void registerFile(String path, [FileViewJumper? jumper]) {
    _openPaths.add(path);
    if (jumper != null) _fileJumpers[path] = jumper;
  }

  void unregisterFile(String path) {
    _openPaths.remove(path);
    _fileJumpers.remove(path);
  }

  void openFile(String path, {int? initialLine, bool mdShowSource = false}) {
    final nav = _navKey.currentState;
    if (nav == null) return;
    if (_openPaths.contains(path)) {
      nav.popUntil((r) => r.settings.name == fileRouteName(path) || r.isFirst);
      if (initialLine != null) {
        _fileJumpers[path]?.jumpToLine(initialLine);
      } else if (mdShowSource) {
        _fileJumpers[path]?.forceSourceMode();
      }
      return;
    }
    final forceSource = initialLine != null || mdShowSource;
    nav.push(
      slideLeftRoute(
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
              : null,
        ),
        name: fileRouteName(path),
      ),
    );
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
      routes.add(
        slideLeftRoute(
          FileViewScreen(
            sessionId: widget.sessionId,
            path: e.path,
            directory: widget.directory,
            restore: e,
          ),
          name: fileRouteName(e.path),
        ),
      );
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
        onGenerateInitialRoutes: (_, _) => _initialRoutes(),
        onGenerateRoute: (_) => null,
      ),
    );
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
