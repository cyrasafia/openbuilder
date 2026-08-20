import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/auth_probe.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/connection/loopback_callback_server.dart';
import 'package:open_builder/core/connection/oauth_login_controller.dart';

class _FakeClient extends AuthCodeClient {
  LoginSession session = const LoginSession(
    authorizationUrl: 'https://auth.test/authorize?x=1',
    codeVerifier: 'v',
    state: 'st-fixed',
  );
  Object? exchangeError;
  int exchangeCalls = 0;
  Future<void>? exchangeGate;

  _FakeClient() : super();

  @override
  Future<LoginSession> startLogin({
    required OidcMetadata meta,
    required String clientId,
    required String audience,
    required String redirectUri,
  }) async {
    capturedAudience = audience;
    return session;
  }

  String? capturedAudience;

  @override
  Future<TokenResult> exchangeCode({
    required String tokenEndpoint,
    required String clientId,
    required String redirectUri,
    required String code,
    required String verifier,
  }) async {
    exchangeCalls++;
    if (exchangeGate != null) await exchangeGate;
    if (exchangeError != null) throw exchangeError!;
    return const TokenResult(
        accessToken: 'at1', refreshToken: 'rt1', expiresAtMs: 123);
  }
}

const meta = OidcMetadata(
  issuer: 'https://auth.test',
  authorizationEndpoint: 'https://auth.test/api/oidc/authorization',
  tokenEndpoint: 'https://auth.test/api/oidc/token',
);

const profile = ConnectionProfile(
  id: 'p1',
  name: 'Test',
  address: 'https://oc.test',
  authMethod: AuthMethod.oauth,
  oidcIssuer: 'https://auth.test',
  tokenEndpoint: 'https://auth.test/api/oidc/token',
);

Future<HttpClientResponse> _hitCallback(int port, String query) async {
  final client = HttpClient();
  final req =
      await client.getUrl(Uri.parse('http://127.0.0.1:$port/callback?$query'));
  return req.close();
}

Future<OAuthLoginPhase> _waitForPhase(
    OAuthLoginController c, OAuthLoginPhase phase) async {
  if (c.phase == phase) return phase;
  final completer = Completer<OAuthLoginPhase>();
  void listener() {
    if (c.phase == phase && !completer.isCompleted) completer.complete(phase);
  }

  c.addListener(listener);
  final result = await completer.future.timeout(const Duration(seconds: 2));
  c.removeListener(listener);
  return result;
}

