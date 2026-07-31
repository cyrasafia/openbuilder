import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// `refreshCommands` merges three sources (`/api/command`, `/api/skill`,
// `/config`) into a single cached list. A transient blip must not wipe a
// known-good cache:
//  - a thrown fetch (degraded) keeps the cache (pre-existing behavior).
//  - a "suspicious empty" — both server sources return 200-OK with zero entries
//    (common right after a network recovery, no exception) — also keeps the
//    cache while the streak is under [ServerStore.kMaxSuspiciousRetries], then
//    is trusted once it persists.

class _CmdClient extends OpencodeClient {
  _CmdClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  List<CommandInfo> commands = const [];
  List<CommandInfo> skills = const [];
  List<CommandInfo> config = const [];
  Object? commandsError;
  Object? skillsError;

  @override
  Future<List<CommandInfo>> getCommands({String? directory}) async {
    if (commandsError != null) throw commandsError!;
    return commands;
  }

  @override
  Future<List<CommandInfo>> getSkills({String? directory}) async {
    if (skillsError != null) throw skillsError!;
    return skills;
  }

  @override
  Future<List<CommandInfo>> getConfigCommands() async => config;
}

const _dir = '/work';
final _cmd = const CommandInfo(name: 'review', description: 'code review');
final _skill = const CommandInfo(
    name: 'tavily-search', description: 'web search', source: 'skill');
final _config = const CommandInfo(name: 'goal', description: 'set goal');

void main() {
  test('suspicious empty keeps a known-good cache and marks degraded',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.commands = [_cmd];
    client.skills = [_skill];
    client.config = [_config];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(3));
    expect(store.commandsDegraded, isFalse);

    // Network just recovered: both server sources 200-OK but empty.
    client.commands = const [];
    client.skills = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(3),
        reason: 'good cache must survive a transient suspicious empty');
    expect(store.commandsDegraded, isTrue,
        reason: 'next `/` must retry to recover the real list');
  });

  test('suspicious empty with no cache surfaces only config but stays degraded',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    // First ever refresh is already suspicious-empty (no prior good cache).
    client.commands = const [];
    client.skills = const [];
    client.config = [_config];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(1));
    expect(store.commandsDegraded, isTrue,
        reason: 'no cache to protect — flag degraded so the next `/` retries');
  });

  test('a recovered fetch clears the streak so a later blip is retained again',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client
      ..commands = [_cmd]
      ..skills = [_skill]
      ..config = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    // Transient suspicious empty → retained.
    client
      ..commands = const []
      ..skills = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);

    // Recovery → cache refreshed, streak reset, no longer degraded.
    client
      ..commands = [_cmd]
      ..skills = [_skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isFalse);

    // Another blip must still be retained (streak was reset by the recovery).
    client
      ..commands = const []
      ..skills = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);
  });

  test('after the streak is exhausted a persistent empty is trusted', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client
      ..commands = [_cmd]
      ..skills = [_skill]
      ..config = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    // Burn through the retain budget with suspicious empties.
    client
      ..commands = const []
      ..skills = const [];
    for (var i = 0; i < ServerStore.kMaxSuspiciousRetries; i++) {
      await store.refreshCommands(directory: _dir);
      expect(store.commandsNotifier.value, hasLength(2),
          reason: 'retain while streak under budget (attempt ${i + 1})');
    }

    // One more → streak exhausted, empty is now authoritative.
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, isEmpty);
    expect(store.commandsDegraded, isFalse,
        reason: 'a persistent empty is genuine, not degraded');
  });

  test('a thrown fetch still keeps a known-good cache', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client
      ..commands = [_cmd]
      ..skills = [_skill]
      ..config = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    client.commandsError = Exception('connection abort');
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);
  });
}
