import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/models.dart';

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

/// Paginated response from `GET /api/session`.
class ApiSessionList {
  final List<SessionModel> sessions;
  final String? nextCursor;
  const ApiSessionList({required this.sessions, this.nextCursor});
}

/// Thin, hand-written typed client for the opencode HTTP API.
///
/// Spec pinned at `opencode_openapi.json` (see `tool/gen_client.sh`); endpoints
/// are added by hand against v2 types. SSE is handled by `SseClient`.
class OpencodeClient {
  final Dio dio;
  OpencodeClient(this.dio);

  /// `GET /global/health` → `{ healthy, version }`.
  Future<HealthInfo> health() async {
    final r = await dio.get<dynamic>('/global/health');
    return HealthInfo.fromJson(_asMap(r.data));
  }

  /// `GET /project`
  Future<List<ProjectModel>> projects() async =>
      _getModels('/project', ProjectModel.fromJson);

  /// `GET /project/current`
  Future<ProjectModel> currentProject() async {
    final r = await dio.get<dynamic>('/project/current');
    return ProjectModel.fromJson(_asMap(r.data));
  }

  /// `GET /session` (global, unarchived by default)
  Future<List<SessionModel>> sessions() async =>
      _getModels('/session', SessionModel.fromJson);

  /// `GET /session?directory=<path>` — sessions scoped to one project directory.
  Future<List<SessionModel>> sessionsForDirectory(String directory) async {
    final r = await dio.get<dynamic>('/session',
        queryParameters: {'directory': directory});
    return _getModelsFromData(r.data, SessionModel.fromJson);
  }

  /// `GET /api/session` — paginated global session list (all projects).
  Future<ApiSessionList> sessionsAll({String? cursor}) async {
    final q = cursor != null ? {'cursor': cursor} : null;
    final r = await dio.get<dynamic>('/api/session', queryParameters: q);
    final m = _asMap(r.data);
    final data = _getModelsFromData(m['data'], SessionModel.fromJson);
    final cur = m['cursor'];
    return ApiSessionList(
      sessions: data,
      nextCursor: cur is Map ? cur['next']?.toString() : null,
    );
  }

  /// Metadata for a single session.
  /// `GET /api/session/{id}`
  Future<SessionModel> sessionMeta(String sessionId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId');
    return SessionModel.fromJson(_asMap(r.data));
  }

  /// `GET /session/status` → `{ sessionID: {type: idle|busy|retry} }`
  Future<Map<String, SessionStatusValue>> sessionStatus() async {
    final r = await dio.get<dynamic>('/session/status');
    final m = _asMap(r.data);
    return m.map((k, v) => MapEntry(
        k, SessionStatusValue.fromJson(v is Map ? v.cast() : const {})));
  }

  /// `GET /session/:id/message?limit=`
  Future<List<MessageEntry>> messages(String sessionId, {int? limit}) async {
    final r = await dio.get<dynamic>(
      '/session/$sessionId/message',
      queryParameters: limit == null ? null : {'limit': limit},
    );
    return _getModelsFromData(r.data, MessageEntry.fromJson);
  }

  /// `GET /session/:id/message/:messageID`
  Future<MessageEntry> message(String sessionId, String messageId) async {
    final r = await dio.get<dynamic>('/session/$sessionId/message/$messageId');
    return MessageEntry.fromJson(_asMap(r.data));
  }

  /// `GET /session/:id/todo`
  Future<List<Todo>> todos(String sessionId) async {
    final r = await dio.get<dynamic>('/session/$sessionId/todo');
    return _getModelsFromData(r.data, Todo.fromJson);
  }

  /// `POST /session/:id/permissions/:permissionID`
  Future<void> respondPermission(
    String sessionId,
    String permissionId,
    String response, {
    bool? remember,
  }) async {
    await dio.post(
      '/session/$sessionId/permissions/$permissionId',
      data: {
        'response': response,
        // ignore: use_null_aware_elements
        if (remember != null) 'remember': remember,
      },
    );
  }

  // ---- helpers ----

  Future<List<T>> _getModels<T>(
          String path, T Function(Map<String, dynamic>) fromJson) async =>
      _getModelsFromData((await dio.get<dynamic>(path)).data, fromJson);

  List<T> _getModelsFromData<T>(
      dynamic data, T Function(Map<String, dynamic>) fromJson) {
    final list = _asList(data);
    return list.map(fromJson).toList();
  }

  static List<Map<String, dynamic>> _asList(dynamic data) {
    if (data is List) {
      return data
          .map((e) => e is Map ? e.cast<String, dynamic>() : <String, dynamic>{})
          .toList();
    }
    if (data is String && data.trim().isNotEmpty) {
      final d = jsonDecode(data);
      if (d is List) {
        return d
            .map((e) =>
                e is Map ? e.cast<String, dynamic>() : <String, dynamic>{})
            .toList();
      }
    }
    return const [];
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
