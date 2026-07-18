import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// Parses real opencode data shapes against the local server (plan-overview.md §8).
/// Skips silently if the server is unreachable.
OpencodeClient? _client;

Future<bool> _serverUp() async {
  if (_client == null) return false;
  try {
    await _client!.health();
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  setUp(() {
    _client = OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://localhost:15120',
      username: 'opencode',
      password: '',
    )));
  });

  test('projects() parses v2 Project{name,icon,sandboxes}', () async {
    if (!await _serverUp()) return;
    final ps = await _client!.projects();
    expect(ps, isNotEmpty);
    final first = ps.first;
    expect(first.id, isNotEmpty);
    expect(first.worktree, isNotEmpty);
    expect(first.sandboxes, isA<List>());
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('sessions() parses v2 Session + status map', () async {
    if (!await _serverUp()) return;
    final ss = await _client!.sessions();
    expect(ss, isNotEmpty);
    final s = ss.first;
    expect(s.id, isNotEmpty);
    expect(s.projectID, isNotEmpty);
    expect(s.title, isNotEmpty);
    expect(s.updated, greaterThan(0));
    final status = await _client!.sessionStatus();
    expect(status, isA<Map>());
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('messages()/todos() parse against an active session', () async {
    if (!await _serverUp()) return;
    final ss = await _client!.sessions();
    final target = ss.firstWhere(
      (s) => s.tokens.total > 0,
      orElse: () => ss.first,
    );
    final msgs = await _client!.messages(target.id, limit: 5);
    expect(msgs, isA<List>());
    if (msgs.isNotEmpty) {
      expect(msgs.first.info.role, anyOf(equals('user'), equals('assistant')));
      expect(msgs.first.parts, isA<List>());
    }
    final todos = await _client!.todos(target.id);
    expect(todos, isA<List>());
  }, timeout: const Timeout(Duration(seconds: 20)));
}