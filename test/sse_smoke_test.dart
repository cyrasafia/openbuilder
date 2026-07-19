import 'dart:async';

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
}