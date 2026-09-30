import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

ProjectModel _project(String id) => ProjectModel(
      id: id,
      canonical: '/repo/$id',
      vcs: 'git',
    );

SessionModel _session(String id, String projectId, String dir) => SessionModel(
      id: id,
      projectID: projectId,
      directory: dir,
      title: id,
      created: 0,
      updated: 1000,
    );

class _WorktreesMockClient extends OpencodeClient {
  final Map<String, List<String>> byProject;
  final Set<String> failingProjects;
  final List<String> calls = [];
  final List<String> sessionCalls = [];

  _WorktreesMockClient({
    this.byProject = const {},
    this.failingProjects = const {},
  }) : super(_noopDio());

  @override
  Future<List<WorktreeInfo>> worktrees(String projectID) async {
    calls.add(projectID);
    if (failingProjects.contains(projectID)) {
      throw Exception('server error');
    }
    return (byProject[projectID] ?? const [])
        .map((d) => WorktreeInfo(directory: d))
        .toList();
  }

  @override
  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = 1000}) async {
    sessionCalls.add(directory);
    return [
      SessionModel(
        id: 'ses-${directory.split('/').last}',
        projectID: 'p1',
        directory: directory,
        title: directory,
        created: 0,
        updated: 1000,
      ),
    ];
  }
}

class _UpdateProjectMockClient extends _WorktreesMockClient {
  ProjectModel? returned;

  _UpdateProjectMockClient({super.byProject, super.failingProjects})
      : super();

  @override
  Future<ProjectModel> updateProject(
    String projectId, {
    String? canonical,
    String? name,
    bool updateIcon = false,
    String? iconUrl,
    String? iconOverride,
    String? iconColor,
  }) async =>
      returned!;
}

