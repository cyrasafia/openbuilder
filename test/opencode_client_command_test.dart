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


class _TwoResponseAdapter implements HttpClientAdapter {
  final _Capture cap;
  final String firstBody;
  final String? secondBody;
  final int secondStatus;
  var calls = 0;

  _TwoResponseAdapter(
    this.cap, {
    required this.firstBody,
    required this.secondBody,
    required this.secondStatus,
  });

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    cap.method = options.method;
    cap.path = options.path;
    cap.query = options.queryParameters;
    if (calls == 1) {
      return ResponseBody.fromString(firstBody, 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });
    }
    final body = secondBody ?? '[]';
    return ResponseBody.fromString(body, secondStatus, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

OpencodeClient _client(_Capture cap, {String body = '{}'}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _Adapter(cap, body: body);
  return OpencodeClient(dio);
}

OpencodeClient _captureTwo(
  _Capture cap, {
  String firstBody = '{}',
  String? secondBody,
  int secondStatus = 200,
}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _TwoResponseAdapter(
      cap,
      firstBody: firstBody,
      secondBody: secondBody,
      secondStatus: secondStatus,
    );
  return OpencodeClient(dio);
}

void main() {
  test('command: POST /api/session/:id/command with name + text', () async {
    final cap = _Capture();
    await _client(cap).command('s1', command: 'review');
    expect(cap.method, 'POST');
    expect(cap.path, '/api/session/s1/command');
    expect(cap.body!['name'], 'review');
    expect(cap.body!['text'], '');
    expect(cap.body!.containsKey('files'), isFalse,
        reason: 'files must be omitted when empty');
  });

  test('command: forwards command name, arguments, files', () async {
    final cap = _Capture();
    await _client(cap).command(
      's1',
      command: 'review',
      arguments: 'HEAD~1',
      files: [
        {
          'uri': 'data:image/png;base64,AAAA',
          'name': 'a.png',
        },
      ],
    );
    expect(cap.body!['name'], 'review');
    expect(cap.body!['text'], 'HEAD~1');
    expect(cap.body!['files'], [
      {
        'uri': 'data:image/png;base64,AAAA',
        'name': 'a.png',
      },
    ]);
  });

  test('prompt: skill invocation carries skills attachment, no agents', () async {
    final cap = _Capture();
    await _client(cap).prompt(
      's1',
      text: '/grilling check my plan',
      skills: [
        {'id': 'grilling', 'name': 'grilling'},
      ],
    );
    expect(cap.method, 'POST');
    expect(cap.path, '/api/session/s1/prompt');
    expect(cap.body!['text'], '/grilling check my plan');
    expect(cap.body!['skills'], [
      {'id': 'grilling', 'name': 'grilling'},
    ]);
    expect(cap.body!.containsKey('agents'), isFalse,
        reason: 'agent selection is session-level; no synthetic mention '
            'attachment on every prompt');
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

  test('getMergedCommands: command + skill merge with skill flag', () async {
    final cap = _Capture();
    final cmdJson = jsonEncode({
      'location': {'directory': '/w'},
      'data': [
        {'name': 'init', 'description': 'setup AGENTS.md'},
      ],
    });
    final skillJson = jsonEncode({
      'location': {'directory': '/w'},
      'data': [
        {'id': 'grilling', 'name': 'grilling', 'description': 'stress-test plans'},
      ],
    });
    final res = await _captureTwo(
      cap,
      firstBody: cmdJson,
      secondBody: skillJson,
    ).getMergedCommands(directory: '/w');
    expect(res, hasLength(2));
    expect(res[0].name, 'init');
    expect(res[0].skill, isFalse);
    expect(res[1].name, 'grilling');
    expect(res[1].skill, isTrue);
  });

  test('getMergedCommands: skill fetch failure degrades to commands only',
      () async {
    final cap = _Capture();
    final cmdJson = jsonEncode({
      'location': {'directory': '/w'},
      'data': [
        {'name': 'init', 'description': 'setup AGENTS.md'},
      ],
    });
    final res = await _captureTwo(
      cap,
      firstBody: cmdJson,
      secondStatus: 500,
    ).getMergedCommands(directory: '/w');
    expect(res, hasLength(1));
    expect(res[0].name, 'init');
  });
}
