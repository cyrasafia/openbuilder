import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'core/connection/connection_profile.dart';
import 'core/connection/connection_store.dart';
import 'core/session/file_browsing_store.dart';
import 'domain/models.dart';
import 'features/conversation/conversation_screen.dart';
import 'features/files/diff_detail_screen.dart';
import 'features/files/diff_list_screen.dart';
import 'features/files/file_browsing_container.dart';
import 'features/models/model_management_screen.dart';
import 'features/projects/project_detail_screen.dart';
import 'features/servers/basic_auth_screen.dart';
import 'features/servers/oauth_login_screen.dart';
import 'features/servers/server_info_screen.dart';
import 'features/servers/servers_screen.dart';
import 'features/servers/welcome_screen.dart';
import 'features/settings/settings_tab.dart';
import 'features/shell/main_shell.dart';
import 'features/shell/projects_tab.dart';
import 'features/shell/sessions_tab.dart';
import 'features/shell/swipeable_shell_container.dart';

CustomTransitionPage<void> _slideUpPage(GoRouterState state, Widget child) {
  return CustomTransitionPage(
    key: state.pageKey,
    child: child,
    transitionsBuilder: (_, animation, _, child) => SlideTransition(
      position: CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      ).drive(Tween(begin: const Offset(0, 1), end: Offset.zero)),
      child: child,
    ),
  );
}

/// go_router re-parses (and thus re-keys) imperative matches on every
/// refresh, so a per-change refreshListenable would remount any pushed page
/// on each store mutation. The redirect only depends on presence
/// (empty <-> non-empty), so gate refreshes on that transition alone.
class _PresenceRefreshListenable extends ChangeNotifier {
  bool _empty;
  final ConnectionStore _store;

  _PresenceRefreshListenable(this._store) : _empty = _store.isEmpty {
    _store.addListener(_onStoreChanged);
  }

  void _onStoreChanged() {
    final empty = _store.isEmpty;
    if (empty != _empty) {
      _empty = empty;
      notifyListeners();
    }
  }
}

/// Pop imperative routes until the server-management list is on top. Falls
/// back to a cold `go` when the stack has no /servers below (not reachable
/// from the current flows, but keeps the exit total).
void popToServerManagement(GoRouter router) {
  while (router.routerDelegate.currentConfiguration.uri.path != '/servers' &&
      router.canPop()) {
    router.pop();
  }
  if (router.routerDelegate.currentConfiguration.uri.path != '/servers') {
    router.go('/servers');
  }
}

GoRouter buildRouter(ConnectionStore store) {
  return GoRouter(
    refreshListenable: _PresenceRefreshListenable(store),
    initialLocation: '/sessions',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final isPublic = loc == '/welcome' ||
          loc == '/servers/new' ||
          loc.endsWith('/edit') ||
          loc.endsWith('/login');
      if (store.isEmpty && !isPublic) return '/welcome';
      if (!store.isEmpty && loc == '/welcome') return '/sessions';
      return null;
    },
    routes: [
      GoRoute(path: '/welcome', builder: (_, _) => const WelcomeScreen()),
      GoRoute(path: '/servers', builder: (_, _) => const ServersScreen()),
      GoRoute(
        path: '/servers/new',
        builder: (_, _) => const ServerInfoScreen(),
      ),
      GoRoute(
        path: '/servers/:id/edit',
        builder: (_, s) => ServerInfoScreen(id: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/servers/:id/login',
        builder: (_, s) {
          final args = s.extra is ServerLoginArgs
              ? s.extra as ServerLoginArgs
              : null;
          final profile =
              args?.profile ?? store.byId(s.pathParameters['id']!);
          if (profile == null) return const ServersScreen();
          switch (profile.authMethod) {
            case AuthMethod.oauth:
              return OAuthLoginScreen(
                profile: profile,
                metadata: args?.metadata,
                newlyAdded: args?.newlyAdded ?? false,
                controller: args?.controller,
              );
            case AuthMethod.basic:
              return BasicAuthScreen(
                profile: profile,
                newlyAdded: args?.newlyAdded ?? false,
              );
            case AuthMethod.none:
              return const ServersScreen();
          }
        },
      ),
      GoRoute(
        path: '/session/:id',
        builder: (_, s) =>
            ConversationScreen(sessionId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/session/:id/diff',
        builder: (_, s) => DiffListScreen(
          sessionId: s.pathParameters['id']!,
          directory: s.uri.queryParameters['directory'],
        ),
      ),
      GoRoute(
        path: '/session/:id/diff/file',
        builder: (_, s) {
          final modeName = s.uri.queryParameters['mode'];
          final mode = DiffMode.values.firstWhere(
            (m) => m.name == modeName,
            orElse: () => DiffMode.uncommitted,
          );
          return DiffDetailScreen(
            sessionId: s.pathParameters['id']!,
            path: s.uri.queryParameters['path'] ?? '',
            directory: s.uri.queryParameters['directory'],
            mode: mode,
            messageID: s.uri.queryParameters['messageID'],
          );
        },
      ),
      GoRoute(
        path: '/session/:id/files',
        pageBuilder: (_, s) => _slideUpPage(
          s,
          FileBrowsingContainer(
            sessionId: s.pathParameters['id']!,
            directory: s.uri.queryParameters['directory'],
            initial: s.extra is FileBrowsingSnapshot
                ? s.extra as FileBrowsingSnapshot
                : null,
          ),
        ),
      ),
      GoRoute(
        path: '/project/:id',
        builder: (_, s) => ProjectDetailScreen(
          projectId: s.pathParameters['id']!,
          directory: s.uri.queryParameters['directory'],
        ),
      ),
      GoRoute(
        path: '/models',
        builder: (_, _) => const ModelManagementScreen(),
      ),
      StatefulShellRoute(
        builder: (_, _, shell) => MainShell(shell: shell),
        navigatorContainerBuilder: (_, navigationShell, children) =>
            SwipeableShellContainer(
              navigationShell: navigationShell,
              children: children,
            ),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/sessions',
                builder: (_, _) => const SessionsTab(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/projects',
                builder: (_, _) => const ProjectsTab(),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                builder: (_, _) => const SettingsTab(),
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
