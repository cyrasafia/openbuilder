import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';

class _BlockingStopSse extends SseClient {
  final stopped = Completer<void>();
  bool stopCalled = false;

  _BlockingStopSse()
      : super(uri: Uri.parse('http://127.0.0.1/event'));

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

  test('teardown detaches clients before bounded stop completes', () async {
    ServerStore.sseStopTimeout = const Duration(milliseconds: 10);
    final store = ServerStore();
    final first = _BlockingStopSse();
    final second = _BlockingStopSse();
    store.installSseForTesting('first', first);
    store.installSseForTesting('second', second);

    final stopping = store.stopSseForTesting();

    expect(store.hasSseForTesting('first'), isFalse);
    expect(store.hasSseForTesting('second'), isFalse);
    expect(first.stopCalled, isTrue);
    expect(second.stopCalled, isTrue);
    await stopping.timeout(const Duration(milliseconds: 100));
    expect(first.stopped.isCompleted, isFalse);
    expect(second.stopped.isCompleted, isFalse);
  });
}
