import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

const _mainDir = '/repo';
const _projectId = 'p1';

ProjectModel _project() => ProjectModel(
      id: _projectId,
      canonical: _mainDir,
      vcs: 'git',
    );

SessionModel _session(String id, String dir) => SessionModel(
      id: id,
      projectID: _projectId,
      directory: dir,
      title: id,
      created: 0,
      updated: 1000,
    );

class _ShellCall {
  final String command;
  final String? cwd;
  final int timeoutMs;
  const _ShellCall(this.command, this.cwd, {this.timeoutMs = 15000});

  @override
  bool operator ==(Object other) =>
      other is _ShellCall &&
      other.command == command &&
      other.cwd == cwd &&
      other.timeoutMs == timeoutMs;

  @override
  int get hashCode => Object.hash(command, cwd, timeoutMs);
}

/// Mock client with a scriptable [runShell] (design-worktree-branch-sync).
class _BranchMockClient extends OpencodeClient {
  _BranchMockClient() : super(_noopDio());

  WorktreeInfo createWorktreeResult = const WorktreeInfo(directory: '');
  SessionModel? createSessionError;
  bool failCreateSession = false;

  final shellCalls = <_ShellCall>[];
  final callOrder = <String>[];
  ShellRunResult? Function(String command, String? cwd)? onShell;

  @override
  Future<WorktreeInfo> createWorktree(
    String projectID, {
    String? name,
    String? branch,
    String? from,
    String? directory,
  }) async =>
      createWorktreeResult;

  @override
  Future<SessionModel> createSession(
    String directory, {
    String? title,
    String? agent,
    ModelRef? model,
  }) async {
    if (failCreateSession) throw Exception('session create failed');
    return _session('new-session', directory);
  }

  @override
  Future<List<SessionModel>> sessionsForDirectory(String directory,
          {int limit = 1000}) async =>
      const [];

  @override
  Future<void> removeWorktree(String projectID, String worktreeDir,
      {bool force = false}) async {
    callOrder.add('remove');
  }

  @override
  Future<ShellRunResult> runShell(String command,
      {String? cwd, int timeoutMs = 15000}) async {
    shellCalls.add(_ShellCall(command, cwd, timeoutMs: timeoutMs));
    callOrder.add('shell:$command');
    final handler = onShell;
    if (handler != null) return handler(command, cwd) ?? const ShellRunResult(0, '');
    return const ShellRunResult(0, '');
  }
}

