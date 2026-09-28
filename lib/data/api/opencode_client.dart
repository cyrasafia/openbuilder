import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../core/net/raw_download.dart'
    if (dart.library.html) '../../core/net/raw_download_web.dart'
    as raw_download;
import '../../domain/models.dart';

class MessagesPage {
  final List<SessionMessage> entries;
  final String? olderCursor;
  final String? newerCursor;
  const MessagesPage(this.entries, this.olderCursor, this.newerCursor);
}

class HealthInfo {
  final bool healthy;
  final String version;

  const HealthInfo({required this.healthy, required this.version});

  factory HealthInfo.fromJson(Map<String, dynamic> j) => HealthInfo(
        healthy: j['healthy'] != false,
        version: (j['version'] ?? '').toString(),
      );
}

class OpencodeClient {
  final Dio dio;
  OpencodeClient(this.dio);

  static const int _defaultListLimit = 1000;

  Map<String, dynamic> _locationQuery(String? directory) =>
      directory == null || directory.isEmpty
          ? const {}
          : {'location[directory]': directory};

  Future<HealthInfo> health() async {
    final r = await dio.get<dynamic>('/api/info');
    return HealthInfo.fromJson(_asMap(r.data));
  }

  Future<Map<String, dynamic>> info() async {
    final r = await dio.get<dynamic>('/api/info');
    return _asMap(r.data);
  }

  Future<ProjectModel?> currentLocationProject() async {
    final r = await dio.get<dynamic>('/api/location');
    final d = _asMap(r.data);
    final project = d['project'];
    if (project is! Map) return null;
    return ProjectModel.fromJson(project.cast<String, dynamic>());
  }

  Future<List<ProjectModel>> projects() async {
    final r = await dio.get<dynamic>('/api/project');
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => ProjectModel.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<ProjectModel> updateProject(
    String projectId, {
    String? canonical,
    String? name,
    bool updateIcon = false,
    String? iconUrl,
    String? iconOverride,
    String? iconColor,
  }) async {
    final body = <String, dynamic>{'projectID': projectId};
    if (canonical != null) body['canonical'] = canonical;
    if (name != null) body['name'] = name;
    if (updateIcon) {
      final icon = <String, dynamic>{};
      if (iconUrl != null) icon['url'] = iconUrl;
      if (iconOverride != null) icon['override'] = iconOverride;
      if (iconColor != null) icon['color'] = iconColor;
      body['icon'] = icon;
    }
    final r = await dio.patch<dynamic>('/api/project/$projectId', data: body);
    return ProjectModel.fromJson(_asMap(r.data));
  }

  Future<List<SessionModel>> sessions({
    String? directory,
    String? project,
    String? subpath,
    int limit = _defaultListLimit,
    String? search,
    String? parentID,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (directory != null && directory.isNotEmpty) {
      params['directory'] = directory;
    }
    if (project != null && project.isNotEmpty) params['project'] = project;
    if (subpath != null && subpath.isNotEmpty) params['subpath'] = subpath;
    if (search != null && search.isNotEmpty) params['search'] = search;
    if (parentID != null) params['parentID'] = parentID;
    final r = await dio.get<dynamic>('/api/session', queryParameters: params);
    final data = _asMap(r.data)['data'];
    final list = data is List ? data : const [];
    return list
        .whereType<Map>()
        .map((e) => SessionModel.fromJson(e.cast<String, dynamic>()))
        .where((s) => s.archived == null)
        .toList();
  }

  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = _defaultListLimit}) async {
    return sessions(directory: directory, limit: limit);
  }

  Future<SessionModel> sessionMeta(String sessionId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId');
    return SessionModel.fromJson(_asMap(r.data));
  }

  Future<SessionModel> createSession(String directory, {String? title}) async {
    final body = <String, dynamic>{
      'location': {'directory': directory},
    };
    if (title != null && title.isNotEmpty) body['title'] = title;
    final r = await dio.post<dynamic>('/api/session', data: body);
    return SessionModel.fromJson(_asMap(r.data));
  }

  Future<void> deleteSession(String sessionId) async {
    await dio.delete<dynamic>('/api/session/$sessionId');
  }

  Future<void> updateTitle(String sessionId, String title) async {
    await dio.patch<dynamic>(
      '/api/session/$sessionId',
      data: {'title': title},
    );
  }

  Future<Map<String, SessionStatusValue>> activeSessions() async {
    final r = await dio.get<dynamic>('/api/session/active');
    final d = _asMap(r.data)['data'];
    if (d is! Map) return const {};
    return d.map((k, v) => MapEntry(k.toString(),
        const SessionStatusValue('busy')));
  }

