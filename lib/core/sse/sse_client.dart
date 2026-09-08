import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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

/// An [OpencodeEvent] with its `/global/event` envelope directory attached.
/// `directory` is `'global'` for frames without one (`server.connected` /
/// `server.heartbeat`).
class GlobalOpencodeEvent {
  final String directory;
  final OpencodeEvent event;

  const GlobalOpencodeEvent({required this.directory, required this.event});
}

/// Parses one raw SSE `data:` frame from `/global/event`.
///
/// Envelope: `{"directory": "/abs/dir"?, "project"?, "payload": {id,type,properties}}`.
/// Returns null for malformed JSON, non-envelope payloads, and the `sync`
/// double-emit (each durable event is re-sent wrapped as
/// `{"payload":{"type":"sync","syncEvent":{…}}}` — the original event already
/// preceded it, so the wrapper must be dropped).
GlobalOpencodeEvent? parseGlobalEvent(String data) {
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(data) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final payload = j['payload'];
  if (payload is! Map) return null;
  final map = payload.cast<String, dynamic>();
  if (map['type'] == 'sync') return null;
  final ev = OpencodeEvent.fromJson(map);
  if (ev.type.isEmpty) return null;
  final directory = j['directory']?.toString() ?? 'global';
  return GlobalOpencodeEvent(directory: directory, event: ev);
}

/// Lifecycle state of the SSE connection, for UI indicators (specs §11).
class SseState {
  final bool connected;
  final bool reconnecting;
  /// Current reconnect attempt (1-based); 0 when connected / idle.
  final int attempt;
  const SseState({this.connected = false, this.reconnecting = false, this.attempt = 0});
}

/// Connects to `GET /global/event` (single GlobalBus stream, server ≥ v1.0.66),
/// parses envelopes, and reconnects with exponential backoff on the IO
/// transport (web's EventSource reconnects by itself). Reconciliation is
/// driven by `server.connected` (re-emitted on each connect).
///
/// No `Last-Event-ID`: server SSE frames carry no `id:` and the server never
/// honors the header — disconnect recovery is REST reconciliation.
/// See design-sse-global-event.md.
class SseClient {
  final Uri uri;
  final Map<String, String> headers;
  final String label;

  StreamSubscription<String>? _sub;
  final _controller = StreamController<GlobalOpencodeEvent>.broadcast();
  final _stateCtl = StreamController<SseState>.broadcast();
  bool _stopped = true;
  bool _connected = false;
  int _backoff = 1;
  int _reconnectAttempt = 0;
  bool _reconnectPending = false;
  bool _kickReconnect = false;
  Timer? _heartbeatTimer;
  // Load-bearing, NOT redundant with the transport's `.timeout()`: created
  // before the transport call, so it consistently fires first and cancels the
  // async* generator, causing the generator's cancellation machinery to
  // DISCARD the transport's TimeoutException. Removing it lets that
  // TimeoutException escape through the async* error channel into the zone
  // (flutter_test flags it as unhandled). See sse_transport.dart doc comment.
  Timer? _connectTimer;
  static const _heartbeatTimeout = Duration(seconds: 60);

  /// Overall timeout for one connect attempt (connection + response headers).
  /// Bounds the previously-unbounded header-wait phase — a server that accepts
  /// TCP but never sends response headers (e.g., overloaded) would otherwise
  /// hang until the 60s heartbeat backstop. See design-sse-reconnect-recovery.md §12.
  @visibleForTesting
  static Duration overallTimeout = const Duration(seconds: 15);

  SseClient({required String baseUrl, this.headers = const {}, String? label})
      : uri = Uri.parse('$baseUrl/global/event'),
        label = label ?? '/global/event';

  Stream<GlobalOpencodeEvent> get events => _controller.stream;
  /// Lifecycle changes (connected / reconnecting + attempt), for UI banners.
  Stream<SseState> get state => _stateCtl.stream;
  bool get isRunning => !_stopped;

  void _emit(SseState s) {
    if (!_stateCtl.isClosed) _stateCtl.add(s);
  }

  void start() {
    if (!_stopped) return;
    _stopped = false;
    AppLogger.I.i(_tag, 'start $label');
    _connect();
  }

  Future<void> stop() async {
    _stopped = true;
    _connected = false;
    _connectTimer?.cancel();
    _connectTimer = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    AppLogger.I.i(_tag, 'stop $label');
    await _sub?.cancel();
    _sub = null;
  }

