import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';

class _Capture {
  String? method;
  String? path;
  Map<String, dynamic>? query;
}

class _Adapter implements HttpClientAdapter {
  final _Capture cap;
  final String body;
  _Adapter(this.cap, {this.body = '[]'});
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cap.method = options.method;
    cap.path = options.path;
    cap.query = options.queryParameters;
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

OpencodeClient _client(_Capture cap, {String body = '[]'}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _Adapter(cap, body: body);
  return OpencodeClient(dio);
}

void main() {
  group('findFiles', () {
    test('parses array of relative path strings into FileNodes', () async {
      final cap = _Capture();
      final res = await _client(
        cap,
        body: jsonEncode([
          'lib/main.dart',
          'lib/features/files/binary_view.dart',
          'lib/',
          'pubspec.yaml',
        ]),
      ).findFiles(directory: '/work', path: '', query: 'lib');

      expect(cap.method, 'GET');
      expect(cap.path, '/find/file');
      expect(cap.query!['directory'], '/work');
      expect(cap.query!['query'], 'lib');

      expect(res, hasLength(4));

      expect(res[0].path, 'lib/main.dart');
      expect(res[0].name, 'main.dart');
      expect(res[0].isDir, isFalse);

      expect(res[1].path, 'lib/features/files/binary_view.dart');
      expect(res[1].name, 'binary_view.dart');
      expect(res[1].isDir, isFalse);

      expect(res[2].path, 'lib/');
      expect(res[2].name, 'lib');
      expect(res[2].isDir, isTrue);

      expect(res[3].path, 'pubspec.yaml');
      expect(res[3].name, 'pubspec.yaml');
      expect(res[3].isDir, isFalse);
    });

    test('scopes by path and re-prefixes results to stay relative to directory',
        () async {
      final cap = _Capture();
      final res = await _client(
        cap,
        body: jsonEncode(['code_view.dart', 'binary_view.dart']),
      ).findFiles(directory: '/work', path: 'lib/features/files', query: 'view');

      // search root is directory + '/' + path
      expect(cap.query!['directory'], '/work/lib/features/files');

      expect(res[0].path, 'lib/features/files/code_view.dart');
      expect(res[0].name, 'code_view.dart');
      expect(res[1].path, 'lib/features/files/binary_view.dart');
      expect(res[1].name, 'binary_view.dart');
    });

    test('empty directory does not produce a leading slash in the search root',
        () async {
      final cap = _Capture();
      await _client(cap).findFiles(directory: '', path: 'lib', query: 'x');
      expect(cap.query!['directory'], 'lib');
    });

    test('drops empty-string entries instead of making phantom nodes',
        () async {
      final cap = _Capture();
      final res = await _client(
        cap,
        body: jsonEncode(['main.dart', '']),
      ).findFiles(directory: '/work', path: '', query: 'x');
      expect(res, hasLength(1));
      expect(res[0].name, 'main.dart');
    });

    test('strips trailing slash from directory when composing the search root',
        () async {
      final cap = _Capture();
      await _client(cap).findFiles(
        directory: '/work/',
        path: 'lib',
        query: 'x',
      );
      expect(cap.query!['directory'], '/work/lib');
    });

    test('returns empty list for non-array payload', () async {
      final cap = _Capture();
      final res = await _client(cap, body: '{}').findFiles(
        directory: '/work',
        path: '',
        query: 'x',
      );
      expect(res, isEmpty);
    });
  });
}