  Future<List<WorktreeInfo>> worktrees(String projectID) async {
    final r = await dio.get<dynamic>('/api/worktree',
        queryParameters: {'projectID': projectID});
    if (r.data is List) {
      return (r.data as List)
          .whereType<Map>()
          .map((e) => WorktreeInfo.fromJson(e.cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  Future<WorktreeInfo> createWorktree(
    String projectID, {
    String? name,
    String? branch,
    String? from,
    String? directory,
  }) async {
    final body = <String, dynamic>{'projectID': projectID};
    if (name != null && name.isNotEmpty) body['name'] = name;
    if (branch != null && branch.isNotEmpty) body['branch'] = branch;
    if (from != null && from.isNotEmpty) body['from'] = from;
    if (directory != null && directory.isNotEmpty) body['directory'] = directory;
    final r = await dio.post<dynamic>('/api/worktree', data: body);
    return WorktreeInfo.fromJson(_asMap(r.data));
  }

  Future<void> removeWorktree(
    String projectID,
    String worktreeDir, {
    bool force = false,
  }) async {
    await dio.delete<dynamic>('/api/worktree', data: {
      'projectID': projectID,
      'directory': worktreeDir,
      'force': force,
    });
  }

  Future<List<CommandInfo>> getMergedCommands({String? directory}) async {
    final results = await Future.wait([
      _try(() async {
        final r = await dio.get<dynamic>('/api/command',
            queryParameters: _locationQuery(directory));
        return _dataList(r.data);
      }),
      _try(() async {
        final r = await dio.get<dynamic>('/api/skill',
            queryParameters: _locationQuery(directory));
        return _dataList(r.data);
      }),
    ]);
    final out = <CommandInfo>[];
    for (final e in results[0]) {
      if (e is! Map) continue;
      out.add(CommandInfo.fromJson(e.cast<String, dynamic>()));
    }
    for (final e in results[1]) {
      if (e is! Map) continue;
      final s = SkillInfo.fromJson(e.cast<String, dynamic>());
      out.add(CommandInfo(
        name: s.id,
        description: s.description ?? s.name,
        skill: true,
      ));
    }
    return out;
  }

  Future<List<AgentInfo>> listAgents({String? directory}) async {
    final r = await dio.get<dynamic>('/api/agent',
        queryParameters: _locationQuery(directory));
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => AgentInfo.fromJson(e.cast<String, dynamic>()))
        .where((a) => !a.hidden && a.mode == 'primary')
        .toList();
  }

  Future<List<ModelInfo>> listModels({String? directory}) async {
    final r = await dio.get<dynamic>('/api/model',
        queryParameters: _locationQuery(directory));
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => ModelInfo.fromJson(e.cast<String, dynamic>()))
        .where((m) =>
            m.enabled && m.status != 'deprecated' && m.status != 'disabled')
        .toList();
  }

  Future<void> switchAgent(String sessionId, String agent) async {
    await dio.post('/api/session/$sessionId/agent', data: {'agent': agent});
  }

  Future<void> switchModel(String sessionId, ModelRef model) async {
    final m = <String, dynamic>{
      'id': model.id,
      'providerID': model.providerID,
    };
    if (model.variant != null) {
      m['variant'] = model.variant;
    }
    await dio.post('/api/session/$sessionId/model', data: {'model': m});
  }

  Future<List<SessionMessage>> messages(String sessionId, {int? limit}) async {
    final r = await dio.get<dynamic>(
      '/api/session/$sessionId/message',
      queryParameters: {
        'order': 'asc',
        'limit': ?limit,
      },
    );
    return _messageListFrom(r.data);
  }

  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    } else {
      params['order'] = 'desc';
    }
    final r = await dio.get<dynamic>(
      '/api/session/$sessionId/message',
      queryParameters: params,
    );
    final d = _asMap(r.data);
    final cur = (d['cursor'] as Map?) ?? const {};
    final entries = _messageListFrom(d['data']).reversed.toList();
    return MessagesPage(
      entries,
      cur['next']?.toString(),
      cur['previous']?.toString(),
    );
  }

  Future<MessagesPage> messagesPageCompute(String sessionId,
      {required int limit, String? cursor}) async {
    if (runtimeType != OpencodeClient) {
      return messagesPage(sessionId, limit: limit, cursor: cursor);
    }
    final params = <String, dynamic>{'limit': limit};
    if (cursor != null && cursor.isNotEmpty) {
      params['cursor'] = cursor;
    } else {
      params['order'] = 'desc';
    }
    final r = await dio.get<String>(
      '/api/session/$sessionId/message',
      queryParameters: params,
      options: Options(responseType: ResponseType.plain),
    );
    final body = r.data ?? '';
    if (body.isEmpty) {
      return MessagesPage(const [], null, null);
    }
    final parsed = await compute(decodeMessagePage, body);
    return MessagesPage(
      parsed.entries.reversed.toList(),
      parsed.olderCursor,
      parsed.newerCursor,
    );
  }

