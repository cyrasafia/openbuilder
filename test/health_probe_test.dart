import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// Tests for the health-probe fast-recovery path: while the watchdog SSE is
/// reconnecting (network/server down), ServerStore probes GET /global/health
/// periodically and kicks all clients out of backoff on the first healthy
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

  test('probe starts on watchdog reconnecting, stops after healthy kick',
      () async {
    final client = _ProbeMockClient(healthy: false);
    final store = ServerStore()..client = client;
    store.onSseStateForTesting(ServerStore.globalWatchdogKeyForTesting,
        const SseState(reconnecting: true, attempt: 1));
    // Failing probes tick every 200ms.
    await Future.delayed(const Duration(milliseconds: 550));
    expect(client.healthCalls, greaterThanOrEqualTo(1),
        reason: 'probe should tick while watchdog is reconnecting');
    // Server comes back — next tick succeeds, probe stops.
    client.healthy = true;
    await Future.delayed(const Duration(milliseconds: 450));
    final callsAfterKick = client.healthCalls;
    await Future.delayed(const Duration(milliseconds: 450));
    expect(client.healthCalls, callsAfterKick,
        reason: 'probe must stop after a healthy response kicked reconnect');
    store.dispose();
  });

  test('probe stops when watchdog connects', () async {
    final client = _ProbeMockClient(healthy: false);
    final store = ServerStore()..client = client;
    store.onSseStateForTesting(ServerStore.globalWatchdogKeyForTesting,
        const SseState(reconnecting: true, attempt: 1));
    store.onSseStateForTesting(ServerStore.globalWatchdogKeyForTesting,
        const SseState(connected: true));
    await Future.delayed(const Duration(milliseconds: 450));
    expect(client.healthCalls, 0,
        reason: 'probe stopped before its first tick when watchdog connects');
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

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));
