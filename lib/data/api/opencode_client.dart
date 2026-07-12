import 'dart:convert';

import 'package:dio/dio.dart';

/// Server health from `GET /global/health`.
class HealthInfo {
  final bool healthy;
  final String version;

  const HealthInfo({required this.healthy, required this.version});

  factory HealthInfo.fromJson(Map<String, dynamic> j) => HealthInfo(
        healthy: j['healthy'] == true,
        version: (j['version'] ?? '').toString(),
      );
}

/// Thin, hand-written typed client for the opencode HTTP API.
///
/// The full OpenAPI spec is pinned at `opencode_openapi.json` (see
/// `tool/gen_client.sh`). Off-the-shelf `dart-dio` generation produced ~8k
/// analyzer warnings on opencode's complex spec, so endpoints are added by hand
/// against the v2 types. SSE is handled separately by `SseClient` (Phase 1).
class OpencodeClient {
  final Dio dio;
  OpencodeClient(this.dio);

  /// `GET /global/health` → `{ healthy, version }`.
  Future<HealthInfo> health() async {
    final r = await dio.get<dynamic>('/global/health');
    return HealthInfo.fromJson(_asMap(r.data));
  }

  static Map<String, dynamic> _asMap(dynamic data) {
    if (data is Map<String, dynamic>) return data;
    if (data is Map) return data.cast<String, dynamic>();
    if (data is String && data.trim().isNotEmpty) {
      final decoded = jsonDecode(data);
      if (decoded is Map) return decoded.cast<String, dynamic>();
    }
    return const {};
  }
}
