import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';

class _Capture {
  String? method;
  String? path;
  Map<String, dynamic>? query;
  Uri? uri;
}

class _Adapter implements HttpClientAdapter {
  final _Capture cap;
  final String body;
  final int status;
  _Adapter(this.cap, {this.body = '', this.status = 200});
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
    cap.uri = options.uri;
    return ResponseBody.fromString(body, status, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

OpencodeClient _client(_Capture cap, {String body = '', int status = 200}) =>
    OpencodeClient(Dio()..httpClientAdapter = _Adapter(cap, body: body, status: status));

void main() {
  group('OpencodeClient.evictLocation', () {
    test('DELETE /api/debug/location with deepObject query (spec anchor)',
        () async {
      final cap = _Capture();
      final client = _client(cap, status: 204);

      await client.evictLocation('/srv/worktrees/feature');

      expect(cap.method, 'DELETE');
      expect(cap.path, '/api/debug/location');
      expect(cap.query, {'location[directory]': '/srv/worktrees/feature'});
      // 线上字节形态（三轮评审 nit 加固）：断言编码后的完整 query——键形
      // `location%5Bdirectory%5D=` 须与 server 端 requestRef 的解析
      // （`location[directory]`）逐字节对齐，dio 序列化行为漂移在此拦截
      expect(
        cap.uri!.query,
        'location%5Bdirectory%5D=%2Fsrv%2Fworktrees%2Ffeature',
      );
    });
  });

  group('OpencodeClient.listWarmLocationDirectories', () {
    test('GET /api/debug/location parses the bare array', () async {
      final cap = _Capture();
      final client = _client(
        cap,
        body: '[{"directory":"/a"},{"directory":"/b"}]',
      );

      final dirs = await client.listWarmLocationDirectories();

      expect(cap.method, 'GET');
      expect(cap.path, '/api/debug/location');
      expect(dirs, {'/a', '/b'});
    });

    test('skips non-map entries and missing/empty directory fields',
        () async {
      final cap = _Capture();
      final client = _client(
        cap,
        body: '[{"directory":"/a"},{"workspaceID":"w"},'
            '{"directory":""},{"directory":null},"str"]',
      );

      final dirs = await client.listWarmLocationDirectories();

      expect(dirs, {'/a'});
    });

    test('non-array payload yields an empty set', () async {
      final cap = _Capture();
      final client = _client(cap, body: '{"unexpected":true}');

      final dirs = await client.listWarmLocationDirectories();

      expect(dirs, isEmpty);
    });
  });
}
