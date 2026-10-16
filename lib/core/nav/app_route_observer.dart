import 'package:flutter/widgets.dart';

/// 全局页面可见性源：维护根导航器上的路由栈，向订阅者广播「是否被不透明路由盖住」。
/// 判据只看 **不透明（opaque）** 路由：bottom sheet / dialog / popup menu 盖在页面上时，
/// 页面仍然可见（用户还在看它）。与 Flutter 自身的 obscured 语义对齐
/// （`TransitionRoute.opaque`：过渡完成后被遮挡的路由不再构建）。
///
/// 不复用框架的 [RouteObserver]：它按「紧邻下方路由」通知（didPush / didPop 的 previousRoute），
/// 栈 `[页面, 弹层, 不透明页]` 的入栈 / 出栈会漏判——页面被盖住、以及弹层未关时揭开，都收不到回调。
/// 本实现按「上方是否存在不透明路由」求值，通知其下**所有**订阅者。
/// 只服务**根导航器**：本类不区分 navigator，订阅者一律按根栈求值。嵌套 Navigator
/// 内的页面（如文件容器的内层路由）不应订阅本观察者——其宿主容器路由被盖住时会被误判为可见。
///
/// 单例在进程内共享：整棵 Navigator 被拆除（不走 pop / remove）时不发通知，`_stack` 保留陈旧条目。
/// 判定不受影响（陈旧条目恒在目标路由下方）；生产只有一棵常驻导航器。
final AppRouteObserver appRouteObserver = AppRouteObserver();

class AppRouteObserver extends NavigatorObserver {
  final Map<Route<dynamic>, Set<RouteAware>> _subscribers = {};
  final List<Route<dynamic>> _stack = [];
  final Set<Route<dynamic>> _covered = {};

  void subscribe(RouteAware routeAware, Route<dynamic> route) {
    _subscribers.putIfAbsent(route, () => <RouteAware>{}).add(routeAware);
    // 兜底：路由不在栈内时按栈顶记账。生产不会走到（observer 通知先于页面首帧 build），
    // 它服务未注册本观察者的 harness（如各 widget 测试自建 GoRouter）——那类页面因此恒判可见。
    if (!_stack.contains(route)) _stack.add(route);
    if (_isVisible(route)) {
      _covered.remove(route);
      routeAware.didPush();
    } else {
      _covered.add(route);
      routeAware.didPushNext();
    }
  }

  void unsubscribe(RouteAware routeAware) {
    final emptied = <Route<dynamic>>[];
    for (final entry in _subscribers.entries) {
      entry.value.remove(routeAware);
      if (entry.value.isEmpty) emptied.add(entry.key);
    }
    for (final route in emptied) {
      _subscribers.remove(route);
      _covered.remove(route);
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _stack.add(route);
    _recompute();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forget(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forget(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (newRoute == null || oldRoute == null) return;
    final index = _stack.indexOf(oldRoute);
    if (index >= 0) _stack[index] = newRoute;
    final subscribers = _subscribers.remove(oldRoute);
    if (subscribers != null) {
      _subscribers.putIfAbsent(newRoute, () => <RouteAware>{}).addAll(subscribers);
    }
    if (_covered.remove(oldRoute)) _covered.add(newRoute);
    _recompute();
  }

  void _forget(Route<dynamic> route) {
    _stack.remove(route);
    _covered.remove(route);
    final subscribers = _subscribers.remove(route);
    if (subscribers != null) {
      for (final routeAware in subscribers.toList()) {
        routeAware.didPop();
      }
    }
    _recompute();
  }

  void _recompute() {
    for (final entry in _subscribers.entries.toList()) {
      final route = entry.key;
      final visible = _isVisible(route);
      final covered = _covered.contains(route);
      if (visible == !covered) continue;
      if (visible) {
        _covered.remove(route);
        for (final routeAware in entry.value.toList()) {
          routeAware.didPopNext();
        }
      } else {
        _covered.add(route);
        for (final routeAware in entry.value.toList()) {
          routeAware.didPushNext();
        }
      }
    }
  }

  bool _isVisible(Route<dynamic> route) {
    final index = _stack.lastIndexOf(route);
    if (index < 0) return false;
    for (var i = index + 1; i < _stack.length; i++) {
      if (_covers(_stack[i])) return false;
    }
    return true;
  }

  static bool _covers(Route<dynamic> route) =>
      route is TransitionRoute ? route.opaque : true;
}
