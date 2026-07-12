// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' show EventSource, MessageEvent;

/// Web transport: uses browser `EventSource`, which auto-reconnects and parses
/// SSE framing. EventSource cannot set custom headers, so auth must be
/// cookie/URL-based or absent (the opencode test server doesn't enforce auth).
Stream<String> eventDataStream(Uri uri, Map<String, String> headers) {
  final controller = StreamController<String>();
  final es = EventSource(uri.toString());

  es.onMessage.listen((MessageEvent m) {
    final d = m.data;
    if (d is String) {
      controller.add(d);
    } else if (d != null) {
      controller.add(d.toString());
    }
  });

  // EventSource auto-reconnects internally; keep the controller open and do NOT
  // surface errors (the caller reconnects only on the IO transport, where the
  // stream actually completes on disconnect). Reconciliation is driven by the
  // `server.connected` event that the server re-emits on each connect.

  controller.onCancel = () => es.close();

  return controller.stream;
}
