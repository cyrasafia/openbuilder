import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

/// Emits one item per SSE event, joining multi-line `data:` payloads.
///
/// Native (dart:io) transport using a streamed dio response. The caller
/// reconnects on done/error (see `SseClient`).
///
/// [overallTimeout] bounds the connect attempt (connection + response
/// headers). A server that accepts TCP but never sends response headers
/// (e.g., overloaded) would otherwise hang until the caller's heartbeat
/// backstop.
///
/// **Dual-timeout interaction (critical, do NOT remove `SseClient._connectTimer`)**:
/// `SseClient._connectTimer` and this `.timeout()` share the same duration.
/// `SseClient._connectTimer` is created FIRST (in `_connect()`, before the
/// transport call), so it consistently fires first: it cancels the stream
/// subscription, and the async* generator's `await responseFuture.timeout(...)`
/// is interrupted by the async* cancellation machinery, which DISCARDS the
/// TimeoutException this `.timeout()` would otherwise emit. If
/// `SseClient._connectTimer` were removed, this TimeoutException would
/// propagate through the async* generator's error channel into the zone
/// (which flutter_test flags as an unhandled error even when onError catches
/// it). So `_connectTimer` is load-bearing, not redundant.
///
/// On timeout, the abandoned request's eventual error is handled by the
/// pre-registered catchError — not orphaned.
Stream<String> eventDataStream(Uri uri, Map<String, String> headers,
    {Duration overallTimeout = const Duration(seconds: 15)}) async* {
  final dio = Dio(BaseOptions(
    responseType: ResponseType.stream,
    headers: headers,
    connectTimeout: const Duration(seconds: 15),
  ));
  // Pre-register an error handler so the abandoned request's eventual error
  // (after the timeout fires) is handled, not orphaned as a zone error.
  final responseFuture = dio.getUri<dynamic>(uri);
  responseFuture.catchError((Object e) => Response<dynamic>(
      requestOptions: RequestOptions(path: uri.toString())));
  final Response<dynamic> resp;
  try {
    resp = await responseFuture.timeout(overallTimeout);
  } on TimeoutException {
    // Defensive dead code: in practice SseClient._connectTimer fires first
    // and cancels this generator before the transport timer runs (see the
    // dual-timeout note in the doc comment above), so this branch is never
    // reached. Kept as a safety net: if the ordering ever flips, converting
    // the timeout to a normal stream close (onDone → reconnect) avoids the
    // TimeoutException escaping through the async* error channel into the zone.
    return;
  }
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
