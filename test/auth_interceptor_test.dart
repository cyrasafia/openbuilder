import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/connection/connection_store.dart';
import 'package:open_builder/core/net/dio_factory.dart';

class _FakeStore extends ConnectionStore {
  final Map<String, ConnectionProfile> db = {};
  final Set<String> broken = {};

  @override
  ConnectionProfile? byId(String id) => db[id];

  @override
  Future<void> update(ConnectionProfile p) async => db[p.id] = p;

  @override
  bool isAuthBroken(String id) => broken.contains(id);

  @override
  void markAuthBroken(String id) => broken.add(id);

  @override
  void clearAuthBroken(String id) => broken.remove(id);
}

class _AuthAdapter implements HttpClientAdapter {
  int apiCalls = 0;
  int refreshCalls = 0;
  final List<String> authHeaders = [];
  int failFirstWith401;
  bool refreshFailsTransiently = false;

  _AuthAdapter({this.failFirstWith401 = 0});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    final auth = options.headers['Authorization']?.toString() ?? '';
    if (path == '/token') {
      refreshCalls++;
      if (refreshFailsTransiently) {
        throw DioException.connectionError(
            requestOptions: options, reason: 'auth host unreachable');
      }
      await Future.delayed(const Duration(milliseconds: 30));
      return ResponseBody.fromString(
          '{"access_token":"at-new","refresh_token":"rt-new","expires_in":3600}',
          200,
          headers: {
            Headers.contentTypeHeader: ['application/json'],
          });
    }
    apiCalls++;
    authHeaders.add(auth);
    if (apiCalls <= failFirstWith401) {
      return ResponseBody.fromString('{"error":"unauthorized"}', 401);
    }
    return ResponseBody.fromString('{"ok":true}', 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

/// Token endpoint that always answers 400 `invalid_grant` — the definitive
/// credential-dead signal.
class _RejectingTokenAdapter implements HttpClientAdapter {
  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    throw DioException.badResponse(
      statusCode: 400,
      requestOptions: options,
      response: Response(
          requestOptions: options, data: '{"error":"invalid_grant"}'),
    );
  }
}

ConnectionProfile _profile({
  int? expiresInMs,
  String refreshToken = 'rt-old',
}) {
  return ConnectionProfile(
    id: 'p1',
    name: 'n',
    address: 'http://api.test',
    authMethod: AuthMethod.oauth,
    accessToken: 'at-old',
    refreshToken: refreshToken,
    tokenExpiresAt: expiresInMs == null
        ? null
        : DateTime.now().millisecondsSinceEpoch + expiresInMs,
    oidcIssuer: 'https://auth.test',
    tokenEndpoint: 'http://authstub.test/token',
    clientId: 'cid',
  );
}

Dio _apiDio(_AuthAdapter adapter, ConnectionProfile p, _FakeStore store) {
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
  test('401 → refresh once → retry with new token → store updated',
      () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 3600000);
    final adapter = _AuthAdapter(failFirstWith401: 1);
    final dio = _apiDio(adapter, store.db['p1']!, store);

    final resp = await dio.get<Object>('/data');
    expect(resp.statusCode, 200);
    expect(adapter.refreshCalls, 1, reason: 'exactly one refresh');
    expect(adapter.authHeaders.last, 'Bearer at-new',
        reason: 'retry carries the refreshed token');
    expect(store.db['p1']!.accessToken, 'at-new');
    expect(store.db['p1']!.refreshToken, 'rt-new');
    expect(store.broken, isEmpty);
  });

  test('401 with no refresh token → authBroken, no retry', () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 3600000, refreshToken: '');
    final adapter = _AuthAdapter(failFirstWith401: 5);
    final dio = _apiDio(adapter, store.db['p1']!, store);

    await expectLater(dio.get<Object>('/data'), throwsA(isA<DioException>()));
    expect(adapter.apiCalls, 1, reason: 'no retry without refresh token');
    expect(store.broken, contains('p1'));
  });

  test('near expiry → proactive refresh before the request is sent',
      () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 30000); // 30s < 60s slack
    final adapter = _AuthAdapter();
    final dio = _apiDio(adapter, store.db['p1']!, store);

    final resp = await dio.get<Object>('/data');
    expect(resp.statusCode, 200);
    expect(adapter.refreshCalls, 1);
    expect(adapter.authHeaders.single, 'Bearer at-new',
        reason: 'the very first request already carries the fresh token');
    expect(adapter.apiCalls, 1);
  });

  test('single-flight: concurrent requests trigger one refresh only',
      () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 30000);
    final adapter = _AuthAdapter();
    final dio = _apiDio(adapter, store.db['p1']!, store);

    final results =
        await Future.wait([dio.get<Object>('/a'), dio.get<Object>('/b')]);
    expect(results.every((r) => r.statusCode == 200), isTrue);
    expect(adapter.refreshCalls, 1,
        reason: 'both requests share one in-flight refresh');
    expect(adapter.authHeaders.toSet(), {'Bearer at-new'});
  });

  test('transient refresh failure: no authBroken, no retry, original 401 propagates',
      () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 3600000);
    final adapter = _AuthAdapter(failFirstWith401: 1)
      ..refreshFailsTransiently = true;
    final dio = _apiDio(adapter, store.db['p1']!, store);

    await expectLater(dio.get<Object>('/data'), throwsA(isA<DioException>()));
    expect(adapter.refreshCalls, 1);
    expect(store.broken, isEmpty,
        reason: 'network blip at the token endpoint must not flag the profile');
    expect(store.db['p1']!.refreshToken, 'rt-old',
        reason: 'persisted tokens untouched');
  });

  test('definitive refresh rejection (4xx) → authBroken', () async {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 30000); // forces proactive refresh
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'));
    dio.interceptors.add(AuthInterceptor(dio, store.db['p1']!,
        store: store,
        tokenClient: AuthCodeClient(
            dio: Dio(BaseOptions(baseUrl: 'http://authstub.test'))
              ..httpClientAdapter = _RejectingTokenAdapter())));

    await expectLater(dio.get<Object>('/data'), throwsA(isA<DioException>()));
    expect(store.broken, contains('p1'),
        reason: 'invalid_grant is a definitive credential failure');
  });

  test('basic profile: header attached, no interceptor lifecycle', () {
    final dio = dioFor(ConnectionProfile(
      id: 'b',
      name: 'n',
      address: 'http://api.test',
      authMethod: AuthMethod.basic,
      username: 'opencode',
      password: 'pw',
    ));
    expect(dio.options.headers['Authorization'], 'Basic b3BlbmNvZGU6cHc=');
    expect(dio.interceptors.whereType<AuthInterceptor>(), isEmpty);
  });

  test('oauth profile via dioFor gets the AuthInterceptor', () {
    final store = _FakeStore();
    store.db['p1'] = _profile(expiresInMs: 3600000);
    final dio = dioFor(store.db['p1']!, store: store);
    expect(dio.interceptors.whereType<AuthInterceptor>().length, 1);
  });

  test('oauth profile without store fails loudly (release-safe)', () {
    expect(
      () => dioFor(_profile(expiresInMs: 3600000)),
      throwsA(isA<ArgumentError>()),
      reason: 'token rotation must be persisted — omission is a bug',
    );
  });

  test('none profile: no auth header at all', () {
    final dio = dioFor(ConnectionProfile(
        id: 'x', name: 'n', address: 'http://a', authMethod: AuthMethod.none));
    expect(dio.options.headers.containsKey('Authorization'), isFalse);
    expect(dio.interceptors.whereType<AuthInterceptor>(), isEmpty);
  });
}