  Future<SessionMessage> message(String sessionId, String messageId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId/message/$messageId');
    return SessionMessage.fromJson(_asMap(r.data));
  }

  Future<List<Permission>> pendingPermissions(String directory) async {
    final r = await dio.get<dynamic>('/api/permission/request',
        queryParameters: _locationQuery(directory));
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => Permission.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<List<Permission>> sessionPermissions(String sessionId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId/permission');
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => Permission.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<void> respondPermission(
    String sessionId,
    String permissionId,
    String response,
  ) async {
    await dio.post(
      '/api/session/$sessionId/permission/$permissionId/reply',
      data: {'decision': response},
    );
  }

  Future<List<FormInfo>> listForms({String? directory}) async {
    final r = await dio.get<dynamic>('/api/form',
        queryParameters: _locationQuery(directory));
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => FormInfo.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<List<FormInfo>> sessionForms(String sessionId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId/form');
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) => FormInfo.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  Future<void> replyForm(
    String sessionId,
    String formId,
    Map<String, dynamic> answer,
  ) async {
    await dio.post(
      '/api/session/$sessionId/form/$formId/reply',
      data: {'answer': answer},
    );
  }

  Future<void> cancelForm(String sessionId, String formId) async {
    await dio.delete<dynamic>('/api/session/$sessionId/form/$formId');
  }

  Future<Map<String, dynamic>> prompt(
    String sessionId, {
    required String text,
    List<Map<String, dynamic>> files = const [],
    String? agent,
    Duration? sendTimeout,
  }) async {
    final body = <String, dynamic>{'text': text};
    if (files.isNotEmpty) body['files'] = files;
    if (agent != null && agent.isNotEmpty) {
      body['agents'] = [
        {'name': agent}
      ];
    }
    final r = await dio.post(
      '/api/session/$sessionId/prompt',
      data: body,
      options: sendTimeout == null ? null : Options(sendTimeout: sendTimeout),
    );
    return _asMap(r.data);
  }

  Future<void> shell(
    String sessionId, {
    required String command,
  }) async {
    await dio.post(
      '/api/session/$sessionId/shell',
      data: {'command': command},
    );
  }

  Future<void> command(
    String sessionId, {
    required String command,
    String arguments = '',
    List<Map<String, dynamic>> files = const [],
    Duration? sendTimeout,
  }) async {
    final body = <String, dynamic>{
      'name': command,
      'text': arguments,
    };
    if (files.isNotEmpty) body['files'] = files;
    await dio.post(
      '/api/session/$sessionId/command',
      data: body,
      options: sendTimeout == null ? null : Options(sendTimeout: sendTimeout),
    );
  }

  Future<void> activateSkill(String sessionId, String skillId) async {
    await dio.post(
      '/api/experimental/session/$sessionId/skill',
      data: {'id': skillId},
    );
  }

  Future<void> interrupt(String sessionId) async {
    await dio.post('/api/session/$sessionId/interrupt');
  }

  Future<void> compact(String sessionId) async {
    await dio.post('/api/session/$sessionId/compact');
  }

  Future<void> revert(String sessionId, {required String messageID}) async {
    await dio.post(
      '/api/session/$sessionId/revert/stage',
      data: {'messageID': messageID},
    );
    await dio.post('/api/session/$sessionId/revert/commit');
  }

  Future<List<FileDiff>> diff(
    String sessionId, {
    String? directory,
    String? mode,
    String? messageID,
    int? context,
  }) async {
    final dir = directory != null && directory.isNotEmpty ? directory : null;
    if (messageID != null && messageID.isNotEmpty) {
      final params = <String, dynamic>{'from': messageID, 'context': context ?? kVcsDiffContext};
      final r = await dio.get<dynamic>(
        '/api/session/$sessionId/diff',
        queryParameters: params,
      );
      return _diffListFrom(r.data);
    }
    final params = <String, dynamic>{
      'mode': mode ?? 'working',
      'context': context ?? kVcsDiffContext,
    };
    if (dir != null) params.addAll(_locationQuery(dir));
    final r = await dio.get<dynamic>('/api/vcs/diff', queryParameters: params);
    return _diffListFrom(r.data);
  }

  Future<List<FileNode>> listFiles({
    required String directory,
    required String path,
  }) async {
    final params = _locationQuery(directory);
    if (path.isNotEmpty && path != '.') params['path'] = path;
    final r = await dio.get<dynamic>('/api/fs/list', queryParameters: params);
    final base = _asMap(r.data)['location'];
    final baseDir = base is Map ? base['directory']?.toString() ?? directory : directory;
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) {
          final entry = e.cast<String, dynamic>();
          return FileNode.fromFsEntry(
            (entry['path'] ?? '').toString(),
            (entry['type'] ?? 'file').toString(),
            baseDirectory: baseDir,
          );
        })
        .toList();
  }

  Future<StreamedFile> readFileStream({
    required String directory,
    required String path,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final raw = raw_download.rawDownloadDio(dio);
    try {
      final encoded = path
          .split('/')
          .map((s) => Uri.encodeComponent(s))
          .join('/');
      final r = await raw.get<dynamic>(
        '/api/fs/read/$encoded',
        queryParameters: _locationQuery(directory),
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
        cancelToken: cancelToken,
      );
      final body = raw_download.decodeDownloadBody(
        r.data as Uint8List,
        r.headers.value('content-encoding'),
      );
      final mime = r.headers.value('content-type')?.split(';').first.trim();
      if (body.length < _inlineParseLimit) {
        return parseStreamedFile((body, mime));
      }
      return compute(parseStreamedFile, (body, mime));
    } finally {
      raw.close(force: true);
    }
  }

  Future<List<FileNode>> findFiles({
    required String directory,
    required String path,
    required String query,
  }) async {
    final base = directory.endsWith('/')
        ? directory.substring(0, directory.length - 1)
        : directory;
    final searchRoot = path.isEmpty
        ? base
        : base.isEmpty
            ? path
            : '$base/$path';
    final r = await dio.get<dynamic>('/api/fs/find', queryParameters: {
      ..._locationQuery(searchRoot),
      'query': query,
    });
    String toRel(String s) => path.isEmpty ? s : '$path/$s';
    return _dataList(r.data)
        .whereType<Map>()
        .map((e) {
          final entry = e.cast<String, dynamic>();
          final p = (entry['path'] ?? '').toString();
          return FileNode.fromFsEntry(
            toRel(p),
            (entry['type'] ?? 'file').toString(),
          );
        })
        .toList();
  }

  List<FileDiff> _diffListFrom(dynamic data) {
    final list = data is Map ? data['data'] : data;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => FileDiff.fromJson(e.cast<String, dynamic>()))
        .toList();
  }

  List<SessionMessage> _messageListFrom(dynamic data) {
    final list = data is Map ? data['data'] : data;
    if (list is! List) return const [];
    return list
        .whereType<Map>()
        .map((e) => SessionMessage.fromJson(e.cast<String, dynamic>()))
        .toList(growable: false);
  }

  List<dynamic> _dataList(dynamic data) {
    final list = data is Map ? data['data'] : data;
    return list is List ? list : const [];
  }

  Future<List<dynamic>> _try(Future<List<dynamic>> Function() f) async {
    try {
      return await f();
    } catch (_) {
      return const [];
    }
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

const int _inlineParseLimit = 500 * 1024;

@visibleForTesting
class DecodedMessagePage {
  final List<SessionMessage> entries;
  final String? olderCursor;
  final String? newerCursor;
  const DecodedMessagePage(this.entries, this.olderCursor, this.newerCursor);
}

@visibleForTesting
DecodedMessagePage decodeMessagePage(String body) {
  final d = jsonDecode(body);
  if (d is! Map) return const DecodedMessagePage([], null, null);
  final list = d['data'];
  final cur = (d['cursor'] as Map?) ?? const {};
  final entries = list is List
      ? list
          .whereType<Map>()
          .map((e) => SessionMessage.fromJson(e.cast<String, dynamic>()))
          .toList(growable: false)
      : const <SessionMessage>[];
  return DecodedMessagePage(
    entries,
    cur['next']?.toString(),
    cur['previous']?.toString(),
  );
}

const int kVcsDiffContext = 3;

@visibleForTesting
StreamedFile parseStreamedFile((Uint8List, String?) args) {
  final body = args.$1;
  final mime = args.$2;
  final type = _isTextMime(mime) ? 'text' : 'binary';
  if (type == 'text') {
    return StreamedFile(
      type: type,
      mimeType: mime,
      text: utf8.decode(body, allowMalformed: true),
    );
  }
  return StreamedFile(
    type: type,
    mimeType: mime,
    bytes: body,
  );
}

bool _isTextMime(String? mime) {
  if (mime == null || mime.isEmpty) return true;
  final m = mime.toLowerCase();
  if (m.startsWith('text/')) return true;
  if (m == 'application/json') return true;
  if (m == 'application/jsonl') return true;
  if (m == 'application/json5') return true;
  if (m == 'application/xml') return true;
  if (m == 'application/yaml' || m == 'application/x-yaml' || m == 'text/yaml') {
    return true;
  }
  if (m == 'application/javascript' || m == 'text/javascript') return true;
  if (m == 'application/x-empty') return true;
  return false;
}