Future<void> _flushBackground() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('ServerStore worktree branch mount (create)', () {
    test('mounts opencode/<basename> in the new worktree directory', () async {
      final client = _BranchMockClient()
        ..createWorktreeResult =
            const WorktreeInfo(directory: '/wt/quiet-canyon');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);

      final session =
          await store.createSessionInNewWorktree(_mainDir);

      expect(session.id, 'new-session');
      await _flushBackground();

      expect(
        client.shellCalls,
        contains(const _ShellCall(
            'git switch -c opencode/quiet-canyon', '/wt/quiet-canyon',
            timeoutMs: 5000)),
      );
      expect(store.worktreeDirsOf(_projectId), contains('/wt/quiet-canyon'));
    });

    test('name collision retries with random suffix (show-ref confirms)',
        () async {
      final client = _BranchMockClient()
        ..createWorktreeResult =
            const WorktreeInfo(directory: '/wt/quiet-canyon')
        ..onShell = (command, _) {
          if (command.startsWith('git switch -c opencode/quiet-canyon') &&
              !command.contains('-c opencode/quiet-canyon-')) {
            return const ShellRunResult(1, "fatal: 分支已存在");
          }
          if (command.startsWith('git show-ref') &&
              command.endsWith('refs/heads/opencode/quiet-canyon')) {
            return const ShellRunResult(0, '');
          }
          return const ShellRunResult(0, '');
        };
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);

      await store.createSessionInNewWorktree(_mainDir);
      await _flushBackground();

      final switchCmds = client.shellCalls
          .map((c) => c.command)
          .where((c) => c.startsWith('git switch -c'))
          .toList();
      expect(switchCmds.first, 'git switch -c opencode/quiet-canyon');
      expect(switchCmds.length, 2);
      expect(switchCmds[1],
          matches(r'^git switch -c opencode/quiet-canyon-[a-z0-9]{4,}$'));
    });

    test('non-slug directory name skips branch management entirely',
        () async {
      final client = _BranchMockClient()
        ..createWorktreeResult = const WorktreeInfo(directory: '/wt/My Work');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);

      final session =
          await store.createSessionInNewWorktree(_mainDir);
      await _flushBackground();

      expect(session.id, 'new-session');
      expect(client.shellCalls, isEmpty);
    });

    test('shell channel failure degrades to detached without blocking create',
        () async {
      final client = _BranchMockClient()
        ..createWorktreeResult =
            const WorktreeInfo(directory: '/wt/quiet-canyon')
        ..onShell = (_, _) => throw Exception('endpoint missing');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);

      final session =
          await store.createSessionInNewWorktree(_mainDir);
      await _flushBackground();

      expect(session.id, 'new-session');
      // Single switch attempt, then degrade (no suffix retries on channel error).
      expect(client.shellCalls.length, 1);
    });
  });

  group('ServerStore worktree branch cleanup (remove)', () {
    test('merged branch is deleted from project canonical after worktree '
        'removal', () async {
      const worktreeDir = '/repo/.worktrees/feature';
      final client = _BranchMockClient()
        ..onShell = (command, _) {
          if (command.contains('show-ref')) return const ShellRunResult(0, '');
          if (command.contains('for-each-ref')) {
            return const ShellRunResult(
                0, 'refs/heads/opencode/feature\nrefs/heads/main\n');
          }
          return const ShellRunResult(0, '');
        };
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, isNull);
      expect(
        client.shellCalls,
        contains(const _ShellCall('git branch -D opencode/feature', _mainDir,
            timeoutMs: 5000)),
      );
      // WBS-1：清理链全部 shell 显式 5s 超时（deleting 态内最坏 15s 收口）。
      expect(
        client.shellCalls.every((c) => c.timeoutMs == 5000),
        isTrue,
      );
      // Branch cleanup runs after the worktree DELETE (§2.3: canonical cwd).
      expect(client.callOrder.indexOf('shell:git branch -D opencode/feature'),
          greaterThan(client.callOrder.indexOf('remove')));
    });

    test('unmerged branch is kept and returned for the UI notice', () async {
      const worktreeDir = '/repo/.worktrees/feature';
      final client = _BranchMockClient()
        ..onShell = (command, _) {
          if (command.contains('show-ref')) return const ShellRunResult(0, '');
          if (command.contains('for-each-ref')) {
            return const ShellRunResult(0, 'refs/heads/opencode/feature\n');
          }
          return const ShellRunResult(0, '');
        };
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, 'opencode/feature');
      expect(
        client.shellCalls
            .where((c) => c.command.contains('branch -D')),
        isEmpty,
      );
    });

    test('no same-named branch: single existence probe only', () async {
      const worktreeDir = '/repo/.worktrees/feature';
      final client = _BranchMockClient()
        ..onShell = (command, _) => const ShellRunResult(1, '');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, isNull);
      expect(client.shellCalls.length, 1);
      expect(client.shellCalls.single.command, contains('show-ref'));
    });

    test('branch -D failure falls back to keep + notice', () async {
      const worktreeDir = '/repo/.worktrees/feature';
      final client = _BranchMockClient()
        ..onShell = (command, _) {
          if (command.contains('show-ref')) return const ShellRunResult(0, '');
          if (command.contains('for-each-ref')) {
            return const ShellRunResult(0, 'refs/heads/opencode/feature\nrefs/heads/main\n');
          }
          if (command.contains('branch -D')) return const ShellRunResult(1, '');
          return const ShellRunResult(0, '');
        };
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, 'opencode/feature');
    });

    test('non-slug directory skips cleanup (zero shell calls)', () async {
      const worktreeDir = '/repo/My Work';
      final client = _BranchMockClient();
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, isNull);
      expect(client.shellCalls, isEmpty);
    });

    test('shell channel error keeps silent (no false keep notice)',
        () async {
      const worktreeDir = '/repo/.worktrees/feature';
      final client = _BranchMockClient()
        ..onShell = (_, _) => throw Exception('shell unavailable');
      final store = ServerStore()..client = client;
      store.setProjectsForTesting([_project()]);
      store.setWorktreeDirsForTesting(_projectId, [worktreeDir]);

      final kept = await store.removeWorktree(_mainDir, worktreeDir: worktreeDir);

      expect(kept, isNull);
      expect(store.worktreeDirsOf(_projectId), isEmpty);
    });
  });

  group('OpencodeClient.runShell', () {
    test('POST already terminal: reads output without status polling',
        () async {
      final calls = <String>[];
      final adapter = _ScriptedAdapter((method, path, body) {
        calls.add('$method $path');
        if (method == 'POST') return _shellEnvelope('sh_1', 'exited', 0);
        if (path == '/api/shell/sh_1/output') {
          return '{"location":{},"data":{"output":"done\\n"}}';
        }
        throw StateError('unexpected $method $path');
      });
      final client = OpencodeClient(Dio()..httpClientAdapter = adapter);

      final result = await client.runShell('echo done', cwd: '/repo');

      expect(result.exit, 0);
      expect(result.output, 'done\n');
      // The cleanup DELETE is fire-and-forget — flush the microtask chain.
      await _flushBackground();
      expect(calls, [
        'POST /api/shell',
        'GET /api/shell/sh_1/output',
        'DELETE /api/shell/sh_1',
      ]);
    });

    test('polls running shell to terminal state and passes exit code',
        () async {
      var polls = 0;
      final adapter = _ScriptedAdapter((method, path, body) {
        if (method == 'POST') return _shellEnvelope('sh_2', 'running', null);
        if (path == '/api/shell/sh_2') {
          polls++;
          return polls < 2
              ? _shellEnvelope('sh_2', 'running', null)
              : _shellEnvelope('sh_2', 'exited', 3);
        }
        if (path == '/api/shell/sh_2/output') {
          return '{"location":{},"data":{"output":"boom"}}';
        }
        throw StateError('unexpected $method $path');
      });
      final client = OpencodeClient(Dio()..httpClientAdapter = adapter);

      final result = await client.runShell('git status', cwd: '/repo');

      expect(result.exit, 3);
      expect(result.output, 'boom');
      expect(polls, 2);
    });

    test('throws TimeoutException when the shell never exits', () async {
      final adapter = _ScriptedAdapter((method, path, body) {
        if (method == 'POST') return _shellEnvelope('sh_3', 'running', null);
        return _shellEnvelope('sh_3', 'running', null);
      });
      final client = OpencodeClient(Dio()..httpClientAdapter = adapter);

      expect(
        () => client.runShell('sleep forever', timeoutMs: 50),
        throwsA(isA<TimeoutException>()),
      );
    });
  });
}

String _shellEnvelope(String id, String status, int? exit) {
  final exitJson = exit == null ? 'null' : '$exit';
  return '{"location":{},"data":{"id":"$id","status":"$status","exit":$exitJson,'
      '"command":"c","cwd":"/","shell":"/bin/fish","metadata":{},'
      '"time":{"started":1}}}';
}

class _ScriptedAdapter implements HttpClientAdapter {
  _ScriptedAdapter(this.respond);

  final String Function(String method, String path, Map<String, dynamic>? body)
      respond;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Map<String, dynamic>? body;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      final raw = utf8.decode(bytes);
      if (raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) body = decoded;
      }
    }
    final text = respond(options.method, options.path, body);
    return ResponseBody.fromString(text, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}
