import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One-shot loopback receiver for the OAuth redirect (GET query and POST
/// form_post both accepted). Binds 127.0.0.1 only; answers with a minimal
/// success page for the WebView to render.
class LoopbackCallbackServer {
  HttpServer? _server;
  final Completer<Map<String, String>> _params = Completer();
  bool _closed = false;

  static const defaultPort = 8901;
  static const path = '/callback';

  static String redirectUriFor(int port) => 'http://127.0.0.1:$port$path';

  bool get isBound => _server != null;

  /// Actual bound port (useful when started with port 0 for tests).
  int get boundPort => _server?.port ?? 0;

  Future<Map<String, String>> get params => _params.future;

  Future<void> start({int port = defaultPort, String? message}) async {
    if (_server != null || _closed) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    if (_closed) {
      // close() raced the bind — the socket must not leak.
      await server.close(force: true);
      return;
    }
    _server = server;
    server.listen((request) async {
      final params = <String, String>{};
      mergeQuery(params, request.uri.query);
      if (request.method == 'POST') {
        final body = await request.fold<String>(
          '',
          (prev, chunk) => prev + utf8.decode(chunk),
        );
        mergeQuery(params, body);
      }
      final text = message ?? 'Authorization received. You can return to Open Builder.';
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.html;
      request.response.write(
        '<!DOCTYPE html><html><head><meta name="viewport" '
        'content="width=device-width, initial-scale=1"></head>'
        '<body style="font-family:sans-serif;text-align:center;padding-top:40px">'
        '<div style="font-size:48px">&#10004;</div>'
        '<p>${htmlEscape.convert(text)}</p>'
        '</body></html>',
      );
      await request.response.close();
      if (!_params.isCompleted) _params.complete(params);
      await close();
    }, onError: (Object _) {
      if (!_params.isCompleted) {
        _params.completeError(const SocketException('loopback server error'));
      }
    });
  }

  void mergeQuery(Map<String, String> into, String query) {
    for (final pair in query.split('&')) {
      if (pair.isEmpty) continue;
      final eq = pair.indexOf('=');
      if (eq == -1) continue;
      final key = _decode(pair.substring(0, eq));
      final value = _decode(pair.substring(eq + 1));
      into.putIfAbsent(key, () => value);
    }
  }

  String _decode(String s) => Uri.decodeComponent(s.replaceAll('+', ' '));

  Future<void> close() async {
    _closed = true;
    final server = _server;
    _server = null;
    await server?.close(force: true);
    if (!_params.isCompleted) {
      _params.completeError(StateError('loopback closed'));
    }
  }
}