void main() {
  group('ServerStore._reconcileWorktrees', () {
    test('replaces the cached list with the remote worktree list', () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/real', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting(
          'p1', ['/repo/p1', '/wt/real', '/wt/ghost']);
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/real']);
    });

    test('keeps cached worktrees when the fetch fails (fail-open)', () async {
      final client = _WorktreesMockClient(
        failingProjects: {'p1'},
      );
      final store = ServerStore()..client = client;
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/ghost']);
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/ghost']);
    });

    test('keeps cached worktrees on a 200-empty list (fail-open)', () async {
      final client = _WorktreesMockClient(byProject: {'p1': []});
      final store = ServerStore()..client = client;
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/real']);
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/real']);
    });

    test('skips projects without cached worktrees or workspace usage',
        () async {
      final client = _WorktreesMockClient();
      final store = ServerStore()..client = client;
      await store.reconcileWorktreesForTesting([
        _project('p1'),
        ProjectModel(id: 'global', canonical: '/'),
      ]);
      expect(store.worktreeDirsOf('p1'), isEmpty);
      expect(client.calls, isEmpty);
    });

    test('queries worktree list for workspace-enabled projects without '
        'cached worktrees', () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/remote', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1'), _project('p2')]);
      store.setWorkspaceEnabled('p1', true);
      await store.reconcileWorktreesForTesting([
        _project('p1'),
        _project('p2'),
      ]);
      expect(client.calls, ['p1']);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/remote']);
      expect(store.worktreeDirsOf('p2'), isEmpty);
    });

    test('queries worktree list for projects with sessions outside the '
        'canonical directory', () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/remote', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.upsertSessionForTesting(_session('s1', 'p1', '/wt/remote'));
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(client.calls, ['p1']);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/remote']);
    });

    test('injected sessions drive the predicate without store state',
        () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/remote', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      await store.reconcileWorktreesForTesting(
        [_project('p1')],
        sessions: [_session('s1', 'p1', '/wt/remote')],
      );
      expect(client.calls, ['p1']);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/remote']);
    });

    test('adopts remote worktrees missing from the local cache', () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/calm', '/wt/b', '/wt/a', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/calm']);
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(store.worktreeDirsOf('p1'),
          ['/repo/p1', '/wt/a', '/wt/b', '/wt/calm']);
    });

    test('all-ghost cache ends up with only the remote main worktree',
        () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting('p1', ['/wt/ghost-a', '/wt/ghost-b']);
      await store.reconcileWorktreesForTesting([_project('p1')]);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1']);
    });

    test('reconciles projects independently and in parallel', () async {
      final client = _WorktreesMockClient(
        byProject: {
          'p1': ['/repo/p1'],
        },
        failingProjects: {'p2'},
      );
      final store = ServerStore()..client = client;
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/ghost']);
      store.setWorktreeDirsForTesting('p2', ['/repo/p2', '/wt/other']);
      await store.reconcileWorktreesForTesting([
        _project('p1'),
        _project('p2'),
      ]);
      expect(store.worktreeDirsOf('p1'), ['/repo/p1']);
      expect(store.worktreeDirsOf('p2'), ['/repo/p2', '/wt/other']);
      expect(client.calls, containsAll(['p1', 'p2']));
    });
  });

  group('ServerStore.updateProject', () {
    test('reconciles cached worktrees after a PATCH response', () async {
      final client = _UpdateProjectMockClient(byProject: {
        'p1': ['/wt/real', '/repo/p1'],
      });
      client.returned = ProjectModel(
        id: 'p1',
        canonical: '/repo/p1',
        vcs: 'git',
        name: 'renamed',
      );
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting(
          'p1', ['/repo/p1', '/wt/real', '/wt/ghost']);
      final updated = await store.updateProject('p1', name: 'renamed');
      expect(updated.name, 'renamed');
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/real']);
    });

    test('keeps cached worktrees when the fetch fails', () async {
      final client = _UpdateProjectMockClient(
        failingProjects: {'p1'},
      );
      client.returned = _project('p1');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/ghost']);
      await store.updateProject('p1', name: 'renamed');
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/ghost']);
    });
  });

  group('ServerStore.reconcileProjectWorktrees', () {
    test('merges fresh remote worktrees into the cache', () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/calm', '/wt/a', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting('p1', ['/repo/p1', '/wt/calm']);
      await store.reconcileProjectWorktrees('p1');
      expect(store.worktreeDirsOf('p1'), ['/repo/p1', '/wt/a', '/wt/calm']);
    });

    test('stores remote worktrees oldest-first (server lists newest-first)',
        () async {
      final client = _WorktreesMockClient(byProject: {
        'p1': ['/wt/newest', '/wt/mid', '/wt/oldest', '/repo/p1'],
      });
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      await store.reconcileProjectWorktrees('p1');
      expect(store.worktreeDirsOf('p1'),
          ['/repo/p1', '/wt/oldest', '/wt/mid', '/wt/newest']);
    });

    test('keeps cached worktrees when the fetch fails', () async {
      final client = _WorktreesMockClient(failingProjects: {'p1'});
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project('p1')]);
      store.setWorktreeDirsForTesting('p1', ['/repo/p1']);
      await store.reconcileProjectWorktrees('p1');
      expect(store.worktreeDirsOf('p1'), ['/repo/p1']);
    });

    test('no-ops for unknown projects', () async {
      final client = _WorktreesMockClient();
      final store = ServerStore()..client = client;
      await store.reconcileProjectWorktrees('missing');
      expect(client.calls, isEmpty);
    });
  });

  group('ServerStore._detectGhostSessionIds', () {
    final projects = [_project('p1')];
    final map = {
      '/repo/p1': ['/repo/p1'],
    };

    test('flags a dropped session whose directory is unreachable', () {
      final store = ServerStore();
      final ids = store.detectGhostSessionIdsForTesting(
        [_session('s1', 'p1', '/wt/ghost')],
        [],
        projects,
        map,
      );
      expect(ids, {'s1'});
    });

    test('keeps sessions still present in the fresh list', () {
      final store = ServerStore();
      final ids = store.detectGhostSessionIdsForTesting(
        [_session('s1', 'p1', '/wt/ghost')],
        [_session('s1', 'p1', '/wt/ghost')],
        projects,
        map,
      );
      expect(ids, isEmpty);
    });

    test('keeps dropped sessions in still-reachable directories', () {
      final store = ServerStore();
      final ids = store.detectGhostSessionIdsForTesting(
        [
          _session('s1', 'p1', '/repo/p1'),
          _session('s2', 'p1', '/wt/real'),
        ],
        [],
        [_project('p1')],
        {
          '/repo/p1': ['/repo/p1', '/wt/real'],
        },
      );
      expect(ids, isEmpty);
    });

    test('fail-open on empty or missing worktree list', () {
      final store = ServerStore();
      expect(
        store.detectGhostSessionIdsForTesting(
          [_session('s1', 'p1', '/wt/ghost')],
          [],
          projects,
          {'/repo/p1': []},
        ),
        isEmpty,
      );
      expect(
        store.detectGhostSessionIdsForTesting(
          [_session('s1', 'p1', '/wt/ghost')],
          [],
          projects,
          {},
        ),
        isEmpty,
      );
    });

    test('skips global sessions, unknown projects, empty directories', () {
      final store = ServerStore();
      final ids = store.detectGhostSessionIdsForTesting(
        [
          _session('s1', 'global', '/wt/ghost'),
          _session('s2', 'unknown', '/wt/ghost'),
          _session('s3', 'p1', ''),
        ],
        [],
        [ProjectModel(id: 'global', canonical: '/'), ...projects],
        map,
      );
      expect(ids, isEmpty);
    });
  });

  group('ConversationStore.markWorkspaceMissing', () {
    test('sets the flag, settles busy status, and notifies', () {
      final conv = ConversationStore('s1', OpencodeClient(_noopDio()));
      conv.setStatus('busy');
      var notifies = 0;
      conv.addListener(() => notifies++);
      expect(conv.workspaceMissing, isFalse);
      conv.markWorkspaceMissing();
      expect(conv.workspaceMissing, isTrue);
      expect(conv.status, 'idle');
      expect(notifies, 2); // busy→idle + flag
      conv.markWorkspaceMissing();
      expect(notifies, 2);
    });

    test('clearWorkspaceMissing recovers and notifies once', () {
      final conv = ConversationStore('s1', OpencodeClient(_noopDio()));
      conv.markWorkspaceMissing();
      var notifies = 0;
      conv.addListener(() => notifies++);
      conv.clearWorkspaceMissing();
      expect(conv.workspaceMissing, isFalse);
      expect(notifies, 1);
      conv.clearWorkspaceMissing();
      expect(notifies, 1);
    });
  });

  group('ghost tracking survives conversation eviction', () {
    test('ensureConversation re-applies the flag for a tracked ghost', () {
      final store = ServerStore()..client = OpencodeClient(_noopDio());
      store.upsertSessionForTesting(_session('s1', 'p1', '/wt/ghost'));
      store.markGhostSessionsForTesting({'s1'});
      final conv = store.ensureConversation('s1');
      expect(conv, isNotNull);
      expect(conv!.workspaceMissing, isTrue);
      expect(conv.status, 'idle');
    });

    test('recovered session is no longer re-flagged', () {
      final store = ServerStore()..client = OpencodeClient(_noopDio());
      store.upsertSessionForTesting(_session('s1', 'p1', '/wt/ghost'));
      store.markGhostSessionsForTesting({'s1'});
      store.unghostRecoveredForTesting([_session('s1', 'p1', '/wt/ghost')]);
      final conv = store.ensureConversation('s1');
      expect(conv, isNotNull);
      expect(conv!.workspaceMissing, isFalse);
    });
  });
}
