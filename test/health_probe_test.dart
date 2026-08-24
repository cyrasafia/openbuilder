import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// Tests for the health-probe fast-recovery path: while the global SSE is
/// reconnecting (network/server down), ServerStore probes GET /global/health
/// periodically and kicks the client out of backoff on the first healthy
/// response — bounding recovery detection to the probe interval instead of
/// the 30s backoff ceiling.

void main() {
  final savedInterval = ServerStore.healthProbeInterval;

  setUp(() {
    ServerStore.healthProbeInterval = const Duration(milliseconds: 200);
  });
  tearDown(() {
    ServerStore.healthProbeInterval = savedInterval;
  });

  test('probe starts on reconnecting, stops after healthy kick', () async {
    final client = _ProbeMockClient(healthy: false);
    final store = ServerStore()..client = client;
    store.onSseStateForTesting(const SseState(reconnecting: true, attempt: 1));
    // Failing probes tick every 200ms.
    await Future.delayed(const Duration(milliseconds: 550));
    expect(client.healthCalls, greaterThanOrEqualTo(1),
        reason: 'probe should tick while the SSE is reconnecting');
    // Server comes back — next tick succeeds, probe stops.
    client.healthy = true;
    await Future.delayed(const Duration(milliseconds: 450));
    final callsAfterKick = client.healthCalls;
    await Future.delayed(const Duration(milliseconds: 450));
    expect(client.healthCalls, callsAfterKick,
        reason: 'probe must stop after a healthy response kicked reconnect');
    store.dispose();
  });

  test('probe stops when the stream connects', () async {
    final client = _ProbeMockClient(healthy: false);
    final store = ServerStore()..client = client;
    store.onSseStateForTesting(const SseState(reconnecting: true, attempt: 1));
    store.onSseStateForTesting(const SseState(connected: true));
    await Future.delayed(const Duration(milliseconds: 450));
    expect(client.healthCalls, 0,
        reason: 'probe stopped before its first tick when the stream connects');
    store.dispose();
  });

  test('stale healthy response does not stop a newer probe cycle', () async {
    final client = _DelayedProbeMockClient();
    final store = ServerStore()..client = client;
    store.onSseStateForTesting(const SseState(reconnecting: true, attempt: 1));
    await Future.delayed(const Duration(milliseconds: 250));
    expect(client.healthCalls, 1);

    // Drop → recover → drop again: the second reconnecting starts a NEW probe
    // cycle (generation bump). The first cycle's delayed healthy response
    // resolves after that and must not stop the new timer.
    store.onSseStateForTesting(const SseState(connected: true));
    store.onSseStateForTesting(const SseState(reconnecting: true, attempt: 2));
    client.firstResponse.complete(HealthInfo(healthy: true, version: 'test'));

    await Future.delayed(const Duration(milliseconds: 500));
    expect(client.healthCalls, greaterThanOrEqualTo(2),
        reason: 'an old healthy response must not stop the new probe timer');
    store.dispose();
  });
}

/// Mock client whose /global/health outcome is controllable.
class _ProbeMockClient extends OpencodeClient {
  int healthCalls = 0;
  bool healthy;
  _ProbeMockClient({required this.healthy}) : super(_noopDio());

  @override
  Future<HealthInfo> health() async {
    healthCalls++;
    if (!healthy) throw Exception('server down');
    return HealthInfo(healthy: true, version: 'test');
  }
}

class _DelayedProbeMockClient extends OpencodeClient {
  int healthCalls = 0;
  final firstResponse = Completer<HealthInfo>();

  _DelayedProbeMockClient() : super(_noopDio());

  @override
  Future<HealthInfo> health() {
    healthCalls++;
    if (healthCalls == 1) return firstResponse.future;
    return Future<HealthInfo>.error(Exception('server down'));
  }
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));
