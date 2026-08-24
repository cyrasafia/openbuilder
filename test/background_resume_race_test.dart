import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';

class _BlockingStopSse extends SseClient {
  final stopped = Completer<void>();
  bool stopCalled = false;

  _BlockingStopSse() : super(baseUrl: 'http://127.0.0.1');

  @override
  Future<void> stop() {
    stopCalled = true;
    return stopped.future;
  }
}

void main() {
  tearDown(() {
    ServerStore.sseStopTimeout = const Duration(seconds: 2);
  });

  test('teardown detaches the client before bounded stop completes', () async {
    ServerStore.sseStopTimeout = const Duration(milliseconds: 10);
    final store = ServerStore();
    final client = _BlockingStopSse();
    store.installSseForTesting(client);

    final stopping = store.stopSseForTesting();

    expect(store.hasSseForTesting, isFalse);
    expect(client.stopCalled, isTrue);
    await stopping.timeout(const Duration(milliseconds: 100));
    expect(client.stopped.isCompleted, isFalse);
  });
}
