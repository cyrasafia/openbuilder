import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Emits one item per SSE event, joining multi-line `data:` payloads.
///
/// Native (dart:io) transport using a streamed dio response. The caller
/// reconnects on done/error (see `SseClient`).
Stream<String> eventDataStream(Uri uri, Map<String, String> headers) async* {
  final dio = Dio(BaseOptions(
    responseType: ResponseType.stream,
    headers: headers,
    connectTimeout: const Duration(seconds: 15),
  ));
  final resp = await dio.getUri<dynamic>(uri);
  if (resp.data is! ResponseBody) {
    throw StateError('Expected a streamed response');
  }
  final body = resp.data as ResponseBody;
  final buffer = StringBuffer();
  final dataLines = <String>[];

  await for (final chunk in body.stream) {
    buffer.write(utf8.decode(chunk));
    String text = buffer.toString();
    int lastNewline = text.lastIndexOf('\n');
    String process = text;
    if (lastNewline == -1) {
      continue; // wait for a full line
    } else {
      process = text.substring(0, lastNewline + 1);
      buffer.clear();
      buffer.write(text.substring(lastNewline + 1));
    }
    for (final raw in process.split('\n')) {
      final line = raw.endsWith('\r') ? raw.substring(0, raw.length - 1) : raw;
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          yield dataLines.join('\n');
          dataLines.clear();
        }
        continue;
      }
      if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
      } else if (line.startsWith('data')) {
        dataLines.add(line.substring(4).replaceFirst(RegExp(r'^ '), ''));
      }
      // `event:`, `id:`, comments ignored (id tracked from payload in SseClient)
    }
  }
  // flush trailing
  if (dataLines.isNotEmpty) yield dataLines.join('\n');
}
