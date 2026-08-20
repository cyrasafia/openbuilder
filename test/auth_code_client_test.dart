import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/auth_probe.dart';

class _Capture {
  Uri? uri;
  Map<String, dynamic> body = {};
}

class _Adapter implements HttpClientAdapter {
  final _Capture cap;
  final String respBody;
  final int status;
  _Adapter(this.cap, {this.respBody = '{}', this.status = 200});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cap.uri = options.uri;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      final raw = utf8.decode(bytes);
      cap.body = raw.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(Uri.splitQueryString(raw));
    }
    return ResponseBody.fromString(respBody, status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

AuthCodeClient _client(_Capture cap,
        {String body = '{}', int status = 200}) =>
    AuthCodeClient(
        dio: Dio()..httpClientAdapter = _Adapter(cap, respBody: body, status: status));

const meta = OidcMetadata(
  issuer: 'https://auth.test',
  authorizationEndpoint: 'https://auth.test/api/oidc/authorization',
  tokenEndpoint: 'https://auth.test/api/oidc/token',
  parEndpoint: 'https://auth.test/api/oidc/pushed-authorization-request',
);

void main() {
  group('startLogin (PAR path)', () {
    test('pushes all required fields and builds request_uri URL', () async {
      final cap = _Capture();
      final c = _client(cap,
          body: '{"request_uri":"urn:ietf:params:oauth:request_uri:abc"}',
          status: 201);
      final s = await c.startLogin(
          meta: meta,
          clientId: 'openbuilder-app',
          audience: 'https://oc.test',
          redirectUri: 'http://127.0.0.1:8901/callback');
      expect(cap.uri.toString(), meta.parEndpoint);
      expect(cap.body['client_id'], 'openbuilder-app');
      expect(cap.body['response_type'], 'code');
      expect(cap.body['redirect_uri'], 'http://127.0.0.1:8901/callback');
      expect(cap.body['scope'], 'offline_access authelia.bearer.authz');
      expect(cap.body['audience'], 'https://oc.test');
      expect(cap.body['code_challenge_method'], 'S256');
      expect(cap.body['state'], isNotEmpty);
      expect(
        s.authorizationUrl,
        startsWith('https://auth.test/api/oidc/authorization'
            '?client_id=openbuilder-app&request_uri=urn%3Aietf%3Aparams%3Aoauth%3Arequest_uri%3Aabc'),
      );
      expect(s.state, cap.body['state']);
    });

    test('code_challenge is BASE64URL(SHA256(verifier)) per RFC 7636',
        () async {
      final cap = _Capture();
      final c = _client(cap,
          body: '{"request_uri":"urn:x"}', status: 201);
      final s = await c.startLogin(
          meta: meta,
          clientId: 'cid',
          audience: 'https://oc.test',
          redirectUri: 'http://127.0.0.1:8901/callback');
      final expected = base64Url
          .encode(sha256.convert(utf8.encode(s.codeVerifier)).bytes)
          .replaceAll('=', '');
      expect(cap.body['code_challenge'], expected);
      expect(
          s.codeVerifier.length >= 43 && s.codeVerifier.length <= 128, isTrue);
    });

    test('PAR error (400) surfaces as DioException', () async {
      final c = _client(_Capture(),
          body: '{"error":"invalid_request"}', status: 400);
      expect(
        () => c.startLogin(
            meta: meta,
            clientId: 'cid',
            audience: 'a',
            redirectUri: 'http://127.0.0.1:8901/callback'),
        throwsA(isA<DioException>()),
      );
    });
  });

  group('startLogin (no PAR endpoint → direct authorization URL)', () {
    test('all params in the query string', () async {
      final cap = _Capture();
      final c = _client(cap);
      const noPar = OidcMetadata(
        issuer: 'https://auth.test',
        authorizationEndpoint: 'https://auth.test/authorize',
        tokenEndpoint: 'https://auth.test/token',
      );
      final s = await c.startLogin(
          meta: noPar,
          clientId: 'cid',
          audience: 'https://oc.test',
          redirectUri: 'http://127.0.0.1:8901/callback');
      expect(cap.uri, isNull, reason: 'no PAR request should be sent');
      final url = Uri.parse(s.authorizationUrl);
      expect(url.path, '/authorize');
      final q = url.queryParameters;
      expect(q['client_id'], 'cid');
      expect(q['response_type'], 'code');
      expect(q['scope'], 'offline_access authelia.bearer.authz');
      expect(q['code_challenge_method'], 'S256');
      expect(q['state'], s.state);
    });
  });

  group('token exchange', () {
    test('exchangeCode parses tokens and computes expiresAtMs', () async {
      final cap = _Capture();
      final c = _client(cap,
          body:
              '{"access_token":"at1","refresh_token":"rt1","expires_in":3600,'
              '"token_type":"bearer"}');
      final t = await c.exchangeCode(
          tokenEndpoint: meta.tokenEndpoint,
          clientId: 'cid',
          redirectUri: 'http://127.0.0.1:8901/callback',
          code: 'the-code',
          verifier: 'the-verifier');
      expect(cap.uri.toString(), meta.tokenEndpoint);
      expect(cap.body['grant_type'], 'authorization_code');
      expect(cap.body['code'], 'the-code');
      expect(cap.body['code_verifier'], 'the-verifier');
      expect(t.accessToken, 'at1');
      expect(t.refreshToken, 'rt1');
      final skew = t.expiresAtMs! -
          DateTime.now().millisecondsSinceEpoch -
          3600 * 1000;
      expect(skew.abs() < 5000, isTrue);
    });

    test('response without access_token throws', () async {
      final c = _client(_Capture(), body: '{"foo":1}');
      expect(
        () => c.exchangeCode(
            tokenEndpoint: meta.tokenEndpoint,
            clientId: 'cid',
            redirectUri: 'r',
            code: 'c',
            verifier: 'v'),
        throwsA(isA<DioException>()),
      );
    });

    test('refreshToken sends refresh grant and parses new tokens', () async {
      final cap = _Capture();
      final c = _client(cap,
          body: '{"access_token":"at2","refresh_token":"rt2"}');
      final t = await c.refreshToken(
          tokenEndpoint: meta.tokenEndpoint,
          clientId: 'cid',
          refreshToken: 'rt1');
      expect(cap.body['grant_type'], 'refresh_token');
      expect(cap.body['refresh_token'], 'rt1');
      expect(t.accessToken, 'at2');
      expect(t.refreshToken, 'rt2');
      expect(t.expiresAtMs, isNull);
    });
  });
}
