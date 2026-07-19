import 'dart:async';
import 'dart:convert';

import '../logging/app_logger.dart';
import 'sse_transport.dart' if (dart.library.html) 'sse_transport_web.dart'
    as transport;

const _tag = 'SSE';

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

/// Lifecycle state of the SSE connection, for UI indicators (specs §11).
class SseState {
  final bool connected;
  final bool reconnecting;
  /// Current reconnect attempt (1-based); 0 when connected / idle.
  final int attempt;
  const SseState({this.connected = false, this.reconnecting = false, this.attempt = 0});
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
  final _stateCtl = StreamController<SseState>.broadcast();
  String? _lastId;
  bool _stopped = true;
  int _backoff = 1;
  int _reconnectAttempt = 0;
  bool _reconnectPending = false;
  bool _kickReconnect = false;
  DateTime _lastEventAt = DateTime.now();
  Timer? _heartbeatTimer;
  static const _heartbeatTimeout = Duration(seconds: 60);

  SseClient({required this.uri, this.headers = const {}});

  Stream<OpencodeEvent> get events => _controller.stream;
  /// Lifecycle changes (connected / reconnecting + attempt), for UI banners.
  Stream<SseState> get state => _stateCtl.stream;
  bool get isRunning => !_stopped;

  /// Last time an SSE data frame was received. Used for LRU eviction.
  /// Only updated in `_onData` — NOT on connection establishment.
  /// Idle directories with no events keep their creation timestamp,
  /// so LRU correctly prioritizes evicting them.
  DateTime get lastEventAt => _lastEventAt;

  void _emit(SseState s) {
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  void start() {
    if (!_stopped) return;
    _stopped = false;
    AppLogger.I.i(_tag, 'start ${uri.path}');
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    AppLogger.I.i(_tag, 'stop ${uri.path}');
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
    _startHeartbeatTimer();
    _sub = transport.eventDataStream(uri, h).listen(
          _onData,
          onError: (_) => _onDrop(),
          onDone: () => _onDrop(),
        );
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatTimeout, _onHeartbeatTimeout);
  }

  void _onHeartbeatTimeout() {
    if (_stopped) return;
    AppLogger.I.w(_tag, 'heartbeat timeout (no data for ${_heartbeatTimeout.inSeconds}s) ${uri.path}');
    _sub?.cancel();
    _onDrop();
  }

  /// Transport dropped (error/done). Schedule one reconnect, guarding against
  /// duplicate scheduling while a backoff is already pending.
  void _onDrop() {
    if (_stopped || _reconnectPending) return;
    AppLogger.I.w(_tag, 'dropped ${uri.path}');
    unawaited(_scheduleReconnect());
  }

  Future<void> _scheduleReconnect() async {
    _reconnectPending = true;
    _reconnectAttempt++;
    AppLogger.I.i(_tag, 'reconnect attempt $_reconnectAttempt ${uri.path}');
    _emit(SseState(reconnecting: true, attempt: _reconnectAttempt));
    final waitSeconds = _backoff;
    _backoff = (_backoff * 2).clamp(1, 30);
    // Interruptible backoff: reconnectNow() (e.g., app resume) breaks the
    // sleep early. 200ms poll granularity keeps kick latency negligible.
    final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
    while (DateTime.now().isBefore(deadline) && !_stopped && !_kickReconnect) {
      await Future.delayed(const Duration(milliseconds: 200));
    }
    _kickReconnect = false;
    _reconnectPending = false;
    if (_stopped) return;
    _connect();
  }

  /// Wake from backoff sleep and reconnect immediately, resetting the backoff
  /// that was earned under suspended-network conditions (e.g., Android Doze
  /// while backgrounded). Called by ServerStore on app resume / SSE start.
  /// No-op when connected or not pending.
  void reconnectNow() {
    if (_stopped || !_reconnectPending) return;
    AppLogger.I.i(_tag, 'reconnect now (kicked) ${uri.path}');
    _backoff = 1;
    _kickReconnect = true;
  }

  void _onData(String data) {
    _lastEventAt = DateTime.now();
    _backoff = 1; // healthy
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatTimeout, _onHeartbeatTimeout);
    try {
      final j = jsonDecode(data) as Map<String, dynamic>;
      final ev = OpencodeEvent.fromJson(j);
      if (ev.id != null) _lastId = ev.id;
      _controller.add(ev);
    } catch (_) {
      // ignore malformed frames
    }
    // Always emit connected on receiving data — covers first connect
    // AND reconnect.
    if (!_stateCtl.isClosed) {
      _reconnectAttempt = 0;
      _emit(const SseState(connected: true));
    }
  }
}
