import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Builds the [Dio] used for the streamed `/file/content` download.
///
/// Transparent gzip decompression is disabled (`autoUncompress = false`) so the
/// response body is returned gzip-compressed and `onReceiveProgress` reports
/// **pre-decompression** bytes — which match the (possibly compressed)
/// `Content-Length`. That keeps the transfer ratio accurate regardless of
/// whether the server gzips: numerator and denominator always share the same
/// byte scale. The compressed body is reversed afterwards via
/// [decodeDownloadBody].
///
/// `Accept-Encoding: gzip` is advertised explicitly so compression does not
/// depend on dart:io's implicit header injection.
Dio rawDownloadDio(Dio base) {
  final raw = Dio(BaseOptions(
    baseUrl: base.options.baseUrl,
    connectTimeout: base.options.connectTimeout,
    receiveTimeout: base.options.receiveTimeout,
    sendTimeout: base.options.sendTimeout,
    headers: {
      ...base.options.headers,
      'Accept-Encoding': 'gzip',
    },
  ));
  (raw.httpClientAdapter as IOHttpClientAdapter).createHttpClient = () {
    final client = HttpClient();
    client.autoUncompress = false;
    return client;
  };
  return raw;
}

/// Reverses gzip compression on [body] when [contentEncoding] advertises it.
/// Returns [body] unchanged otherwise (e.g. when the server sent it plain).
Uint8List decodeDownloadBody(Uint8List body, String? contentEncoding) {
  if ((contentEncoding ?? '').toLowerCase().contains('gzip')) {
    return Uint8List.fromList(gzip.decode(body));
  }
  return body;
}
