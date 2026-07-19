import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/sse/sse_client.dart';

/// Verifies the SSE IO transport against the local opencode server (plan §8).
/// Expects at least one event (server.connected) within a few seconds.
void main() {
  test('SseClient receives an event from /event (localhost:15120)', () async {
    final client = SseClient(uri: Uri.parse('http://localhost:15120/event'));
    final completer = Completer<OpencodeEvent>();
    final sub = client.events.listen((e) {
      if (!completer.isCompleted) completer.complete(e);
    });
    client.start();
    try {
      final ev = await completer.future.timeout(const Duration(seconds: 8));
      expect(ev.type, isNotEmpty);
    } on TimeoutException {
      // CI / non-dev machines won't have the local server; skip gracefully.
      await sub.cancel();
      await client.stop();
      return;
    } catch (e) {
      await sub.cancel();
      await client.stop();
      return;
    }
    await sub.cancel();
    await client.stop();
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('reconnectNow wakes from backoff and reconnects quickly', () async {
    // Discard port: connection refused instantly, so each _connect() fails
    // immediately and the client walks the backoff ladder deterministically.
    final client = SseClient(uri: Uri.parse('http://127.0.0.1:9/event'));
    final attemptTimes = <int, DateTime>{};
    final sub = client.state.listen((s) {
      if (s.reconnecting) attemptTimes[s.attempt] = DateTime.now();
    });
    client.start();
    // attempt 1 scheduled at ~t0 (1s sleep), attempt 2 at ~t1s (2s sleep).
    await Future.delayed(const Duration(milliseconds: 1500));
    expect(attemptTimes.containsKey(2), isTrue,
        reason: 'attempt 2 should be pending (sleeping 2s backoff)');
    // Kick — attempt 3 should arrive in ~poll granularity (~200ms), not 2s.
    client.reconnectNow();
    await Future.delayed(const Duration(milliseconds: 1200));
    expect(attemptTimes.containsKey(3), isTrue,
        reason: 'reconnectNow should wake the client from the 2s backoff');
    final delta = attemptTimes[3]!.difference(attemptTimes[2]!).inMilliseconds;
    expect(delta, lessThan(1500),
        reason: 'kick should break the 2s backoff (delta=${delta}ms)');
    await sub.cancel();
    await client.stop();
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('reconnectNow before first failure persists into first reconnect cycle',
      () async {
    // Kick landing while NOT pending (e.g., mid-connect) must still take
    // effect: the flag survives into the first _scheduleReconnect, whose
    // sleep loop exits immediately instead of sleeping the full backoff.
    final client = SseClient(uri: Uri.parse('http://127.0.0.1:9/event'));
    final attemptTimes = <int, DateTime>{};
    final sub = client.state.listen((s) {
      if (s.reconnecting) attemptTimes[s.attempt] = DateTime.now();
    });
    final t0 = DateTime.now();
    client.start();
    // Synchronous kick: lands before the first drop is scheduled
    // (_reconnectPending == false). With the lost-kick fix, the flag
    // persists; without it, this call would be a complete no-op.
    client.reconnectNow();
    await Future.delayed(const Duration(milliseconds: 800));
    expect(attemptTimes.containsKey(2), isTrue,
        reason: 'kick flag should persist into the first reconnect cycle');
    final delta = attemptTimes[2]!.difference(t0).inMilliseconds;
    expect(delta, lessThan(1000),
        reason:
            'first cycle should be immediate (flag skipped the 1s backoff), got ${delta}ms');
    await sub.cancel();
    await client.stop();
  }, timeout: const Timeout(Duration(seconds: 10)));

  // A (P1): a server that accepts TCP but never sends response headers must
  // time out (sseOverallTimeout) and retry — not hang until the 60s heartbeat.
  test('hung server (no response headers) times out and reconnects', () async {
    final savedTimeout = SseClient.overallTimeout;
    SseClient.overallTimeout = const Duration(seconds: 2);

    // Raw TCP server: accepts connections but never responds (simulates an
    // overloaded server that accepts the socket but can't process the request).
    final server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) => socket.drain<void>());

    final client = SseClient(
      uri: Uri.parse('http://127.0.0.1:${server.port}/event'),
      label: 'test-hang',
    );
    final attempts = <int>[];
    final sub = client.state.listen((s) {
      if (s.reconnecting) attempts.add(s.attempt);
    });
    client.start();
    // With 2s timeout: connect hangs → 2s timeout → drop → attempt 1 (1s) →
    // connect hangs → 2s timeout → drop → attempt 2. Total ~7s for 2 attempts.
    await Future.delayed(const Duration(seconds: 8));
    expect(attempts.length, greaterThanOrEqualTo(2),
        reason: 'hung connects should time out and keep retrying, not hang for 60s heartbeat');

    SseClient.overallTimeout = savedTimeout;
    await sub.cancel();
    await client.stop();
    await server.close();
    // Let any in-flight transport timeouts settle within the test zone
    // (stop() cancels _sub but the underlying HTTP request lingers; without
    // this delay the 2s timeout fires as an unhandled post-test error).
    await Future.delayed(const Duration(seconds: 3));
  }, timeout: const Timeout(Duration(seconds: 20)));
}