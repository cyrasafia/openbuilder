import 'dart:async';
import 'dart:convert';

import 'sse_transport.dart' if (dart.library.html) 'sse_transport_web.dart'
    as transport;

/// A parsed opencode SSE event (`data: {id,type,properties}`).
class OpencodeEvent {
  final String? id;
  final String type;
  final Map<String, dynamic> properties;

  const OpencodeEvent({this.id, required this.type, required this.properties});

  factory OpencodeEvent.fromJson(Map<String, dynamic> j) => OpencodeEvent(
        id: j['id']?.toString(),
        type: (j['type'] ?? '').toString(),
        properties: j['properties'] is Map
            ? (j['properties'] as Map).cast<String, dynamic>()
            : const {},
      );
}

/// Connects to `/event`, parses events, tracks the last id, and reconnects with
/// exponential backoff on the IO transport (web's EventSource reconnects by
/// itself). Reconciliation is driven by `server.connected` (re-emitted on each
/// connect).
class SseClient {
  final Uri uri;
  final Map<String, String> headers;

  StreamSubscription<String>? _sub;
  final _controller = StreamController<OpencodeEvent>.broadcast();
  String? _lastId;
  bool _stopped = true;
  int _backoff = 1;

  SseClient({required this.uri, this.headers = const {}});

  Stream<OpencodeEvent> get events => _controller.stream;
  bool get isRunning => !_stopped;

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    await _sub?.cancel();
    _sub = null;
  }

  void _connect() {
    final h = <String, String>{
      ...headers,
      // ignore: use_null_aware_elements
      if (_lastId != null) 'Last-Event-ID': _lastId!,
      'Accept': 'text/event-stream',
    };
    _sub = transport.eventDataStream(uri, h).listen(
          _onData,
          onError: (Object _) => _scheduleReconnect(),
          onDone: () => _scheduleReconnect(),
        );
  }

  Future<void> _scheduleReconnect() async {
    if (_stopped) return;
    await Future.delayed(Duration(seconds: _backoff));
    _backoff = (_backoff * 2).clamp(1, 30);
    if (_stopped) return;
    _connect();
  }

  void _onData(String data) {
    _backoff = 1; // healthy
    try {
      final j = jsonDecode(data) as Map<String, dynamic>;
      final ev = OpencodeEvent.fromJson(j);
      if (ev.id != null) _lastId = ev.id;
      _controller.add(ev);
    } catch (_) {
      // ignore malformed frames
    }
  }
}
