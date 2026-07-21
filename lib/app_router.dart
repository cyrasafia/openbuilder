import 'package:go_router/go_router.dart';

import 'core/connection/connection_store.dart';
import 'features/conversation/conversation_screen.dart';
import 'features/files/diff_detail_screen.dart';
import 'features/files/diff_list_screen.dart';
import 'features/files/file_list_screen.dart';
import 'features/files/file_view_screen.dart';
import 'features/models/model_management_screen.dart';
import 'features/projects/project_detail_screen.dart';
import 'features/servers/server_form_screen.dart';
import 'features/servers/servers_screen.dart';
import 'features/servers/welcome_screen.dart';
import 'features/settings/settings_tab.dart';
import 'features/shell/main_shell.dart';
import 'features/shell/projects_tab.dart';
import 'features/shell/sessions_tab.dart';
import 'features/shell/swipeable_shell_container.dart';

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
        builder: (_, s) => DiffDetailScreen(
          sessionId: s.pathParameters['id']!,
          path: s.uri.queryParameters['path'] ?? '',
          directory: s.uri.queryParameters['directory'],
        ),
      ),
      GoRoute(
        path: '/session/:id/files',
        builder: (_, s) => FileListScreen(
          sessionId: s.pathParameters['id']!,
          directory: s.uri.queryParameters['directory'],
          initialPath: s.uri.queryParameters['path'],
        ),
      ),
      GoRoute(
        path: '/session/:id/file',
        builder: (_, s) => FileViewScreen(
          sessionId: s.pathParameters['id']!,
          path: s.uri.queryParameters['path'] ?? '',
          directory: s.uri.queryParameters['directory'],
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
