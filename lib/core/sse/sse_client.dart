import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import '../logging/app_logger.dart';
import 'sse_transport.dart' if (dart.library.html) 'sse_transport_web.dart'
    as transport;

const _tag = 'SSE';

class OpencodeEvent {
  final String? id;
  final int? created;
  final String type;
  final Map<String, dynamic> properties;
  final String? directory;

  const OpencodeEvent({
    this.id,
    this.created,
    required this.type,
    required this.properties,
    this.directory,
  });

  factory OpencodeEvent.fromJson(Map<String, dynamic> j) => OpencodeEvent(
        id: j['id']?.toString(),
        created: j['created'] is num ? (j['created'] as num).toInt() : null,
        type: (j['type'] ?? '').toString(),
        properties: j['data'] is Map
            ? (j['data'] as Map).cast<String, dynamic>()
            : const {},
        directory: j['location'] is Map
            ? (j['location'] as Map)['directory']?.toString()
            : null,
      );
}

class GlobalOpencodeEvent {
  final String directory;
  final OpencodeEvent event;

  const GlobalOpencodeEvent({required this.directory, required this.event});
}

GlobalOpencodeEvent? parseGlobalEvent(String data) {
  final Map<String, dynamic> j;
  try {
    j = jsonDecode(data) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
  final ev = OpencodeEvent.fromJson(j);
  if (ev.type.isEmpty) return null;
  final directory = ev.directory ?? 'global';
  return GlobalOpencodeEvent(directory: directory, event: ev);
}

class SseState {
  final bool connected;
  final bool reconnecting;
  final int attempt;
  const SseState({this.connected = false, this.reconnecting = false, this.attempt = 0});
}

/// Builds the event-request URI with the auth query percent-encoded EXACTLY
/// like the REST path (dio → `Uri.encodeQueryComponent`). The server decodes
/// the query in form style — a literal `+` means space and corrupts the
/// base64 credential (live-verified: literal `+` → 401, `%2B` → 200) — and
/// `Uri.replace(queryParameters:)` escaping is an SDK implementation detail
/// that has changed across Dart releases (sdk#56643), so the string is
/// built here instead.
@visibleForTesting
Uri sseRequestUri(Uri base, Map<String, String> query) {
  if (query.isEmpty) return base;
  final pairs = query.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}='
          '${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  return base.replace(query: base.query.isEmpty ? pairs : '${base.query}&$pairs');
}

class SseClient {
  final Uri uri;
  final Map<String, String> headers;

  /// Query parameters for the event request (e.g. the oauth profile's
  /// `auth_token` bypass — a live map, re-read on every connect).
  final Map<String, String> query;
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
  Timer? _connectTimer;
  static const _heartbeatTimeout = Duration(seconds: 60);

  @visibleForTesting
  static Duration overallTimeout = const Duration(seconds: 15);

  SseClient({
    required String baseUrl,
    this.headers = const {},
    this.query = const {},
    String? label,
  })  : uri = Uri.parse('$baseUrl/api/event'),
        label = label ?? '/api/event';

  Stream<GlobalOpencodeEvent> get events => _controller.stream;
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
    var target = sseRequestUri(uri, query);
    _startHeartbeatTimer();
    _connectTimer?.cancel();
    _connectTimer = Timer(overallTimeout, _onConnectTimeout);
    _sub?.cancel();
    _sub = null;
    AppLogger.I.d(_tag, 'connect start $label');
    _sub = transport
        .eventDataStream(target, h, overallTimeout: overallTimeout)
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

  void _onDrop([String? reason]) {
    if (_stopped) return;
    if (_reconnectPending) return;
    _connected = false;
    _connectTimer?.cancel();
    _connectTimer = null;
    final r = reason != null ? ' ($reason)' : '';
    AppLogger.I.w(_tag, 'dropped $label$r');
    _reconnectPending = true;
    unawaited(_scheduleReconnect());
  }

  Future<void> _scheduleReconnect() async {
    _reconnectAttempt++;
    AppLogger.I.i(_tag, 'reconnect attempt $_reconnectAttempt $label');
    _emit(SseState(reconnecting: true, attempt: _reconnectAttempt));
    final waitSeconds = _backoff;
    _backoff = (_backoff * 2).clamp(1, 30);
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

  void reconnectNow() {
    if (_stopped) return;
    _backoff = 1;
    if (_reconnectPending) {
      AppLogger.I.i(_tag, 'reconnect now (kicked) $label');
    }
    _kickReconnect = true;
  }

  void _onData(String data) {
    _backoff = 1;
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
    if (!_stateCtl.isClosed) {
      _reconnectAttempt = 0;
      _emit(const SseState(connected: true));
    }
  }
}
