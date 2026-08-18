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

ProjectModel _project(String id, List<String> sandboxes) => ProjectModel(
      id: id,
      worktree: '/repo/$id',
      vcs: 'git',
      sandboxes: sandboxes,
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
  final Map<String, List<String>> byDirectory;
  final Set<String> failingDirectories;
  final List<String> calls = [];
  final List<String> sessionCalls = [];

  _WorktreesMockClient({
    this.byDirectory = const {},
    this.failingDirectories = const {},
  }) : super(_noopDio());

  @override
  Future<List<String>> worktrees(String directory) async {
    calls.add(directory);
    if (failingDirectories.contains(directory)) {
      throw Exception('server error');
    }
    return byDirectory[directory] ?? const [];
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

  _UpdateProjectMockClient({super.byDirectory, super.failingDirectories})
      : super();

  @override
  Future<ProjectModel> updateProject(
    String projectId, {
    String? name,
    bool updateIcon = false,
    String? iconUrl,
    String? iconOverride,
    String? iconColor,
  }) async =>
      returned!;
}

void main() {
  group('ServerStore._reconcileSandboxes', () {
    test('drops ghost sandboxes missing from /experimental/worktree',
        () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/repo/p1', '/wt/real'],
      });
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/real', '/wt/ghost']),
      ]);
      expect(out.single.sandboxes, ['/repo/p1', '/wt/real']);
    });

    test('keeps sandboxes untouched when the fetch fails (fail-open)',
        () async {
      final client = _WorktreesMockClient(
        failingDirectories: {'/repo/p1'},
      );
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/ghost']),
      ]);
      expect(out.single.sandboxes, ['/repo/p1', '/wt/ghost']);
    });

    test('keeps sandboxes untouched on a 200-empty list (fail-open)',
        () async {
      final client = _WorktreesMockClient(byDirectory: {'/repo/p1': []});
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/real']),
      ]);
      expect(out.single.sandboxes, ['/repo/p1', '/wt/real']);
    });

    test('always keeps the main worktree even if the list omits it',
        () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/wt/other'],
      });
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/ghost']),
      ]);
      expect(out.single.sandboxes, ['/repo/p1']);
    });

    test('skips projects without sandboxes', () async {
      final client = _WorktreesMockClient();
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', []),
        ProjectModel(id: 'global', worktree: '/'),
      ]);
      expect(out[0].sandboxes, isEmpty);
      expect(out[1].sandboxes, isEmpty);
      expect(client.calls, isEmpty);
    });

    test('all-ghost project ends up with empty sandboxes', () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/repo/p1'],
      });
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/wt/ghost-a', '/wt/ghost-b']),
      ]);
      expect(out.single.sandboxes, isEmpty);
    });

    test('preserves other project fields when filtering', () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/wt/real'],
      });
      final store = ServerStore()..client = client;
      final p = ProjectModel(
        id: 'p1',
        worktree: '/repo/p1',
        vcs: 'git',
        name: 'renamed',
        commands: const ProjectCommands(start: 'make start'),
        sandboxes: const ['/wt/real', '/wt/ghost'],
        created: 42,
      );
      final out = await store.reconcileSandboxesForTesting([p]);
      final f = out.single;
      expect(f.sandboxes, ['/wt/real']);
      expect(f.name, 'renamed');
      expect(f.commands?.start, 'make start');
      expect(f.created, 42);
      expect(f.vcs, 'git');
    });

    test('filters projects independently and in parallel', () async {
      final client = _WorktreesMockClient(
        byDirectory: {
          '/repo/p1': ['/repo/p1'],
        },
        failingDirectories: {'/repo/p2'},
      );
      final store = ServerStore()..client = client;
      final out = await store.reconcileSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/ghost']),
        _project('p2', ['/repo/p2', '/wt/other']),
      ]);
      expect(out[0].sandboxes, ['/repo/p1']);
      expect(out[1].sandboxes, ['/repo/p2', '/wt/other']);
      expect(client.calls, containsAll(['/repo/p1', '/repo/p2']));
    });
  });

  group('ServerStore.updateProject', () {
    test('filters ghosts out of the PATCH response before storing', () async {
      final client = _UpdateProjectMockClient(byDirectory: {
        '/repo/p1': ['/repo/p1', '/wt/real'],
      });
      client.returned = _project('p1', ['/repo/p1', '/wt/real', '/wt/ghost']);
      final store = ServerStore()
        ..client = client
        ..setProjectsForTesting([_project('p1', ['/wt/ghost'])]);
      final updated = await store.updateProject('p1', name: 'renamed');
      expect(updated.sandboxes, ['/repo/p1', '/wt/real']);
      expect(store.projectOf('p1')?.sandboxes, ['/repo/p1', '/wt/real']);
    });

    test('keeps raw sandboxes when the worktrees fetch fails', () async {
      final client = _UpdateProjectMockClient(
        failingDirectories: {'/repo/p1'},
      );
      client.returned = _project('p1', ['/repo/p1', '/wt/ghost']);
      final store = ServerStore()..client = client;
      final updated = await store.updateProject('p1', name: 'renamed');
      expect(updated.sandboxes, ['/repo/p1', '/wt/ghost']);
    });
  });

  group('ServerStore._sessionsForProject worktreesByDir reuse', () {
    test('uses cached worktrees without re-fetching', () async {
      final client = _WorktreesMockClient();
      final store = ServerStore()..client = client;
      final sessions = await store.sessionsForProjectForTesting(
        _project('p1', ['/repo/p1', '/wt/real']),
        {
          '/repo/p1': ['/wt/real'],
        },
      );
      expect(client.calls, isEmpty);
      expect(client.sessionCalls, ['/repo/p1', '/wt/real']);
      expect(sessions.map((s) => s.directory), ['/repo/p1', '/wt/real']);
    });

    test('falls back to fetching when the cache misses', () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/wt/real'],
      });
      final store = ServerStore()..client = client;
      final sessions = await store.sessionsForProjectForTesting(
        _project('p1', ['/repo/p1', '/wt/real']),
      );
      expect(client.calls, ['/repo/p1']);
      expect(client.sessionCalls, ['/repo/p1', '/wt/real']);
      expect(sessions.map((s) => s.directory), ['/repo/p1', '/wt/real']);
    });

    test('records cache-miss fetches back into the map', () async {
      final client = _WorktreesMockClient(byDirectory: {
        '/repo/p1': ['/wt/real'],
      });
      final store = ServerStore()..client = client;
      final map = <String, List<String>>{};
      await store.sessionsForProjectForTesting(
        _project('p1', ['/repo/p1', '/wt/real']),
        map,
      );
      expect(map['/repo/p1'], ['/wt/real']);
    });
  });

  group('ServerStore._filterSandboxes (pre-fetched map)', () {
    test('filters ghosts, keeps main, skips missing/empty entries', () {
      final store = ServerStore();
      final out = store.filterSandboxesForTesting([
        _project('p1', ['/repo/p1', '/wt/real', '/wt/ghost']),
        _project('p2', ['/repo/p2', '/wt/ghost']),
        _project('p3', ['/repo/p3', '/wt/ghost']),
      ], {
        '/repo/p1': ['/repo/p1', '/wt/real'],
        '/repo/p2': [],
        // p3 missing entirely
      });
      expect(out[0].sandboxes, ['/repo/p1', '/wt/real']);
      expect(out[1].sandboxes, ['/repo/p2', '/wt/ghost']);
      expect(out[2].sandboxes, ['/repo/p3', '/wt/ghost']);
    });
  });

  group('ServerStore._detectGhostSessionIds', () {
    final projects = [_project('p1', ['/repo/p1', '/wt/ghost'])];
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
        [_project('p1', [])],
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
        [ProjectModel(id: 'global', worktree: '/'), ...projects],
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
