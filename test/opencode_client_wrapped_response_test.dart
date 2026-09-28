import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// v2 single-object GET/POST endpoints wrap their payloads as {"data": {...}}
// (verified against a live 2.0.18 server). These tests lock the unwrap: a
// regression that parses the outer envelope yields empty ids — the bug behind
// "GoException: no routes for location: /session" (createSession returned an
// empty id, so the router saw /session/<empty>).

const _wrappedSession = {
  'data': {
    'id': 'ses_f17fade33ffekngOsLb8DlwtSi',
    'projectID': 'p1',
    'cost': 0,
    'tokens': {
      'input': 0,
      'output': 0,
      'reasoning': 0,
      'cache': {'read': 0, 'write': 0},
    },
    'time': {
      'created': 1790599000000,
      'updated': 1790599000000,
    },
    'location': {'directory': '/repo'},
  },
};

const _wrappedMessage = {
  'data': {
    'id': 'msg_probe1',
    'type': 'user',
    'time': {'created': 1790599000001},
    'text': 'hello',
  },
};

class _Capture {
  String? method;
  String? path;
  Map<String, dynamic>? body;
}

class _Adapter implements HttpClientAdapter {
  final _Capture cap;
  final String body;
  _Adapter(this.cap, {required this.body});
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
    if (options.data != null) cap.body = Map<String, dynamic>.of(options.data);
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

OpencodeClient _client(_Capture cap, {required String body}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _Adapter(cap, body: body);
  return OpencodeClient(dio);
}

void main() {
  test('createSession unwraps {"data": {...}} and returns the real id', () async {
    final cap = _Capture();
    final s = await _client(cap, body: jsonEncode(_wrappedSession))
        .createSession('/repo', title: 't');
    expect(cap.method, 'POST');
    expect(cap.path, '/api/session');
    expect(cap.body!['location'], {'directory': '/repo'});
    expect(cap.body!['title'], 't');
    expect(s.id, 'ses_f17fade33ffekngOsLb8DlwtSi',
        reason: 'empty id here produced GoException no routes for /session');
    expect(s.directory, '/repo');
    expect(s.projectID, 'p1');
  });

  test('createSession omits the title key when absent', () async {
    final cap = _Capture();
    await _client(cap, body: jsonEncode(_wrappedSession))
        .createSession('/repo');
    expect(cap.body!.containsKey('title'), isFalse);
  });

  test('sessionMeta unwraps the envelope', () async {
    final cap = _Capture();
    final s = await _client(cap, body: jsonEncode(_wrappedSession))
        .sessionMeta('ses_f17fade33ffekngOsLb8DlwtSi');
    expect(cap.method, 'GET');
    expect(cap.path, '/api/session/ses_f17fade33ffekngOsLb8DlwtSi');
    expect(s.id, 'ses_f17fade33ffekngOsLb8DlwtSi');
    expect(s.directory, '/repo');
  });

  test('message unwraps the envelope', () async {
    final cap = _Capture();
    final m = await _client(cap, body: jsonEncode(_wrappedMessage))
        .message('ses_x', 'msg_probe1');
    expect(cap.path, '/api/session/ses_x/message/msg_probe1');
    expect(m, isA<UserMessage>());
    final user = m as UserMessage;
    expect(user.text, 'hello');
  });

  test('bare (unwrapped) single-object responses still parse', () async {
    final cap = _Capture();
    final s = await _client(
      cap,
      body: jsonEncode(_wrappedSession['data']),
    ).sessionMeta('ses_f17fade33ffekngOsLb8DlwtSi');
    expect(s.id, 'ses_f17fade33ffekngOsLb8DlwtSi');
  });
}
