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
const _sandboxDir = '/repo/.worktrees/feature';
const _projectId = 'p1';

ProjectModel _project({
  List<String> sandboxes = const [],
}) =>
    ProjectModel(
      id: _projectId,
      worktree: _mainDir,
      vcs: 'git',
      sandboxes: sandboxes,
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
  int removeCalls = 0;
  String? lastDirectory;
  String? lastWorktreeDir;
  List<SessionModel> directorySessions = const [];
  final List<String> archivedIds = [];
  final List<String> callOrder = [];

  _RemoveWorktreeMockClient() : super(_noopDio());

  @override
  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = 1000}) async {
    callOrder.add('list');
    return directorySessions;
  }

  @override
  Future<void> archive(String sessionId,
      {String? directory, int? archived}) async {
    callOrder.add('archive:$sessionId');
    archivedIds.add(sessionId);
  }

  @override
  Future<void> removeWorktree(String directory,
      {required String worktreeDir}) async {
    callOrder.add('remove');
    removeCalls++;
    lastDirectory = directory;
    lastWorktreeDir = worktreeDir;
    if (failRemove) throw Exception('server error');
  }
}

void main() {
  group('ServerStore.removeWorktree', () {
    test('removes sandbox from sandboxes and drops its sessions', () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project(sandboxes: [_sandboxDir])]);
      store.upsertSessionForTesting(_session('main', _mainDir));
      store.upsertSessionForTesting(_session('sb1', _sandboxDir));
      store.upsertSessionForTesting(_session('sb2', _sandboxDir));

      await store.removeWorktree(_mainDir, worktreeDir: _sandboxDir);

      expect(client.removeCalls, 1);
      expect(client.lastDirectory, _mainDir);
      expect(client.lastWorktreeDir, _sandboxDir);

      final project = store.projectOf(_projectId)!;
      expect(project.sandboxes, isEmpty);

      final dirs = store.sessions.map((s) => s.directory).toSet();
      expect(dirs, {_mainDir});
      expect(store.sessions.any((s) => s.id == 'sb1'), isFalse);
      expect(store.sessions.any((s) => s.id == 'sb2'), isFalse);
      expect(store.sessions.any((s) => s.id == 'main'), isTrue);
    });

    test('cleans up preview and status caches for removed sessions', () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project(sandboxes: [_sandboxDir])]);
      store.upsertSessionForTesting(_session('sb1', _sandboxDir));

      store.ensureConversation('sb1');
      expect(store.conversationForRead('sb1'), isNotNull);

      await store.removeWorktree(_mainDir, worktreeDir: _sandboxDir);

      expect(store.conversationForRead('sb1'), isNull);
    });

    test('succeeds when project not found (no sandbox update, still cleans sessions)',
        () async {
      final client = _RemoveWorktreeMockClient();
      final store = ServerStore()..client = client;
      // No project seeded — _projects is empty.
      store.upsertSessionForTesting(_session('sb1', _sandboxDir));

      await store.removeWorktree(_mainDir, worktreeDir: _sandboxDir);

      expect(client.removeCalls, 1);
      expect(store.sessions.any((s) => s.directory == _sandboxDir), isFalse);
    });

    test('throws OperationException when API fails and does not mutate state',
        () async {
      final client = _RemoveWorktreeMockClient()..failRemove = true;
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project(sandboxes: [_sandboxDir])]);
      store.upsertSessionForTesting(_session('sb1', _sandboxDir));

      expect(
        () => store.removeWorktree(_mainDir, worktreeDir: _sandboxDir),
        throwsA(isA<OperationException>()),
      );

      // Give the thrown future a chance to settle.
      await Future.delayed(Duration.zero);

      expect(store.projectOf(_projectId)!.sandboxes, [_sandboxDir]);
      expect(store.sessions.any((s) => s.id == 'sb1'), isTrue);
    });

    test('archives worktree sessions before deleting the worktree', () async {
      final client = _RemoveWorktreeMockClient()
        ..directorySessions = [
          _session('sb1', _sandboxDir),
          _session('sb2', _sandboxDir),
        ];
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project(sandboxes: [_sandboxDir])]);

      await store.removeWorktree(_mainDir, worktreeDir: _sandboxDir);

      expect(client.archivedIds, containsAll(['sb1', 'sb2']));
      expect(client.callOrder.first, 'list');
      expect(client.callOrder.last, 'remove');
      expect(client.callOrder.indexOf('remove'),
          greaterThan(client.callOrder.indexOf('archive:sb1')));
      expect(client.callOrder.indexOf('remove'),
          greaterThan(client.callOrder.indexOf('archive:sb2')));
    });

    test('does not re-archive already archived sessions', () async {
      final client = _RemoveWorktreeMockClient()
        ..directorySessions = [
          _session('sb1', _sandboxDir),
          _session('sb2', _sandboxDir, archived: 1234),
        ];
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project(sandboxes: [_sandboxDir])]);

      await store.removeWorktree(_mainDir, worktreeDir: _sandboxDir);

      expect(client.archivedIds, ['sb1']);
      expect(client.removeCalls, 1);
    });

    test('throws KnownError when client is null', () async {
      final store = ServerStore();

      expect(
        () => store.removeWorktree(_mainDir, worktreeDir: _sandboxDir),
        throwsA(isA<KnownError>()),
      );
    });
  });
}
