import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/data/api/opencode_client.dart';

/// Captures the last PATCH body and path sent through the Dio instance.
class _Capture {
  String? lastPath;
  String? lastMethod;
  Map<String, dynamic>? lastBody;
}

HttpClientAdapter _capturingAdapter(_Capture cap) => _CaptureAdapter(cap);

class _CaptureAdapter implements HttpClientAdapter {
  final _Capture cap;
  _CaptureAdapter(this.cap);

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    cap.lastMethod = options.method;
    cap.lastPath = options.path;
    if (requestStream != null) {
      final bytes = <int>[];
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
      final raw = utf8.decode(bytes);
      cap.lastBody =
          raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw) as Map<String, dynamic>;
    } else {
      cap.lastBody = <String, dynamic>{};
    }
    return ResponseBody.fromString(
      _minimalProject,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

const _minimalProject = '{"id":"test","worktree":"/tmp","time":{"created":0,"updated":0},"sandboxes":[]}';

OpencodeClient _client(_Capture cap) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _capturingAdapter(cap);
  return OpencodeClient(dio);
}

void main() {
  test('updateProject: null icon fields are omitted (no JSON null sent)', () async {
    final cap = _Capture();
    await _client(cap).updateProject(
      'p1',
      updateIcon: true,
      iconUrl: null,
      iconOverride: 'data:image/png;base64,AAAA',
      iconColor: null,
    );
    expect(cap.lastMethod, 'PATCH');
    expect(cap.lastPath, '/project/p1');
    final icon = cap.lastBody!['icon'] as Map<String, dynamic>;
    expect(icon.containsKey('url'), isFalse,
        reason: 'null iconUrl must be omitted, not sent as JSON null');
    expect(icon.containsKey('color'), isFalse,
        reason: 'null iconColor must be omitted, not sent as JSON null');
    expect(icon['override'], 'data:image/png;base64,AAAA');
  });

  test('updateProject: empty-string fields are sent (clear semantics)', () async {
    final cap = _Capture();
    await _client(cap).updateProject(
      'p1',
      updateIcon: true,
      iconOverride: '',
      iconColor: '',
    );
    final icon = cap.lastBody!['icon'] as Map<String, dynamic>;
    expect(icon['override'], '');
    expect(icon['color'], '');
    expect(icon.containsKey('url'), isFalse);
  });

  test('updateProject: updateIcon=false omits the icon key entirely', () async {
    final cap = _Capture();
    await _client(cap).updateProject('p1', name: 'new');
    expect(cap.lastBody!.containsKey('icon'), isFalse);
    expect(cap.lastBody!['name'], 'new');
  });

  test('updateProject: iconUrl pass-through includes url key', () async {
    final cap = _Capture();
    await _client(cap).updateProject(
      'p1',
      updateIcon: true,
      iconUrl: 'https://example.com/a.png',
      iconOverride: null,
      iconColor: null,
    );
    final icon = cap.lastBody!['icon'] as Map<String, dynamic>;
    expect(icon['url'], 'https://example.com/a.png');
    expect(icon.containsKey('override'), isFalse);
    expect(icon.containsKey('color'), isFalse);
  });
}