void main() {
  test('happy path: callback with matching state → success + tokens',
      () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
      client: fake,
      providedLoopback: loopback,
      loopbackPort: loopback.boundPort,
    );
    expect(fake.capturedAudience, isNull);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    expect(fake.capturedAudience, 'https://oc.test',
        reason: 'audience must be the API base URL');
    expect(c.authorizationUrl, contains('auth.test'));
    await _hitCallback(
        loopback.boundPort, 'code=abc&state=st-fixed');
    await _waitForPhase(c, OAuthLoginPhase.success);
    expect(c.tokenResult?.accessToken, 'at1');
    expect(fake.exchangeCalls, 1);
    await started;
    c.dispose();
  });

  test('callbackMessage propagates to the rendered callback page', () async {
    final holder = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = holder.port;
    await holder.close();
    final c = OAuthLoginController(
      client: _FakeClient(),
      loopbackPort: port,
    );
    final started = c.start(
      profile: profile,
      meta: meta,
      callbackMessage: '已收到授权，请返回 Open Builder',
    );
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    final resp = await _hitCallback(port, 'code=abc&state=st-fixed');
    expect(resp.statusCode, 200);
    final body =
        await resp.transform(const Utf8Decoder()).join();
    expect(body, contains('已收到授权，请返回 Open Builder'));
    await _waitForPhase(c, OAuthLoginPhase.success);
    await started;
    c.dispose();
  });

  test('state mismatch → csrfError, no code exchange', () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    await _hitCallback(loopback.boundPort, 'code=abc&state=WRONG');
    await _waitForPhase(c, OAuthLoginPhase.csrfError);
    expect(fake.exchangeCalls, 0);
    await started;
    c.dispose();
  });

  test('error=access_denied → denied phase', () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    await _hitCallback(
        loopback.boundPort, 'error=access_denied&state=st-fixed');
    await _waitForPhase(c, OAuthLoginPhase.denied);
    await started;
    c.dispose();
  });

  test('timeout: no callback within the window → timeout phase', () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake,
        providedLoopback: loopback,
        callbackTimeout: const Duration(milliseconds: 80));
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.timeout);
    expect(loopback.isBound, isFalse);
    await started;
    c.dispose();
  });

  test('exchange failure (DioException) → exchangeError', () async {
    final fake = _FakeClient();
    fake.exchangeError = DioException(
      requestOptions: RequestOptions(path: 't'),
      error: 'boom',
    );
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    await _hitCallback(loopback.boundPort, 'code=abc&state=st-fixed');
    await _waitForPhase(c, OAuthLoginPhase.exchangeError);
    await started;
    c.dispose();
  });

  test('cancel during waitingAuth → cancelled; late callback ignored',
      () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    c.cancel();
    await _waitForPhase(c, OAuthLoginPhase.cancelled);
    await started;
    // Loopback was torn down by cancel: connection must be refused now.
    expect(loopback.isBound, isFalse);
    expect(fake.exchangeCalls, 0);
    c.dispose();
  });

  test('cancel during exchanging does not override with success', () async {
    final fake = _FakeClient();
    final gate = Completer<void>();
    fake.exchangeGate = gate.future;
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    unawaited(_hitCallback(loopback.boundPort, 'code=abc&state=st-fixed'));
    await _waitForPhase(c, OAuthLoginPhase.exchanging);
    c.cancel();
    await _waitForPhase(c, OAuthLoginPhase.cancelled);
    gate.complete(); // exchange finishes AFTER the cancel
    await started;
    await Future.delayed(Duration.zero);
    expect(c.phase, OAuthLoginPhase.cancelled,
        reason: 'terminal cancelled must win over late success');
    expect(c.tokenResult, isNull);
    c.dispose();
  });

  test('restart uses a fresh loopback (seam is first-round only)', () async {
    final fake = _FakeClient();
    final loopback = LoopbackCallbackServer();
    await loopback.start(port: 0);
    final ephemeral = loopback.boundPort;
    final c = OAuthLoginController(
        client: fake, providedLoopback: loopback, loopbackPort: ephemeral);
    final started = c.start(profile: profile, meta: meta);
    await _waitForPhase(c, OAuthLoginPhase.waitingAuth);
    c.cancel();
    await started;
    // Round 2: the injected receiver is closed; restart() would bind the
    // SAME (now-free) port with a fresh server. Give the fresh bind a free
    // port by handing the seam's port back — but the seam must NOT be used.
    final c2 = OAuthLoginController(
        client: fake, providedLoopback: loopback, loopbackPort: ephemeral);
    final started2 = c2.start(profile: profile, meta: meta);
    await _waitForPhase(c2, OAuthLoginPhase.waitingAuth);
    c2.cancel();
    final startedCancel = started2;
    await startedCancel;
    await c2.restart(profile: profile, meta: meta);
    await _waitForPhase(c2, OAuthLoginPhase.waitingAuth);
    expect(loopback.isBound, isFalse,
        reason: 'seam receiver stays closed across rounds');
    expect(c2.isLoopbackBoundForTesting, isTrue);
    c2.cancel();
    c2.dispose();
    c.dispose();
  });

  test('port already bound → portBusy', () async {
    final holder = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final c = OAuthLoginController(
        client: _FakeClient(), loopbackPort: holder.port);
    await c.start(profile: profile, meta: meta);
    expect(c.phase, OAuthLoginPhase.portBusy);
    await holder.close(force: true);
    c.dispose();
  });
}
