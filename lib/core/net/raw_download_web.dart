import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'dio_factory.dart';

/// Web variant. The browser owns HTTP decompression and there is no hook to
/// count pre-decompression bytes, so the body is returned uncompressed and
/// [decodeDownloadBody] is a no-op. A fresh [Dio] copy (mirroring the native
/// variant) is returned so the caller can always close it.
Dio rawDownloadDio(Dio base) {
  final raw = Dio(BaseOptions(
    baseUrl: base.options.baseUrl,
    connectTimeout: base.options.connectTimeout,
    receiveTimeout: base.options.receiveTimeout,
    sendTimeout: base.options.sendTimeout,
    headers: Map<String, dynamic>.from(base.options.headers),
  ));
  copyInterceptors(base, raw);
  return raw;
}

Uint8List decodeDownloadBody(Uint8List body, String? contentEncoding) => body;
