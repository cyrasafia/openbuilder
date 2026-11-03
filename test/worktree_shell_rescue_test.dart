import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

const _mainDir = '/repo';
const _worktreeDir = '/repo/.worktrees/feature';
const _projectId = 'p1';

ProjectModel _project() => ProjectModel(
      id: _projectId,
      canonical: _mainDir,
      vcs: 'git',
    );

DioException _unavailableDioError([String dir = _worktreeDir]) =>
    DioException(
      requestOptions: RequestOptions(path: '/api/worktree'),
      response: Response(
        requestOptions: RequestOptions(path: '/api/worktree'),
        statusCode: 400,
        data: {
          '_tag': 'WorktreeError',
          'name': 'WorktreeError',
          'data': {
            'message': 'Worktree directory unavailable: $dir',
            'forceRequired': null,
          },
        },
      ),
    );

/// runShell-level mock: exercises the REAL probeWorktreeHealth mapping.
class _ProbeShellClient extends OpencodeClient {
  ShellRunResult? result;
  Object? error;
  String? lastCommand;
  String? lastCwd;
  int? lastTimeoutMs;

  _ProbeShellClient() : super(_noopDio());

  @override
  Future<ShellRunResult> runShell(String command,
      {String? cwd, int timeoutMs = 15000}) async {
    lastCommand = command;
    lastCwd = cwd;
    lastTimeoutMs = timeoutMs;
    if (error != null) throw error!;
    return result!;
  }
}

/// Full rescue-surface mock for ServerStore.removeWorktree / detectBrokenWorktree.
class _RescueClient extends OpencodeClient {
  Object? removeError;
  WorktreeHealth probeResult = WorktreeHealth.ok;
  int? rmExit = 0;
  Object? rmError;
  Object? refreshError;
  Object? listError;
  List<WorktreeInfo> worktreeRows = const [];
  Object? pruneError;
  Completer<List<SessionModel>>? sessionsGate;

  int probeCalls = 0;
  int refreshCalls = 0;
  int evictCalls = 0;
  final List<(String, String?)> shellCalls = [];

  _RescueClient() : super(_noopDio());

  @override
  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = 1000}) async {
    if (sessionsGate != null) return await sessionsGate!.future;
    return const [];
  }

  @override
  Future<void> deleteSession(String sessionId, {String? directory}) async {}

  @override
  Future<void> removeWorktree(String projectID, String worktreeDir,
      {bool force = false}) async {
    if (removeError != null) throw removeError!;
  }

  @override
  Future<WorktreeHealth> probeWorktreeHealth(String directory) async {
    probeCalls++;
    return probeResult;
  }

  @override
  Future<ShellRunResult> runShell(String command,
      {String? cwd, int timeoutMs = 15000}) async {
    shellCalls.add((command, cwd));
    if (command == 'rm -rf "\$PWD"') {
      if (rmError != null) throw rmError!;
      return ShellRunResult(rmExit, '');
    }
    if (command == 'git worktree prune') {
      if (pruneError != null) throw pruneError!;
      return const ShellRunResult(0, '');
    }
    return const ShellRunResult(0, '');
  }

  @override
  Future<void> refreshWorktrees(String projectID) async {
    refreshCalls++;
    if (refreshError != null) throw refreshError!;
  }

  @override
  Future<List<WorktreeInfo>> worktrees(String projectID) async {
    if (listError != null) throw listError!;
    return worktreeRows;
  }

  @override
  Future<void> evictLocation(String directory) async {
    evictCalls++;
  }
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

ServerStore _storeWith(_RescueClient client) {
  final store = ServerStore()..client = client;
  store.setProjectsForTesting([_project()]);
  store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
  return store;
}

