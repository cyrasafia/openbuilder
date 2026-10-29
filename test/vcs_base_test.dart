import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';

class _ScriptedAdapter implements HttpClientAdapter {
  final ResponseBody Function(RequestOptions options) respond;
  final List<RequestOptions> requests = [];

  _ScriptedAdapter(this.respond);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return respond(options);
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

void main() {
  test('vcsBase returns ref on 200 with data map', () async {
    final adapter = _ScriptedAdapter((options) => _json(200, {
          'location': const {},
          'data': {
            'name': 'iterate',
            'ref': 'refs/heads/iterate',
            'source': 'reflog',
          },
        }));
    final client = OpencodeClient(Dio(BaseOptions())
      ..httpClientAdapter = adapter
      ..options.validateStatus = (s) => s != null && s < 500);

    final base = await client.vcsBase(directory: '/wt/x');

    expect(base?.ref, 'refs/heads/iterate');
    expect(base?.name, 'iterate');
    expect(base?.source, 'reflog');
    expect(adapter.requests.single.path, '/api/vcs/base');
    expect(adapter.requests.single.queryParameters['location[directory]'],
        '/wt/x');
  });

  test('vcsBase treats 200 with null data as no base', () async {
    final adapter = _ScriptedAdapter(
        (options) => _json(200, {'location': const {}, 'data': null}));
    final client = OpencodeClient(Dio(BaseOptions())
      ..httpClientAdapter = adapter
      ..options.validateStatus = (s) => s != null && s < 500);

    expect(await client.vcsBase(), isNull);
  });

  test('vcsBase swallows error responses (503 no base)', () async {
    final adapter = _ScriptedAdapter((options) => _json(503, {
          '_tag': 'ServiceUnavailableError',
          'message': 'Choose a review base',
          'service': 'vcs',
        }));
    final client = OpencodeClient(Dio(BaseOptions())
      ..httpClientAdapter = adapter
      ..options.validateStatus = (s) => s != null && s < 500);

    expect(await client.vcsBase(), isNull);
  });

  test('diff passes base query through on branch mode', () async {
    Map<String, dynamic>? diffQuery;
    final adapter = _ScriptedAdapter((options) {
      diffQuery = options.queryParameters;
      return _json(200, {
        'location': const {},
        'data': [],
      });
    });
    final client = OpencodeClient(Dio(BaseOptions())
      ..httpClientAdapter = adapter
      ..options.validateStatus = (s) => s != null && s < 500);

    final diffs = await client.diff(
      'ses_1',
      directory: '/wt/x',
      mode: 'branch',
      base: 'refs/heads/iterate',
    );

    expect(diffs, isEmpty);
    expect(diffQuery?['mode'], 'branch');
    expect(diffQuery?['base'], 'refs/heads/iterate');
    expect(diffQuery?['location[directory]'], '/wt/x');
  });

  test('diff omits base query when not provided', () async {
    Map<String, dynamic>? diffQuery;
    final adapter = _ScriptedAdapter((options) {
      diffQuery = options.queryParameters;
      return _json(200, {
        'location': const {},
        'data': [],
      });
    });
    final client = OpencodeClient(Dio(BaseOptions())
      ..httpClientAdapter = adapter
      ..options.validateStatus = (s) => s != null && s < 500);

    await client.diff('ses_1', mode: 'branch');

    expect(diffQuery?.containsKey('base'), isFalse);
  });
}
