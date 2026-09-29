import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/data/api/opencode_client.dart';

// 巨型会话（如日志 dump / 目录扫描分析会话）单页消息 JSON 可达数十 MB。
// messagesPageCompute 用流式有界读取防护：Content-Length 头超限提前中止
// （不落地响应体），流式累计字节超限在传输中中止——超限抛
// MessagePageTooLargeException 走 reconcile 的终态路径（报错不崩、不重试），
// 而不是把进程拖进 LMK。

class _Adapter implements HttpClientAdapter {
  final Future<ResponseBody> Function() respond;
  _Adapter({required this.respond});
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return respond();
  }
}

OpencodeClient _client(Future<ResponseBody> Function() respond) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _Adapter(respond: respond);
  return OpencodeClient(dio);
}

OpencodeClient _stringClient(String body) => _client(() async {
      return ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });
    });

String _pageJson(List<Map<String, dynamic>> messages,
        {String? next, String? previous}) =>
    jsonEncode({
      'data': messages,
      'cursor': {'next': next, 'previous': previous},
    });

const _userMsg = {
  'id': 'msg_1',
  'type': 'user',
  'time': {'created': 1790599000000},
  'text': 'hello',
};

void main() {
  test('pages under the limit parse normally (reversed + cursors)', () async {
    final page = await _stringClient(_pageJson([
      {..._userMsg, 'id': 'msg_1'},
      {..._userMsg, 'id': 'msg_2'},
    ], next: 'c_older')).messagesPageCompute('ses_x', limit: 100);

    expect(page.entries.map((e) => e.id).toList(), ['msg_2', 'msg_1'],
        reason: 'compute decode is server order; caller re-reverses to asc');
    expect(page.olderCursor, 'c_older');
    expect(page.newerCursor, isNull);
  });

  test('streamed bytes beyond kMaxMessagePageBytes abort mid-transfer',
      () async {
    final filler = 'x' * (kMaxMessagePageBytes + 1);
    final client = _stringClient('{"data":[],"pad":"$filler"}');

    final err = await _capture(() =>
        client.messagesPageCompute('ses_x', limit: 100));
    expect(err, isA<MessagePageTooLargeException>());
    expect(err.toString(), allOf(contains('too large'), contains('sid=ses_x')));
  });

  test('oversized Content-Length header aborts before the body streams',
      () async {
    final declared = kMaxMessagePageBytes + 12345;
    final client = _client(() async {
      return ResponseBody(
        Stream.value(Uint8List(0)),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          Headers.contentLengthHeader: ['$declared'],
        },
      );
    });

    final err =
        await _capture(() => client.messagesPageCompute('ses_x', limit: 100));
    expect(
        err,
        isA<MessagePageTooLargeException>()
            .having((e) => e.size, 'size', declared),
        reason: 'header path reports the declared length');
  });

  test('limit boundary: exactly kMaxMessagePageBytes still parses', () async {
    const base = '{"data":[],"pad":""}';
    final body =
        '{"data":[],"pad":"${'x' * (kMaxMessagePageBytes - base.length)}"}';
    expect(body.length, kMaxMessagePageBytes);

    final page =
        await _stringClient(body).messagesPageCompute('ses_x', limit: 100);
    expect(page.entries, isEmpty);
  });

  test('multi-byte content is bounded by wire bytes, not decoded chars',
      () async {
    final cjk = '中' * (kMaxMessagePageBytes ~/ 3 + 2);
    final body = _pageJson([
      {..._userMsg, 'text': cjk}
    ]);
    expect(body.length, lessThan(kMaxMessagePageBytes),
        reason: 'setup guard: decoded chars stay under the limit');
    final err = await _capture(
        () => _stringClient(body).messagesPageCompute('ses_x', limit: 100));
    expect(err, isA<MessagePageTooLargeException>(),
        reason: 'UTF-8 wire size (3 bytes/char) exceeds the byte cap');
  });
}

Future<Object?> _capture(Future<void> Function() fn) async {
  try {
    await fn();
    return null;
  } catch (e) {
    return e;
  }
}
