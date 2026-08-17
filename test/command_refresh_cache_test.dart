import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// `refreshCommands` has a single source: the v1 instance route `GET /command`
// (the execution registry of `POST /session/:id/command`; built-ins are
// hardcoded so a healthy answer is never empty). A transient blip must not
// wipe a known-good cache:
//  - a thrown fetch (degraded) keeps the cache.
//  - a "suspicious empty" — 200-OK with zero entries (common right after a
//    network recovery, no exception) — also keeps the cache while the streak
//    is under [ServerStore.kMaxSuspiciousRetries], then is trusted once it
//    persists.

class _CmdClient extends OpencodeClient {
  _CmdClient() : super(Dio(BaseOptions(baseUrl: 'http://test')));
  List<CommandInfo> v1 = const [];
  Object? v1Error;

  @override
  Future<List<CommandInfo>> getMergedCommands({String? directory}) async {
    if (v1Error != null) throw v1Error!;
    return v1;
  }
}

const _dir = '/work';
final _cmd = const CommandInfo(name: 'review', description: 'code review');
final _skill = const CommandInfo(
    name: 'tavily-search', description: 'web search', source: 'skill');

void main() {
  test('a healthy answer applies directly', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isFalse);
  });

  test('suspicious empty keeps a known-good cache and marks degraded',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isFalse);

    // Network just recovered: 200-OK but empty.
    client.v1 = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2),
        reason: 'good cache must survive a transient suspicious empty');
    expect(store.commandsDegraded, isTrue,
        reason: 'next `/` must retry to recover the real list');
  });

  test('suspicious empty with no cache surfaces the empty but stays degraded',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    // First ever refresh is already suspicious-empty (no prior good cache).
    client.v1 = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, isEmpty);
    expect(store.commandsDegraded, isTrue,
        reason: 'no cache to protect — flag degraded so the next `/` retries');
  });

  test('a recovered fetch clears the streak so a later blip is retained again',
      () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    // Transient suspicious empty → retained.
    client.v1 = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);

    // Recovery → cache refreshed, streak reset, no longer degraded.
    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isFalse);

    // Another blip must still be retained (streak was reset by the recovery).
    client.v1 = const [];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);
  });

  test('after the streak is exhausted a persistent empty is trusted', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    // Burn through the retain budget with suspicious empties.
    client.v1 = const [];
    for (var i = 0; i < ServerStore.kMaxSuspiciousRetries; i++) {
      await store.refreshCommands(directory: _dir);
      expect(store.commandsNotifier.value, hasLength(2),
          reason: 'retain while streak under budget (attempt ${i + 1})');
    }

    // One more → streak exhausted, empty is now applied.
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, isEmpty);
    expect(store.commandsDegraded, isFalse,
        reason: 'a persistent empty is authoritative, not degraded');
  });

  test('a thrown fetch still keeps a known-good cache', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd, _skill];
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));

    client.v1Error = Exception('connection abort');
    await store.refreshCommands(directory: _dir);
    expect(store.commandsNotifier.value, hasLength(2));
    expect(store.commandsDegraded, isTrue);
  });

  test('cache retention is directory-scoped', () async {
    final client = _CmdClient();
    final store = ServerStore()..client = client;

    client.v1 = [_cmd];
    await store.refreshCommands(directory: '/a');
    expect(store.commandsNotifier.value, hasLength(1));

    // Same blip but resolved for another directory: no cross-directory retain.
    client.v1 = const [];
    await store.refreshCommands(directory: '/b');
    expect(store.commandsNotifier.value, isEmpty,
        reason: "project A's commands must never leak into project B");
    expect(store.commandsDegraded, isTrue);
  });
}
