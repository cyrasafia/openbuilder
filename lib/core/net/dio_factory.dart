import 'dart:convert';

import 'package:dio/dio.dart';

import '../connection/connection_profile.dart';

/// Builds a configured [Dio] for a [ConnectionProfile] (base URL + basic auth).
Dio dioFor(ConnectionProfile p) {
  final dio = Dio(BaseOptions(
    baseUrl: p.baseUrl,
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 20),
    sendTimeout: const Duration(seconds: 20),
    headers: {'Accept': 'application/json'},
  ));
  if (p.username.isNotEmpty) {
    dio.options.headers['Authorization'] =
        'Basic ${base64Encode(utf8.encode('${p.username}:${p.password}'))}';
  }
  return dio;
}
