/// Web stub — the loopback receiver needs a real socket (dart:io). OAuth
/// login is mobile-only; the stub keeps the web target compiling.
class LoopbackCallbackServer {
  static const defaultPort = 8901;
  static const path = '/callback';

  static String redirectUriFor(int port) => 'http://127.0.0.1:$port$path';

  bool get isBound => false;
  int get boundPort => 0;
  Future<Map<String, String>> get params => Future.error(
      UnsupportedError('loopback callback requires dart:io (mobile)'));

  Future<void> start({int port = defaultPort}) async =>
      throw UnsupportedError('loopback callback requires dart:io (mobile)');

  void mergeQuery(Map<String, String> into, String query) {}

  Future<void> close() async {}
}
