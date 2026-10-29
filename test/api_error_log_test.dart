import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/auth_code_client.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/logging/app_logger.dart';
import 'package:open_builder/core/net/dio_factory.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  final Object Function(RequestOptions options) respond;

  _ScriptedAdapter(this.respond);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final result = respond(options);
    if (result is ResponseBody) return result;
    throw result as DioException;
  }
}

class _Replay401Adapter implements HttpClientAdapter {
  int apiCalls = 0;

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
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    apiCalls++;
    return _json(401, {'_tag': 'UnauthorizedError', 'message': 'bad token'});
  }
}

ResponseBody _json(int status, Map<String, dynamic> body) {
  return ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );
}

Dio _dio(Object Function(RequestOptions) respond) {
  final profile = ConnectionProfile(
    id: 'p1',
    name: 'test',
    address: 'http://localhost:15120',
    password: 'pw',
  );
  final dio = dioFor(profile);
  dio.httpClientAdapter = _ScriptedAdapter(respond);
  return dio;
}

void main() {
  setUp(() {
    AppLogger.resetForTesting();
  });

  List<String> apiLines() => AppLogger.I
      .exportRecent(const Duration(minutes: 1))
      .where((e) => e.tag == 'Api')
      .map((e) => e.message)
      .toList();

  test('badResponse logs method url query status and error tag/message',
      () async {
    final dio = _dio((options) => _json(503, {
          '_tag': 'ServiceUnavailableError',
          'message': 'No merge base available for origin/develop',
          'service': 'vcs',
        }));
    await expectLater(
      dio.get<dynamic>('/api/vcs/diff',
          queryParameters: {'mode': 'branch', 'location[directory]': '/d'}),
      throwsA(isA<DioException>()),
    );
    final lines = apiLines();
    expect(lines, hasLength(1));
    expect(
      lines.single,
      'GET http://localhost:15120/api/vcs/diff?mode=branch'
      '&location[directory]=/d -> 503 '
      'ServiceUnavailableError No merge base available for origin/develop',
    );
  });

  test('auth_token query is never logged', () async {
    final dio = _dio((options) => _json(404, {'_tag': 'FileNotFoundError'}));
    await expectLater(
      dio.get<dynamic>('/api/fs/read',
          queryParameters: {'auth_token': 'secret', 'path': 'a.txt'}),
      throwsA(isA<DioException>()),
    );
    final line = apiLines().single;
    expect(
        line, contains('GET http://localhost:15120/api/fs/read?path=a.txt'));
    expect(line, isNot(contains('secret')));
  });

  test('connection errors are not logged', () async {
    final dio = _dio((options) => DioException.connectionError(
          reason: 'refused',
          requestOptions: options,
        ));
    await expectLater(
      dio.get<dynamic>('/api/info'),
      throwsA(isA<DioException>()),
    );
    expect(apiLines(), isEmpty);
  });

  test('timeouts are not logged', () async {
    final dio = _dio((options) => DioException.receiveTimeout(
          timeout: const Duration(seconds: 1),
          requestOptions: options,
        ));
    await expectLater(
      dio.get<dynamic>('/api/info'),
      throwsA(isA<DioException>()),
    );
    expect(apiLines(), isEmpty);
  });

  test('statuses accepted by validateStatus produce no log', () async {
    final dio = _dio((options) => _json(401, {'_tag': 'UnauthorizedError'}));
    await expectLater(
      dio.get<dynamic>('/probe',
          options: Options(validateStatus: (s) => true)),
      completes,
    );
    expect(apiLines(), isEmpty);
  });

  test('multi-line non-map bodies collapse to a single capped line', () async {
    final dio = _dio((options) =>
        ResponseBody.fromString('plain\nerror\r\ndetail' * 30, 500));
    await expectLater(
      dio.get<dynamic>('/api/x'),
      throwsA(isA<DioException>()),
    );
    final line = apiLines().single;
    expect(line, isNot(contains('\n')));
    expect(line.length, lessThan(300));
  });

  test('oauth 401 refresh-replay-still-401 logs the request exactly once',
      () async {
    final adapter = _Replay401Adapter();
    final tokenDio = Dio(BaseOptions(baseUrl: 'http://authstub.test'))
      ..httpClientAdapter = adapter;
    final profile = ConnectionProfile(
      id: 'p1',
      name: 'n',
      address: 'http://api.test',
      authMethod: AuthMethod.oauth,
      accessToken: 'at-old',
      refreshToken: 'rt-old',
      oidcIssuer: 'https://auth.test',
      tokenEndpoint: 'http://authstub.test/token',
      clientId: 'cid',
    );
    final dio = Dio(BaseOptions(baseUrl: 'http://api.test'))
      ..httpClientAdapter = adapter;
    dio.interceptors.add(AuthInterceptor(dio, profile,
        tokenClient: AuthCodeClient(dio: tokenDio)));
    dio.interceptors.add(ApiErrorLogInterceptor());

    await expectLater(
      dio.get<dynamic>('/data'),
      throwsA(isA<DioException>()),
    );
    expect(adapter.apiCalls, 2, reason: 'original + one replay after refresh');
    final lines = apiLines();
    expect(lines, hasLength(1));
    expect(lines.single,
        startsWith('GET http://api.test/data -> 401 UnauthorizedError'));
  });
}
