import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_probe.dart';

class _Resp {
  final int status;
  final String body;
  final Map<String, String> headers;

  const _Resp(this.status, {this.body = '', this.headers = const {}});
}

class _Router implements HttpClientAdapter {
  final Map<String, _Resp> routes;
  final bool autheliaAcceptGate;
  _Router(this.routes, {this.autheliaAcceptGate = false});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final accept = options.headers['Accept']?.toString() ?? '';
    if (autheliaAcceptGate &&
        options.uri.host == 'oc.test' &&
        !accept.contains('text/html') &&
        !accept.contains('*/*')) {
      return ResponseBody.fromString('', 401);
    }
    final resp = routes[options.uri.toString()];
    if (resp == null) {
      return ResponseBody.fromString('', 404);
    }
    return ResponseBody.fromString(resp.body, resp.status,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          if (resp.headers.isNotEmpty)
            'location': [resp.headers['location']!],
        });
  }
}

Dio _dio(Map<String, _Resp> routes) => Dio(BaseOptions(
      validateStatus: (_) => true,
      followRedirects: false,
    ))..httpClientAdapter = _Router(routes);

const metaBody = '{"issuer":"https://auth.example.com",'
    '"authorization_endpoint":"https://auth.example.com/api/oidc/authorization",'
    '"token_endpoint":"https://auth.example.com/api/oidc/token"}';

void main() {
  group('AuthProbe decision table', () {
    test('oauth: metadata on the API host', () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health':
            const _Resp(200, body: '{"healthy":true}'),
        'http://oc.test/.well-known/oauth-authorization-server':
            const _Resp(200, body: metaBody),
      }));
      final r = await probe.probe('http://oc.test');
      expect(r.outcome, AuthProbeOutcome.oauth);
      expect(r.oidc!.issuer, 'https://auth.example.com');
      expect(r.oidc!.tokenEndpoint, contains('/token'));
    });

    test('oauth wins over health 200', () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health':
            const _Resp(200, body: '{"healthy":true}'),
        'http://oc.test/.well-known/oauth-authorization-server':
            const _Resp(200, body: metaBody),
      }));
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.oauth);
    });

    test('oauth via gateway 302: metadata lives on the auth host (P2b)',
        () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health': const _Resp(302,
            headers: {'location': 'https://auth.test/?rd=x'}),
        'http://oc.test/.well-known/oauth-authorization-server': const _Resp(
            302,
            headers: {'location': 'https://auth.test/?rd=y'}),
        'https://auth.test/.well-known/oauth-authorization-server':
            const _Resp(200, body: metaBody),
      }));
      final r = await probe.probe('http://oc.test');
      expect(r.outcome, AuthProbeOutcome.oauth);
      expect(r.oidc, isNotNull);
    });

    test('oauth via Authelia gateway: 302 only when Accept includes text/html',
        () async {
      final dio = Dio(BaseOptions(
        headers: AuthProbe().dio.options.headers,
        validateStatus: (_) => true,
        followRedirects: false,
      ))..httpClientAdapter = _Router({
          'http://oc.test/global/health': const _Resp(302,
              headers: {'location': 'https://auth.test/?rd=x'}),
          'http://oc.test/.well-known/oauth-authorization-server': const _Resp(
              302,
              headers: {'location': 'https://auth.test/?rd=y'}),
          'https://auth.test/.well-known/oauth-authorization-server':
              const _Resp(200, body: metaBody),
        }, autheliaAcceptGate: true);
      final r = await AuthProbe(dio: dio).probe('http://oc.test');
      expect(r.outcome, AuthProbeOutcome.oauth);
      expect(r.oidc, isNotNull);
    });

    test('none: health 200, no metadata', () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health':
            const _Resp(200, body: '{"healthy":true,"version":"1.2.3"}'),
      }));
      final r = await probe.probe('http://oc.test');
      expect(r.outcome, AuthProbeOutcome.none);
      expect(r.version, '1.2.3');
    });

    test('basic: health 401', () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health': const _Resp(401),
      }));
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.basic);
    });

    test('unknown: health 500 without metadata', () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health': const _Resp(500),
      }));
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.unknown);
    });

    test('health falls back to /api/health when /global/health 404s',
        () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/api/health':
            const _Resp(200, body: '{"healthy":true}'),
      }));
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.none);
    });

    test('metadata without token_endpoint is ignored → falls to health',
        () async {
      final probe = AuthProbe(dio: _dio({
        'http://oc.test/global/health': const _Resp(401),
        'http://oc.test/.well-known/oauth-authorization-server': const _Resp(
            200,
            body: '{"issuer":"https://a","authorization_endpoint":"https://a"}'),
      }));
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.basic);
    });

    test('unreachable: transport errors on both health paths', () async {
      final dio = Dio(BaseOptions(
        validateStatus: (_) => true,
        followRedirects: false,
      ))..httpClientAdapter = _DeadAdapter();
      final probe = AuthProbe(dio: dio);
      expect((await probe.probe('http://oc.test')).outcome,
          AuthProbeOutcome.unreachable);
    });
  });
}

class _DeadAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.connectionError(
        requestOptions: options, reason: 'unreachable');
  }
}
