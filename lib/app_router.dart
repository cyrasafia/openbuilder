import 'package:go_router/go_router.dart';

import 'core/connection/connection_store.dart';
import 'features/servers/server_form_screen.dart';
import 'features/servers/servers_screen.dart';
import 'features/servers/welcome_screen.dart';
import 'features/settings/settings_tab.dart';
import 'features/shell/main_shell.dart';
import 'features/shell/projects_tab.dart';
import 'features/shell/sessions_tab.dart';

GoRouter buildRouter(ConnectionStore store) {
  return GoRouter(
    refreshListenable: store,
    initialLocation: '/sessions',
    redirect: (context, state) {
      final loc = state.matchedLocation;
      final isPublic = loc == '/welcome' ||
          loc == '/servers/new' ||
          loc.endsWith('/edit');
      if (store.isEmpty && !isPublic) return '/welcome';
      if (!store.isEmpty && loc == '/welcome') return '/sessions';
      return null;
    },
    routes: [
      GoRoute(
        path: '/welcome',
        builder: (_, _) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/servers',
        builder: (_, _) => const ServersScreen(),
      ),
      GoRoute(
        path: '/servers/new',
        builder: (_, _) => const ServerFormScreen(),
      ),
      GoRoute(
        path: '/servers/:id/edit',
        builder: (_, s) => ServerFormScreen(id: s.pathParameters['id']!),
      ),
      StatefulShellRoute.indexedStack(
        builder: (_, _, shell) => MainShell(shell: shell),
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
