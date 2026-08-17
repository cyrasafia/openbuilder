import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';

class _Capture {
  String? method;
  String? path;
  Map<String, dynamic>? query;
  Map<String, dynamic>? body;
  Duration? sendTimeout;
}

class _Adapter implements HttpClientAdapter {
  final _Capture cap;
  final String body;
  _Adapter(this.cap, {this.body = '{}'});
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
    cap.sendTimeout = options.sendTimeout;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      final raw = utf8.decode(bytes);
      cap.body = raw.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(raw) as Map<String, dynamic>;
    } else {
      cap.body = <String, dynamic>{};
    }
    return ResponseBody.fromString(body, 200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        });
  }
}

OpencodeClient _client(_Capture cap, {String body = '{}'}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _Adapter(cap, body: body);
  return OpencodeClient(dio);
}

void main() {
  test('command: POST /session/:id/command with command + arguments', () async {
    final cap = _Capture();
    await _client(cap).command('s1', command: 'review');
    expect(cap.method, 'POST');
    expect(cap.path, '/session/s1/command');
    expect(cap.body!['command'], 'review');
    expect(cap.body!['arguments'], '');
    expect(cap.body!.containsKey('agent'), isFalse,
        reason: 'agent must be omitted when null, not sent as JSON null');
    expect(cap.body!.containsKey('parts'), isFalse,
        reason: 'parts must be omitted when empty');
  });

  test('command: forwards directory, agent, arguments, parts', () async {
    final cap = _Capture();
    await _client(cap).command(
      's1',
      directory: '/work',
      agent: 'build',
      command: 'review',
      arguments: 'HEAD~1',
      parts: [
        {
          'type': 'file',
          'mime': 'image/png',
          'url': 'data:image/png;base64,AAAA',
          'filename': 'a.png',
        },
      ],
    );
    expect(cap.query!['directory'], '/work');
    expect(cap.body!['agent'], 'build');
    expect(cap.body!['arguments'], 'HEAD~1');
    expect(cap.body!['parts'], [
      {
        'type': 'file',
        'mime': 'image/png',
        'url': 'data:image/png;base64,AAAA',
        'filename': 'a.png',
      },
    ]);
  });

  test('command: sendTimeout reaches the dio RequestOptions', () async {
    final cap = _Capture();
    await _client(cap).command(
      's1',
      command: 'review',
      sendTimeout: const Duration(seconds: 120),
    );
    expect(cap.sendTimeout, const Duration(seconds: 120));
  });

  test('getMergedCommands: GET /command bare array with source field', () async {
    final cap = _Capture();
    final mergedJson = jsonEncode([
      {'name': 'init', 'description': 'setup AGENTS.md', 'source': 'command'},
      {'name': 'grilling', 'description': 'stress-test plans', 'source': 'skill'},
    ]);
    final res =
        await _client(cap, body: mergedJson).getMergedCommands(directory: '/w');
    expect(cap.method, 'GET');
    expect(cap.path, '/command');
    expect(cap.query!['directory'], '/w');
    expect(res, hasLength(2));
    expect(res[0].name, 'init');
    expect(res[0].source, 'command');
    expect(res[1].name, 'grilling');
    expect(res[1].isSkill, isTrue);
  });

  test('getMergedCommands: omits directory when absent', () async {
    final cap = _Capture();
    await _client(cap, body: '[]').getMergedCommands();
    expect(cap.path, '/command');
    expect(cap.query, isEmpty);
  });
}
