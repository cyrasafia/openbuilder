import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../logging/app_logger.dart';
import 'auth_code_client.dart';
import 'auth_probe.dart';
import 'connection_profile.dart';
import 'loopback_callback_server.dart';

const _tag = 'OAuth';

enum OAuthLoginPhase {
  idle,
  preparing,
  waitingAuth,
  exchanging,
  success,
  parError,
  portBusy,
  csrfError,
  denied,
  flowError,
  timeout,
  exchangeError,
  cancelled,
}

/// Drives the WebView login lifecycle: PKCE+PAR → loopback receiver → code
/// exchange. UI observes [phase] / [authorizationUrl]; tokens land in
/// [tokenResult] for the screen to persist.
class OAuthLoginController extends ChangeNotifier {
  final AuthCodeClient client;
  final LoopbackCallbackServer? providedLoopback;
  final int loopbackPort;
  final Duration callbackTimeout;

  OAuthLoginPhase _phase = OAuthLoginPhase.idle;
  String? _authorizationUrl;
  TokenResult? _tokenResult;
  String? _errorDetail;
  LoopbackCallbackServer? _loopback;
  LoginSession? _session;
  Timer? _timeoutTimer;
  bool _disposed = false;
  bool _firstRound = true;

  OAuthLoginController({
    AuthCodeClient? client,
    this.providedLoopback,
    this.loopbackPort = LoopbackCallbackServer.defaultPort,
    this.callbackTimeout = const Duration(minutes: 5),
  }) : client = client ?? AuthCodeClient();

  OAuthLoginPhase get phase => _phase;
  String? get authorizationUrl => _authorizationUrl;
  TokenResult? get tokenResult => _tokenResult;
  String get loopbackOrigin =>
      'http://127.0.0.1:$loopbackPort';

  @visibleForTesting
  bool get isLoopbackBoundForTesting => _loopback?.isBound ?? false;

  bool get _terminal =>
      _phase == OAuthLoginPhase.success ||
      _phase == OAuthLoginPhase.parError ||
      _phase == OAuthLoginPhase.portBusy ||
      _phase == OAuthLoginPhase.csrfError ||
      _phase == OAuthLoginPhase.denied ||
      _phase == OAuthLoginPhase.flowError ||
      _phase == OAuthLoginPhase.timeout ||
      _phase == OAuthLoginPhase.exchangeError ||
      _phase == OAuthLoginPhase.cancelled;

  Future<void> start({
    required ConnectionProfile profile,
    required OidcMetadata meta,
    String? callbackMessage,
  }) async {
    if (_phase != OAuthLoginPhase.idle) return;
    _set(OAuthLoginPhase.preparing);
    // The injected seam is for the FIRST round only: the loopback completer
    // is one-shot, so restart rounds must build a fresh receiver.
    final seam = _firstRound ? providedLoopback : null;
    _firstRound = false;
    final loopback = seam ?? LoopbackCallbackServer();
    _loopback = loopback;
    try {
      await loopback.start(port: loopbackPort, message: callbackMessage);
    } on Object {
      if (_loopback == loopback) _set(OAuthLoginPhase.portBusy);
      return;
    }
    if (_phase != OAuthLoginPhase.preparing || _loopback != loopback) {
      return;
    }
    try {
      final session = await client.startLogin(
        meta: meta,
        clientId: profile.clientId,
        audience: profile.baseUrl,
        redirectUri: LoopbackCallbackServer.redirectUriFor(loopbackPort),
      );
      if (_phase != OAuthLoginPhase.preparing || _loopback != loopback) {
        return;
      }
      _session = session;
      _authorizationUrl = session.authorizationUrl;
      _set(OAuthLoginPhase.waitingAuth);
    } on DioException catch (e) {
      // Same round-identity rule as the tail of start(): a superseded round
      // must not tear down the successor's receiver or clobber its phase.
      if (_loopback == loopback) {
        _errorDetail = e.response?.data?.toString() ?? e.message;
        AppLogger.I.e(_tag, 'par failed: $_errorDetail');
        await _teardown();
        _set(OAuthLoginPhase.parError);
      }
      return;
    }
    _timeoutTimer = Timer(callbackTimeout, () {
      if (_phase == OAuthLoginPhase.waitingAuth) {
        _teardown();
        _set(OAuthLoginPhase.timeout);
      }
    });
    try {
      final params = await loopback.params;
      if (_phase != OAuthLoginPhase.waitingAuth || _loopback != loopback) {
        return;
      }
      _timeoutTimer?.cancel();
      final error = params['error'];
      if (error != null) {
        _errorDetail = params['error_description'] ?? error;
        AppLogger.I.e(_tag, 'callback error: $_errorDetail');
        _set(error == 'access_denied'
            ? OAuthLoginPhase.denied
            : OAuthLoginPhase.flowError);
        return;
      }
      if (params['state'] != _session?.state || params['code'] == null) {
        _set(OAuthLoginPhase.csrfError);
        return;
      }
      _set(OAuthLoginPhase.exchanging);
      final tokens = await client.exchangeCode(
        tokenEndpoint: meta.tokenEndpoint,
        clientId: profile.clientId,
        redirectUri: LoopbackCallbackServer.redirectUriFor(loopbackPort),
        code: params['code']!,
        verifier: _session!.codeVerifier,
      );
      if (_phase != OAuthLoginPhase.exchanging || _loopback != loopback) {
        return;
      }
      _tokenResult = tokens;
      _set(OAuthLoginPhase.success);
    } on DioException catch (e) {
      _errorDetail = e.response?.data?.toString() ?? e.message;
      AppLogger.I.e(_tag, 'token exchange failed: $_errorDetail');
      // A superseded round (cancel/restart installed a newer receiver) must
      // not overwrite the successor's phase.
      if (_loopback == loopback) {
        _set(OAuthLoginPhase.exchangeError);
      }
    } on Object {
      // Loopback closed while awaiting params (timeout/cancel already set a
      // terminal phase) — never override a terminal phase or a newer round.
      if (_loopback == loopback &&
          (_phase == OAuthLoginPhase.waitingAuth ||
              _phase == OAuthLoginPhase.exchanging)) {
        _set(OAuthLoginPhase.flowError);
      }
    } finally {
      // Only tear down the receiver this round installed: a superseded round
      // (cancel/restart raced its exit) must not close the live one.
      if (_loopback == loopback) {
        await _teardown();
      }
    }
  }

  void cancel() {
    if (_terminal || _phase == OAuthLoginPhase.idle) return;
    _teardown();
    _set(OAuthLoginPhase.cancelled);
  }

  Future<void> restart({
    required ConnectionProfile profile,
    required OidcMetadata meta,
    String? callbackMessage,
  }) async {
    if (!_terminal || _disposed) return;
    await _teardown();
    _phase = OAuthLoginPhase.idle;
    _authorizationUrl = null;
    _tokenResult = null;
    _errorDetail = null;
    _session = null;
    if (_disposed) return;
    notifyListeners();
    // Fire-and-forget: start() resolves only after the (up to 5 min) auth
    // wait; callers must not block on that.
    unawaited(start(
        profile: profile, meta: meta, callbackMessage: callbackMessage));
  }

  Future<void> _teardown() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final loopback = _loopback;
    _loopback = null;
    if (loopback != null) {
      loopback.params.ignore();
      await loopback.close();
    }
  }

  void _set(OAuthLoginPhase phase) {
    _phase = phase;
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _teardown();
    super.dispose();
  }
}