void main() {
  group('OpencodeClient.probeWorktreeHealth (three-state mapping)', () {
    test('exit 0 -> ok, command/cwd/timeout per design §1.2', () async {
      final client = _ProbeShellClient()
        ..result = const ShellRunResult(0, '');
      final health = await client.probeWorktreeHealth(_worktreeDir);
      expect(health, WorktreeHealth.ok);
      expect(client.lastCommand, 'test -e .git');
      expect(client.lastCwd, _worktreeDir);
      expect(client.lastTimeoutMs, 5000);
    });

    test('exit != 0 -> broken (empty shell confirmed)', () async {
      final client = _ProbeShellClient()
        ..result = const ShellRunResult(1, '');
      expect(await client.probeWorktreeHealth(_worktreeDir),
          WorktreeHealth.broken);
    });

    test('exit null -> unknown', () async {
      final client = _ProbeShellClient()..result = const ShellRunResult(null, '');
      expect(await client.probeWorktreeHealth(_worktreeDir),
          WorktreeHealth.unknown);
    });

    test('request failure (500 on vanished dir) -> unknown, does not throw',
        () async {
      final client = _ProbeShellClient()
        ..error = DioException(
          requestOptions: RequestOptions(path: '/api/shell'),
          response: Response(
            requestOptions: RequestOptions(path: '/api/shell'),
            statusCode: 500,
          ),
        );
      expect(await client.probeWorktreeHealth(_worktreeDir),
          WorktreeHealth.unknown);
    });
  });

  group('isWorktreeUnavailableError (discrimination, design §3.1)', () {
    test('matches _tag + message prefix (live 2.0.26 shape)', () {
      expect(isWorktreeUnavailableError(_unavailableDioError()), isTrue);
    });

    test('matches legacy {name, data} shape (dual read)', () {
      final e = DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 400,
          data: {
            'name': 'WorktreeError',
            'data': {'message': 'Worktree directory unavailable: /x'},
          },
        ),
      );
      expect(isWorktreeUnavailableError(e), isTrue);
    });

    test('rejects other WorktreeError messages (e.g. dirty forceRequired)',
        () {
      final e = DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 400,
          data: {
            '_tag': 'WorktreeError',
            'name': 'WorktreeError',
            'data': {
              'message': 'Worktree has unsaved changes',
              'forceRequired': true,
            },
          },
        ),
      );
      expect(isWorktreeUnavailableError(e), isFalse);
    });

    test('prefix is exact up to the colon (no colonless variant matches)',
        () {
      final e = DioException(
        requestOptions: RequestOptions(),
        response: Response(
          requestOptions: RequestOptions(),
          statusCode: 400,
          data: {
            '_tag': 'WorktreeError',
            'name': 'WorktreeError',
            'data': {'message': 'Worktree directory unavailable-ish: /x'},
          },
        ),
      );
      expect(isWorktreeUnavailableError(e), isFalse);
    });

    test('rejects network errors without a response', () {
      expect(
        isWorktreeUnavailableError(DioException(
          requestOptions: RequestOptions(),
          type: DioExceptionType.connectionError,
        )),
        isFalse,
      );
    });

    test('rejects non-DioException and unwraps OperationException', () {
      expect(isWorktreeUnavailableError(Exception('x')), isFalse);
      expect(
        isWorktreeUnavailableError(
            OperationException('删除工作区', cause: _unavailableDioError())),
        isTrue,
      );
    });
  });

  group('ServerStore.removeWorktree rescue (design §3.2)', () {
    test('S5: unavailable + broken -> rm + refresh + converge into success '
        'chain (evict runs, inventory cleared)', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.broken
        ..worktreeRows = const [WorktreeInfo(directory: _mainDir)];
      final store = _storeWith(client);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      final rm = client.shellCalls
          .where((c) => c.$1 == 'rm -rf "\$PWD"')
          .toList();
      expect(rm, hasLength(1));
      expect(rm.first.$2, _worktreeDir);
      expect(client.refreshCalls, 1);
      expect(client.evictCalls, 1);
      expect(store.worktreeDirsOf(_projectId), isEmpty);
      expect(store.isWorktreeDeleting(_worktreeDir), isFalse);
    });

    test('S6: probe ok (live worktree) -> no rm, no refresh, honest failure, '
        'inventory intact', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.ok;
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(
          client.shellCalls.where((c) => c.$1 == 'rm -rf "\$PWD"'), isEmpty);
      expect(client.refreshCalls, 0);
      expect(client.evictCalls, 0);
      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
    });

    test('S8: unknown + row still present -> no rm, give up with original '
        'error', () async {
      final err = _unavailableDioError();
      final client = _RescueClient()
        ..removeError = err
        ..probeResult = WorktreeHealth.unknown
        ..worktreeRows = [const WorktreeInfo(directory: _worktreeDir)];
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()
            .having((e) => e.cause, 'cause', same(err))),
      );
      await Future.delayed(Duration.zero);

      expect(
          client.shellCalls.where((c) => c.$1 == 'rm -rf "\$PWD"'), isEmpty);
      expect(client.refreshCalls, 1);
      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
    });

    test('S9: unknown + row gone (vanished-dir type) -> refresh converges, '
        'no rm, success', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.unknown
        ..worktreeRows = const [WorktreeInfo(directory: _mainDir)];
      final store = _storeWith(client);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(
          client.shellCalls.where((c) => c.$1 == 'rm -rf "\$PWD"'), isEmpty);
      expect(client.refreshCalls, 1);
      expect(store.worktreeDirsOf(_projectId), isEmpty);
    });

    test('unknown + re-list failure (network) -> give up, no success chain',
        () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.unknown
        ..listError = DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionError);
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
    });

    test('S7: rm exit != 0 -> give up before refresh, retryable', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.broken
        ..rmExit = 1;
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(client.refreshCalls, 0);
      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
    });

    test('S7b: rm channel error -> give up, retryable', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.broken
        ..rmError = DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionTimeout);
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(client.refreshCalls, 0);
    });

    test('S10: non-WorktreeError (network) -> probe not even sent', () async {
      final client = _RescueClient()
        ..removeError = DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionError);
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(client.probeCalls, 0);
      expect(client.refreshCalls, 0);
    });

    test('S11: rm ok + refresh fails -> honest failure (retry converges via '
        'unknown path)', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.broken
        ..refreshError = DioException(
            requestOptions: RequestOptions(),
            type: DioExceptionType.connectionError);
      final store = _storeWith(client);

      await expectLater(
        store.removeWorktree(_mainDir, worktreeDir: _worktreeDir),
        throwsA(isA<OperationException>()),
      );
      await Future.delayed(Duration.zero);

      expect(store.worktreeDirsOf(_projectId), [_worktreeDir]);
    });

    test('S11 retry: after rm succeeded the retry takes the unknown path to '
        'convergence', () async {
      final client = _RescueClient()
        ..removeError = _unavailableDioError()
        ..probeResult = WorktreeHealth.broken
        ..worktreeRows = const [WorktreeInfo(directory: _mainDir)];
      final store = _storeWith(client);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      // Retry: dir is gone now -> probe returns unknown, refresh converges.
      client
        ..probeResult = WorktreeHealth.unknown
        ..worktreeRows = const [WorktreeInfo(directory: _mainDir)];
      store.setWorktreeDirsForTesting(_projectId, [_worktreeDir]);
      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(store.worktreeDirsOf(_projectId), isEmpty);
      expect(client.refreshCalls, 2);
    });
  });

  group('cleanup branch prune prefix (design §3.3)', () {
    test('git worktree prune runs first, in canonical cwd', () async {
      final client = _RescueClient();
      final store = _storeWith(client);

      await store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);

      expect(client.shellCalls, isNotEmpty);
      expect(client.shellCalls.first,
          ('git worktree prune', _mainDir));
      expect(
        client.shellCalls.any((c) => c.$1
            .startsWith('git show-ref --verify --quiet refs/heads/opencode/')),
        isTrue,
      );
    });

    test('prune failure is best-effort: show-ref/-D still run', () async {
      final client = _RescueClient()..pruneError = Exception('channel gone');
      final store = _storeWith(client);

      final kept = await store.removeWorktree(
        _mainDir,
        worktreeDir: _worktreeDir,
      );

      expect(kept, isNull);
      expect(
        client.shellCalls.any((c) => c.$1.startsWith('git show-ref')),
        isTrue,
      );
      expect(
        client.shellCalls.any((c) => c.$1.startsWith('git branch -D')),
        isTrue,
      );
    });
  });

  group('ServerStore.detectBrokenWorktree (creation gate, design §2.2)',
      () {
    test('inventory worktree row + broken -> returns owning project', () async {
      final client = _RescueClient()..probeResult = WorktreeHealth.broken;
      final store = _storeWith(client);

      final broken = await store.detectBrokenWorktree(_worktreeDir);

      expect(broken, isNotNull);
      expect(broken!.project.id, _projectId);
      expect(broken.directory, _worktreeDir);
      expect(client.probeCalls, 1);
    });

    test('canonical excluded: no probe, returns null (zero RTT)', () async {
      final client = _RescueClient()..probeResult = WorktreeHealth.broken;
      final store = _storeWith(client);

      expect(await store.detectBrokenWorktree(_mainDir), isNull);
      expect(client.probeCalls, 0);
    });

    test('directory outside any inventory (global) -> null, no probe',
        () async {
      final client = _RescueClient()..probeResult = WorktreeHealth.broken;
      final store = _storeWith(client);

      expect(await store.detectBrokenWorktree('/somewhere/else'), isNull);
      expect(client.probeCalls, 0);
    });

    test('probe unknown -> null (fail-open)', () async {
      final client = _RescueClient()..probeResult = WorktreeHealth.unknown;
      final store = _storeWith(client);

      expect(await store.detectBrokenWorktree(_worktreeDir), isNull);
    });

    test('probe ok -> null', () async {
      final client = _RescueClient()..probeResult = WorktreeHealth.ok;
      final store = _storeWith(client);

      expect(await store.detectBrokenWorktree(_worktreeDir), isNull);
    });

    test('not connected -> null without probe', () async {
      final store = ServerStore();
      expect(await store.detectBrokenWorktree(_worktreeDir), isNull);
    });

    test('deleting-in-flight dir -> null without probe (no gate re-trigger '
        'during rescue window)', () async {
      final gate = Completer<List<SessionModel>>();
      final client = _RescueClient()
        ..probeResult = WorktreeHealth.broken
        ..sessionsGate = gate;
      final store = _storeWith(client);

      final pending = store.removeWorktree(_mainDir, worktreeDir: _worktreeDir);
      expect(store.isWorktreeDeleting(_worktreeDir), isTrue);

      expect(await store.detectBrokenWorktree(_worktreeDir), isNull);
      expect(client.probeCalls, 0);

      gate.complete(const []);
      await pending;
      expect(store.isWorktreeDeleting(_worktreeDir), isFalse);
    });
  });
}
