import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

const _mainDir = '/repo';
const _worktreeDir = '/repo/.worktrees/feature';
const _projectId = 'p1';

ProjectModel _project() => ProjectModel(
      id: _projectId,
      canonical: _mainDir,
      vcs: 'git',
    );

SessionModel _session(String id, String dir,
        {int updated = 1000, int? archived}) =>
    SessionModel(
      id: id,
      projectID: _projectId,
      directory: dir,
      title: id,
      created: 0,
      updated: updated,
      archived: archived,
    );

/// Mock client whose `removeWorktree` outcome is controllable.
class _RemoveWorktreeMockClient extends OpencodeClient {
  bool failRemove = false;
  /// Session ids that should fail DELETE (e.g. 404 race with SSE echo).
  final Set<String> failDeleteIds = {};
  int removeCalls = 0;
  String? lastDirectory;
  String? lastWorktreeDir;
  List<SessionModel> directorySessions = const [];
  final List<String> deletedSessionIds = [];
  final List<String> callOrder = [];

  _RemoveWorktreeMockClient() : super(_noopDio());

  @override
  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = 1000}) async {
    callOrder.add('list');
    return directorySessions;
  }

  @override
  Future<void> deleteSession(String sessionId, {String? directory}) async {
    callOrder.add('delete:$sessionId');
    deletedSessionIds.add(sessionId);
    if (failDeleteIds.contains(sessionId)) {
      throw KnownError(FriendlyErrorKind.notFound);
    }
  }

  @override
  Future<void> removeWorktree(String projectID, String worktreeDir,
      {bool force = false}) async {
    callOrder.add('remove');
    removeCalls++;
    lastDirectory = projectID;
    lastWorktreeDir = worktreeDir;
    if (failRemove) throw Exception('server error');
  }
}

void main() {
  group('ServerStore.removeWorktree', () {
    test('removes the directory from cached worktrees and drops its sessions',
        () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
      store.upsertSessionForTesting(_session('main', _mainDir));
      store.upsertSessionForTesting(_session('sb1', _worktreeDir));
      store.upsertSessionForTesting(_session('sb2', _worktreeDir));

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(client.removeCalls, 1);
      expect(client.lastDirectory, _projectId);
      expect(client.lastWorktreeDir, _worktreeDir);

      final project = store.projectOf(_projectId);
      expect(project, isNotNull);
      expect(store.worktreeDirsOf(_projectId), isEmpty);

      final dirs = store.sessions.map((s) => s.directory).toSet();
      expect(dirs, {_mainDir});
      expect(store.sessions.any((s) => s.id == 'sb1'), isFalse);
      expect(store.sessions.any((s) => s.id == 'sb2'), isFalse);
      expect(store.sessions.any((s) => s.id == 'main'), isTrue);
    });

    test('cleans up preview and status caches for removed sessions', () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
      store.upsertSessionForTesting(_session('sb1', _worktreeDir));

      store.ensureConversation('sb1');
      expect(store.conversationForRead('sb1'), isNotNull);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(store.conversationForRead('sb1'), isNull);
    });

    test('unknown project (canonical not registered) throws instead of guessing',
        () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      // No project seeded — _projects is empty: the v2 worktree API needs
      // projectID, which cannot be resolved from the canonical path.
      store.upsertSessionForTesting(_session('sb1', _worktreeDir));

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<KnownError>()),
      );
      expect(client.removeCalls, 0);
    });

    test('throws OperationException when API fails and does not mutate state',
        () async {
      final client = _RemoveWorktreeMockClient()..failRemove = true;
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
      store.upsertSessionForTesting(_session('sb1', _worktreeDir));

      expect(
        () => store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );

      // Give the thrown future a chance to settle.
      await Future.delayed(Duration.zero);

      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
      expect(store.sessions.any((s) => s.id == 'sb1'), isTrue);
    });

    test('deletes worktree sessions before deleting the worktree', () async {
      final client = _RemoveWorktreeMockClient()
        ..directorySessions = [
          _session('sb1', _worktreeDir),
          _session('sb2', _worktreeDir),
        ];
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(client.deletedSessionIds, containsAll(['sb1', 'sb2']));
      expect(client.callOrder.first, 'list');
      expect(client.callOrder.last, 'remove');
      expect(client.callOrder.indexOf('remove'),
          greaterThan(client.callOrder.indexOf('delete:sb1')));
      expect(client.callOrder.indexOf('remove'),
          greaterThan(client.callOrder.indexOf('delete:sb2')));
    });

    test('deletes all worktree sessions including archived ones', () async {
      final client = _RemoveWorktreeMockClient()
        ..directorySessions = [
          _session('sb1', _worktreeDir),
          _session('sb2', _worktreeDir, archived: 1234),
        ];
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(client.deletedSessionIds, containsAll(['sb1', 'sb2']));
      expect(client.removeCalls, 1);
    });

    test('throws KnownError when client is null', () async {
      final store = ServerStore();

      expect(
        () => store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<KnownError>()),
      );
    });

    test('non-blocking: deleting state set synchronously, cleared on success',
        () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);

      final pending = store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);
      // In-flight: isWorktreeDeleting is true before any await settles.
      expect(store.isWorktreeDeleting(_worktreeDir), isTrue);
      // Re-entry for the same directory is a no-op.
      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);
      expect(client.removeCalls, 0);

      await pending;
      expect(store.isWorktreeDeleting(_worktreeDir), isFalse);
    });

    test('deleting state cleared on failure (retryable)', () async {
      final client = _RemoveWorktreeMockClient()..failRemove = true;
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);

      expect(
        () => store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(store.isWorktreeDeleting(_worktreeDir), isFalse);
    });

    test('best-effort: a 404 on one session delete does not block the rest '
        'nor the worktree removal', () async {
      final client = _RemoveWorktreeMockClient()
        ..directorySessions = [
          _session('sb1', _worktreeDir),
          _session('sb2', _worktreeDir),
          _session('sb3', _worktreeDir),
        ]
        ..failDeleteIds.add('sb2');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
      store.upsertSessionForTesting(_session('sb1', _worktreeDir));
      store.upsertSessionForTesting(_session('sb2', _worktreeDir));
      store.upsertSessionForTesting(_session('sb3', _worktreeDir));

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      // All three DELETEs were attempted; the failed one was swallowed.
      expect(client.deletedSessionIds, containsAll(['sb1', 'sb2', 'sb3']));
      // The worktree removal still ran and local state is fully cleaned.
      expect(client.removeCalls, 1);
      expect(store.worktreeDirsOf(_projectId), isEmpty);
      expect(store.sessions.where((s) => s.directory == _worktreeDir), isEmpty);
      expect(store.isWorktreeDeleting(_worktreeDir), isFalse);
    });
  });
}
