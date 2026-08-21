import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/connection/connection_store.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/net/raw_download.dart';
import 'package:open_builder/data/api/opencode_client.dart';

class _FakeStore extends ConnectionStore {
  final Map<String, ConnectionProfile> db = {};

  @override
  ConnectionProfile? byId(String id) => db[id];

  @override
  Future<void> update(ConnectionProfile p) async => db[p.id] = p;
}

class _Adapter implements HttpClientAdapter {
  int apiCalls = 0;
  final List<String> authHeaders = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.uri.path == '/token') {
      return ResponseBody.fromString(
          '{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          });
    }
    apiCalls++;
    authHeaders.add(options.headers['Authorization']?.toString() ?? '');
    return ResponseBody.fromString(
        jsonEncode(
            {'type': 'text', 'mimeType': 'text/plain', 'content': 'hello'}),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        });
  }
}

ConnectionProfile _profile() => ConnectionProfile(
      id: 'p1',
      name: 'n',
      address: 'http://api.test',
      authMethod: AuthMethod.oauth,
      accessToken: 'at-old',
      refreshToken: 'rt-old',
      tokenExpiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      oidcIssuer: 'https://auth.test',
      tokenEndpoint: 'http://authstub.test/token',
      clientId: 'cid',
    );

Dio _apiDio(_Adapter adapter, ConnectionProfile p, _FakeStore store) {
  final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
    ..httpClientAdapter = adapter;
  dio.interceptors.add(AuthInterceptor(dio, p,
      store: store,
      tokenClient: AuthCodeClient(
          dio: Dio(BaseOptions(baseUrl: 'http://authstub.test'))
            ..httpClientAdapter = adapter)));
  return dio;
}

void main() {
  test('download dio attaches the Bearer token (oauth)', () async {
    final store = _FakeStore();
    store.db['p1'] = _profile();
    final adapter = _Adapter();
    final base = _apiDio(adapter, store.db['p1']!, store);

    final raw = rawDownloadDio(base)..httpClientAdapter = adapter;
    final resp = await raw.get<Object>('/file/content');
    expect(resp.statusCode, 200);
    expect(adapter.authHeaders.single, 'Bearer at-old',
        reason: 'the download request must carry the profile token');
  });

  test('download dio rebinds AuthInterceptor so 401 retries stay on it', () {
    final store = _FakeStore();
    store.db['p1'] = _profile();
    final adapter = _Adapter();
    final base = _apiDio(adapter, store.db['p1']!, store);

    final raw = rawDownloadDio(base);
    final rebound = raw.interceptors.whereType<AuthInterceptor>().single;
    expect(rebound.dio, same(raw),
        reason: 'a 401 retry must run on the download dio '
        '(autoUncompress=false), not the base dio');
    expect(rebound.store, same(store));
    expect(base.interceptors.whereType<AuthInterceptor>().single.dio,
        same(base));
  });

  // End-to-end over the real HTTP stack: readFileStream builds its own
  // download dio (real adapter), so a live local server stands in for the
  // opencode host + the IdP token endpoint.
  test('readFileStream: 401 → refresh → retry succeeds with fresh token',
      () async {
    final authHeaders = <String>[];
    var fileCalls = 0;
    var refreshCalls = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      if (req.uri.path == '/token') {
        refreshCalls++;
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write('{"access_token":"at-new","refresh_token":"rt-new",'
              '"expires_in":3600}');
        await req.response.close();
        return;
      }
      fileCalls++;
      authHeaders.add(req.headers.value(HttpHeaders.authorizationHeader) ?? '');
      if (fileCalls == 1) {
        req.response.statusCode = 401;
        await req.response.close();
        return;
      }
      req.response
        ..statusCode = 200
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(
            {'type': 'text', 'mimeType': 'text/plain', 'content': 'hello'}));
      await req.response.close();
    });

    final base = 'http://127.0.0.1:${server.port}';
    final store = _FakeStore();
    final p = ConnectionProfile(
      id: 'p1',
      name: 'n',
      address: base,
      authMethod: AuthMethod.oauth,
      accessToken: 'at-old',
      refreshToken: 'rt-old',
      tokenExpiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      oidcIssuer: base,
      tokenEndpoint: '$base/token',
      clientId: 'cid',
    );
    store.db['p1'] = p;
    final client = OpencodeClient(dioFor(p, store: store));

    final file = await client.readFileStream(directory: '/w', path: 'a.txt');
    expect(file.text, 'hello');
    expect(authHeaders, ['Bearer at-old', 'Bearer at-new']);
    expect(refreshCalls, 1);
    expect(store.db['p1']!.accessToken, 'at-new');
  });
}
