import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// opencode v2 builds the per-directory agent/model registry lazily: the first
// `GET /api/agent|model?location[directory]=X` for a directory answers 200-OK
// with an empty list, and only later calls (~1s) serve the real one. If that
// transient empty is stored, the 30s TTL cache serves it to the
// agent/model/thinking bar of a session just created in a fresh worktree —
// the model chip still renders (its label comes from the session) but the
// thinking-variant chip stays hidden until the user re-enters the screen.
// A suspicious-empty fetch must be retried in place and never cached.

class _ScriptedClient extends OpencodeClient {
  _ScriptedClient(this.agentsScript, this.modelsScript)
      : super(Dio(BaseOptions(baseUrl: 'http://test')));
  final List<List<AgentInfo>> agentsScript;
  final List<List<ModelInfo>> modelsScript;
  int rounds = 0;
  Object? error;

  List<AgentInfo> _pickAgents() =>
      agentsScript[math.min(rounds, agentsScript.length - 1)];

  List<ModelInfo> _pickModels() =>
      modelsScript[math.min(rounds, modelsScript.length - 1)];

  @override
  Future<List<AgentInfo>> listAgents({String? directory}) async {
    if (error != null) throw error!;
    return _pickAgents();
  }

  @override
  Future<List<ModelInfo>> listModels({String? directory}) async {
    if (error != null) throw error!;
    final value = _pickModels();
    rounds++;
    return value;
  }
}

const _dir = '/work';
const _agents = [AgentInfo(id: 'build', name: 'Build', mode: 'primary')];
const _models = [
  ModelInfo(
    id: 'glm-5.3',
    providerID: 'zhipuai-coding-plan',
    name: 'GLM 5.3',
    variants: [ModelVariant(id: 'low'), ModelVariant(id: 'high')],
  ),
];

void main() {
  setUp(() {
    ServerStore.agentsModelsEmptyRetryDelay = Duration.zero;
  });

  tearDown(() {
    ServerStore.agentsModelsEmptyRetryDelay =
        const Duration(milliseconds: 600);
  });

  test('warm answer applies directly and is served from cache afterwards',
      () async {
    final client = _ScriptedClient([_agents], [_models]);
    final store = ServerStore()..client = client;

    final (agents, models) = await store.fetchAgentsAndModels(directory: _dir);
    expect(agents, hasLength(1));
    expect(models, hasLength(1));
    expect(client.rounds, 1);

    await store.fetchAgentsAndModels(directory: _dir);
    expect(client.rounds, 1, reason: 'within TTL the cache must serve');
  });

  test('cold-directory empty is retried in place and the warm result cached',
      () async {
    final client = _ScriptedClient(
      [const [], _agents],
      [const [], _models],
    );
    final store = ServerStore()..client = client;

    final (agents, models) = await store.fetchAgentsAndModels(directory: _dir);
    expect(agents, hasLength(1), reason: 'retry must pick up the warm list');
    expect(models, hasLength(1));
    expect(client.rounds, 2, reason: 'exactly one in-place retry was needed');

    await store.fetchAgentsAndModels(directory: _dir);
    expect(client.rounds, 2, reason: 'warm result must be cached');
  });

  test('persistently empty is never cached', () async {
    final client = _ScriptedClient([const []], [const []]);
    final store = ServerStore()..client = client;

    final (agents, models) = await store.fetchAgentsAndModels(directory: _dir);
    expect(agents, isEmpty);
    expect(models, isEmpty);
    expect(client.rounds, 1 + ServerStore.kAgentsModelsEmptyRetries);

    await store.fetchAgentsAndModels(directory: _dir);
    expect(
      client.rounds,
      (1 + ServerStore.kAgentsModelsEmptyRetries) * 2,
      reason: 'empty result must not poison the cache for 30s',
    );
  });

  test('a thrown fetch fails the caller and a later call refetches', () async {
    final client = _ScriptedClient([_agents], [_models])
      ..error = StateError('boom');
    final store = ServerStore()..client = client;

    await expectLater(
      store.fetchAgentsAndModels(directory: _dir),
      throwsStateError,
    );

    client.error = null;
    final (agents, models) = await store.fetchAgentsAndModels(directory: _dir);
    expect(agents, hasLength(1));
    expect(models, hasLength(1));
    expect(client.rounds, 1, reason: 'the failed round fetched nothing');
  });
}
