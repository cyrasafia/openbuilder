import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/loopback_callback_server.dart';

Future<HttpClientResponse> _get(int port, String query) async {
  final client = HttpClient();
  final req = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/callback?$query'));
  return req.close();
}

Future<HttpClientResponse> _post(int port, String body) async {
  final client = HttpClient();
  final req = await client.postUrl(Uri.parse('http://127.0.0.1:$port/callback'));
  req.headers.contentType = ContentType(
      'application', 'x-www-form-urlencoded',
      charset: 'utf-8');
  req.write(body);
  return req.close();
}

void main() {
  group('LoopbackCallbackServer', () {
    test('GET query callback completes params (query mode)', () async {
      final server = LoopbackCallbackServer();
      await server.start(port: 0);
      final port = server.boundPort;
      final resp = await _get(port, 'code=abc&state=st1&iss=https%3A%2F%2Fauth.test');
      expect(resp.statusCode, 200);
      final params = await server.params;
      expect(params['code'], 'abc');
      expect(params['state'], 'st1');
      expect(params['iss'], 'https://auth.test');
      expect(server.isBound, isFalse, reason: 'closes after one shot');
    });

    test('POST form body callback completes params (form_post mode)',
        () async {
      final server = LoopbackCallbackServer();
      await server.start(port: 0);
      final port = server.boundPort;
      final resp = await _post(port, 'code=xyz&state=st2');
      expect(resp.statusCode, 200);
      final params = await server.params;
      expect(params['code'], 'xyz');
      expect(params['state'], 'st2');
    });

    test('decodes + as space and %XX sequences', () async {
      final server = LoopbackCallbackServer();
      await server.start(port: 0);
      final port = server.boundPort;
      await _get(port, 'error_description=denied+by+user%21');
      final params = await server.params;
      expect(params['error_description'], 'denied by user!');
    });

    test('renders the localized callback message, HTML-escaped', () async {
      final server = LoopbackCallbackServer();
      await server.start(port: 0, message: '已收到授权 <Open Builder>');
      final port = server.boundPort;
      final resp = await _get(port, 'code=abc&state=st1');
      expect(resp.statusCode, 200);
      final body = await resp.transform(utf8.decoder).join();
      expect(body, contains('已收到授权 &lt;Open Builder&gt;'));
      expect(body, isNot(contains('<Open Builder>')));
    });

    test('close() before any request errors the params future', () async {
      final server = LoopbackCallbackServer();
      await server.start(port: 0);
      final params = server.params;
      await server.close();
      await expectLater(params, throwsStateError);
    });

    test('close() racing start() does not leak the socket', () async {
      final server = LoopbackCallbackServer();
      // Fire start without awaiting, close immediately: the bind may land
      // after close() — the socket must still be released.
      unawaited(server.start(port: 0));
      unawaited(server.params
          .catchError((Object _) => <String, String>{}));
      await server.close();
      await Future.delayed(Duration.zero);
      expect(server.isBound, isFalse);
    });
  });
}
