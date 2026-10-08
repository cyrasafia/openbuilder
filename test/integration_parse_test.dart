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
    final h = await _client!.health();
    return h.version.startsWith('2.');
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
      password: '1234321',
    )));
  });

  test('projects() parses v2 Project{id,canonical,name,icon}', () async {
    if (!await _serverUp()) return;
    final ps = await _client!.projects();
    expect(ps, isNotEmpty);
    final first = ps.first;
    expect(first.id, isNotEmpty);
    expect(first.canonical, isNotEmpty);
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
    final active = await _client!.activeSessions();
    expect(active, isA<Map>());
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('messages() parse against an active session', () async {
    if (!await _serverUp()) return;
    final ss = await _client!.sessions();
    final target = ss.firstWhere(
      (s) => s.tokens.total > 0,
      orElse: () => ss.first,
    );
    final msgs = await _client!.messages(target.id, limit: 5);
    expect(msgs, isA<List>());
    if (msgs.isNotEmpty) {
      expect(
          const [
            'user',
            'assistant',
            'idle',
            'synthetic',
            'system',
            'skill',
            'shell',
            'compaction',
            'agent-switched',
            'model-switched',
            'location-switched',
          ],
          contains(msgs.first.kind));
    }
  }, timeout: const Timeout(Duration(seconds: 20)));
}