  void _connect() {
    final h = <String, String>{
      ...headers,
      'Accept': 'text/event-stream',
    };
    _startHeartbeatTimer();
    _connectTimer?.cancel();
    _connectTimer = Timer(overallTimeout, _onConnectTimeout);
    // Cancel any previous subscription BEFORE overwriting _sub. Without this,
    // each reconnect abandoned the old stream alive: error(onError) and
    // onDone both fired for the dead connection while the new one was already
    // listening, so every reconnect multiplied the live subscription count
    // (duplicate `server.connected` / `session.status` deliveries in the
    // logs) and each dead copy triggered ANOTHER _onDrop → another
    // reconnect — the reconnect storm.
    _sub?.cancel();
    _sub = null;
    AppLogger.I.d(_tag, 'connect start $label');
    _sub = transport
        .eventDataStream(uri, h, overallTimeout: overallTimeout)
        .listen(
          _onData,
          onError: (Object e) => _onDrop('error: ${e.runtimeType}'),
          onDone: () => _onDrop('server closed'),
        );
  }

  void _onConnectTimeout() {
    if (_stopped || _connected) return;
    AppLogger.I.w(_tag, 'connect timeout (${overallTimeout.inSeconds}s) $label');
    _sub?.cancel();
    _sub = null;
    _onDrop('connect timeout');
  }

  void _startHeartbeatTimer() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatTimeout, _onHeartbeatTimeout);
  }

  void _onHeartbeatTimeout() {
    if (_stopped) return;
    AppLogger.I.w(_tag, 'heartbeat timeout (no data for ${_heartbeatTimeout.inSeconds}s) $label');
    _sub?.cancel();
    _onDrop('heartbeat');
  }

  /// Transport dropped (error/done). Schedule one reconnect, guarding against
  /// duplicate scheduling while a backoff is already pending.
  void _onDrop([String? reason]) {
    if (_stopped) return;
    if (_reconnectPending) return;
    _connected = false;
    _connectTimer?.cancel();
    _connectTimer = null;
    final r = reason != null ? ' ($reason)' : '';
    AppLogger.I.w(_tag, 'dropped $label$r');
    _reconnectPending = true; // set synchronously: a same-tick second drop
    // from the old subscription's cancel-echo must not double-schedule.
    unawaited(_scheduleReconnect());
  }

  Future<void> _scheduleReconnect() async {
    _reconnectAttempt++;
    AppLogger.I.i(_tag, 'reconnect attempt $_reconnectAttempt $label');
    _emit(SseState(reconnecting: true, attempt: _reconnectAttempt));
    final waitSeconds = _backoff;
    _backoff = (_backoff * 2).clamp(1, 30);
    // A kick that arrived while no backoff was pending (lost kick) leaves
    // the flag set on purpose. But once a reconnect cycle starts, that stale
    // flag must be consumed HERE, not inside the sleep loop: the loop exits
    // at its first 200ms poll either way, and a flag left set would make the
    // NEXT cycle's sleep exit immediately too, reconnecting twice per drop
    // (attempt 1 + attempt 2 in the same millisecond in the logs).
    final kicked = _kickReconnect;
    _kickReconnect = false;
    final deadline = DateTime.now().add(Duration(seconds: waitSeconds));
    while (!kicked && DateTime.now().isBefore(deadline) && !_stopped) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (_kickReconnect) {
        _kickReconnect = false;
        break;
      }
    }
    _reconnectPending = false;
    if (_stopped) return;
    _connect();
  }

  /// Wake from backoff sleep and reconnect immediately, resetting the backoff
  /// that was earned under suspended-network conditions (e.g., Android Doze
  /// while backgrounded). Called by ServerStore on app resume / SSE start.
  ///
  /// The flag is set unconditionally: a kick landing while a connect is in
  /// flight (_reconnectPending == false) persists into the next
  /// _scheduleReconnect, which consumes it up front (zero added delay), and
  /// the backoff reset caps that cycle at 1s — the lost-kick window stays
  /// closed while the flag never survives past one cycle.
  void reconnectNow() {
    if (_stopped) return;
    _backoff = 1;
    if (_reconnectPending) {
      AppLogger.I.i(_tag, 'reconnect now (kicked) $label');
    }
    _kickReconnect = true;
  }

  void _onData(String data) {
    _backoff = 1; // healthy
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer(_heartbeatTimeout, _onHeartbeatTimeout);
    if (!_connected) {
      _connected = true;
      _connectTimer?.cancel();
      _connectTimer = null;
      AppLogger.I.i(_tag, 'connected $label');
    }
    final gev = parseGlobalEvent(data);
    if (gev != null) _controller.add(gev);
    // Always emit connected on receiving data — covers first connect
    // AND reconnect.
    if (!_stateCtl.isClosed) {
      _reconnectAttempt = 0;
      _emit(const SseState(connected: true));
    }
  }
}
