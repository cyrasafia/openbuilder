import 'dart:convert';

import 'package:dio/dio.dart';

import '../../domain/models.dart';

/// Paginated message window from `GET /session/:id/message?limit=&before=`.
///
/// [entries] are ascending (oldest→newest). [nextCursor] is the opaque
/// `X-Next-Cursor` header anchoring [entries]'s oldest message; pass it as
/// `before` to fetch the next older page. Null means no more older history.
class MessagesPage {
  final List<MessageEntry> entries;
  final String? nextCursor;
  const MessagesPage(this.entries, this.nextCursor);
}

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

  /// `PATCH /project/{projectID}` — update project name / icon / commands.
  ///
  /// [name] is sent only when non-null. When [updateIcon] is true the full
  /// icon object is serialized with all three keys present — explicit JSON
  /// `null` for [iconOverride]/[iconColor] clears them, which is correct under
  /// both merge-patch (RFC 7396: null = delete) and replace semantics.
  /// [iconUrl] is the server-managed repo URL, passed through unchanged.
  Future<ProjectModel> updateProject(
    String projectId, {
    String? name,
    bool updateIcon = false,
    String? iconUrl,
    String? iconOverride,
    String? iconColor,
  }) async {
    final body = <String, dynamic>{};
    if (name != null) body['name'] = name;
    if (updateIcon) {
      body['icon'] = <String, dynamic>{
        'url': iconUrl,
        'override': iconOverride,
        'color': iconColor,
      };
    }
    final r = await dio.patch<dynamic>('/project/$projectId', data: body);
    return ProjectModel.fromJson(_asMap(r.data));
  }

  /// `GET /session` (global, unarchived by default)
  Future<List<SessionModel>> sessions() async =>
      _getModels('/session', SessionModel.fromJson);

  /// `GET /session?directory=<path>` — sessions scoped to one project directory.
  /// Returns unarchived sessions by default (opencode's authoritative archive
  /// filtering), unlike `/api/session` which under-reports `time.archived`.
  Future<List<SessionModel>> sessionsForDirectory(String directory,
      {int limit = 1000}) async {
    final r = await dio.get<dynamic>('/session', queryParameters: {
      'directory': directory,
      'limit': limit,
    });
    return _getModelsFromData(r.data, SessionModel.fromJson);
  }

  /// Metadata for a single session.
  /// `GET /api/session/{id}`
  Future<SessionModel> sessionMeta(String sessionId) async {
    final r = await dio.get<dynamic>('/api/session/$sessionId');
    return SessionModel.fromJson(_asMap(r.data));
  }

  /// `POST /session?directory=<dir>` — create a session in one directory.
  Future<SessionModel> createSession(String directory) async {
    final r = await dio.post<dynamic>('/session',
        queryParameters: {'directory': directory}, data: const {});
    return SessionModel.fromJson(_asMap(r.data));
  }

  /// `GET /experimental/worktree?directory=<dir>` — all worktree directories
  /// for a project (sandbox worktrees beyond the project's main worktree).
  Future<List<String>> worktrees(String directory) async {
    final r = await dio.get<dynamic>('/experimental/worktree',
        queryParameters: {'directory': directory});
    if (r.data is List) {
      return (r.data as List).map((e) => e.toString()).toList();
    }
    return const [];
  }

  /// `POST /experimental/worktree?directory=<dir>` — create a worktree.
  /// Body: `{name?, startCommand?}` → returns `{name, branch?, directory}`.
  /// If [name] is omitted, the server generates a random adjective-noun slug.
  Future<WorktreeResult> createWorktree(String directory,
      {String? name, String? startCommand}) async {
    final body = <String, dynamic>{};
    if (name != null && name.isNotEmpty) body['name'] = name;
    if (startCommand != null && startCommand.isNotEmpty) {
      body['startCommand'] = startCommand;
    }
    final r = await dio.post<dynamic>('/experimental/worktree',
        queryParameters: {'directory': directory}, data: body);
    final d = r.data as Map<String, dynamic>;
    return WorktreeResult.fromJson(d.cast());
  }

  /// `DELETE /experimental/worktree?directory=<dir>` — remove a worktree.
  Future<void> removeWorktree(String directory,
      {required String worktreeDir}) async {
    await dio.delete<dynamic>('/experimental/worktree',
        queryParameters: {'directory': directory},
        data: {'directory': worktreeDir});
  }

  /// Available slash commands for a session's directory.
  /// `GET /api/command?directory=<dir>` → `{ location, data: [CommandV2Info] }`.
  /// Returns the project-scoped command list (empty if the server resolves
  /// none for the directory). The v2 endpoint requires a directory to resolve
  /// commands; without it `data` comes back empty.
  Future<List<CommandInfo>> getCommands({String? directory}) async {
    final params = <String, dynamic>{};
    if (directory != null && directory.isNotEmpty) {
      params['directory'] = directory;
    }
    final r = await dio.get<dynamic>('/api/command', queryParameters: params);
    final data = _asMap(r.data)['data'];
    return _getModelsFromData(data, CommandInfo.fromJson);
  }

  /// `GET /session/status?directory=<dir>` → `{ sessionID: {type: idle|busy|retry} }`.
  /// Without a directory the endpoint returns `{}`.
  Future<Map<String, SessionStatusValue>> sessionStatus({String? directory}) async {
    final r = await dio.get<dynamic>('/session/status',
        queryParameters:
            directory != null && directory.isNotEmpty ? {'directory': directory} : null);
    final m = _asMap(r.data);
    return m.map((k, v) => MapEntry(
        k, SessionStatusValue.fromJson(v is Map ? v.cast() : const {})));
  }

  /// `GET /session/:id/message?limit=` — full message list (no pagination).
  Future<List<MessageEntry>> messages(String sessionId, {int? limit}) async {
    final r = await dio.get<dynamic>(
      '/session/$sessionId/message',
      queryParameters: limit == null ? null : {'limit': limit},
    );
    return _getModelsFromData(r.data, MessageEntry.fromJson);
  }

  /// `GET /session/:id/message?limit=&before=` — paginated window.
  ///
  /// Without [before]: returns the latest [limit] messages (ascending). If
  /// older history exists, [MessagesPage.nextCursor] is non-null (opaque
  /// cursor anchoring the oldest message of the returned page).
  ///
  /// With [before]: returns the next older page (strictly older than the
  /// cursor anchor). Requires [limit] (server returns 400 otherwise).
  ///
  /// Older servers ignoring `limit` return the full list with `nextCursor`
  /// null — degrades gracefully to a full fetch.
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? before}) async {
    final params = <String, dynamic>{'limit': limit};
    if (before != null) params['before'] = before;
    final r = await dio.get<dynamic>(
      '/session/$sessionId/message',
      queryParameters: params,
    );
    final cursor = r.headers.value('x-next-cursor');
    return MessagesPage(
        _getModelsFromData(r.data, MessageEntry.fromJson), cursor);
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

  /// `GET /permission?directory=<dir>` — pending permission requests.
  Future<List<Permission>> pendingPermissions(String directory) async {
    final r = await dio.get<dynamic>('/permission',
        queryParameters: {'directory': directory});
    if (r.data is List) {
      return (r.data as List)
          .map((e) => Permission.fromJson(
              (e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  /// `POST /session/:id/permissions/:permissionID` — respond to a permission.
  /// [response] is one of: `'once'`, `'always'`, `'reject'`.
  Future<void> respondPermission(
    String sessionId,
    String permissionId,
    String response,
  ) async {
    await dio.post(
      '/session/$sessionId/permissions/$permissionId',
      data: {'response': response},
    );
  }

  /// `POST /session/:id/prompt_async` — send a message and return immediately.
  /// [parts] is the message payload, e.g. `[{'type':'text','text':'...'}]`.
  Future<void> prompt(
    String sessionId, {
    String? directory,
    String? agent,
    required List<Map<String, dynamic>> parts,
    Duration? sendTimeout,
  }) async {
    final body = <String, dynamic>{'parts': parts};
    if (agent != null) body['agent'] = agent;
    await dio.post(
      '/session/$sessionId/prompt_async',
      queryParameters:
          directory != null ? {'directory': directory} : null,
      data: body,
      options: sendTimeout == null
          ? null
          : Options(sendTimeout: sendTimeout),
    );
  }

  /// `POST /session/:id/shell` — run a shell command and return immediately.
  /// Mirrors `prompt_async`: the command is executed by an agent and its
  /// output streams back through SSE. [command] is the raw command without
  /// the leading `!`; [agent] defaults to the primary `build` agent.
  Future<void> shell(
    String sessionId, {
    String? directory,
    String? agent,
    required String command,
  }) async {
    await dio.post(
      '/session/$sessionId/shell',
      queryParameters:
          directory != null ? {'directory': directory} : null,
      data: {'agent': agent ?? 'build', 'command': command},
    );
  }

  /// `POST /session/:id/abort` — stop a running session.
  Future<void> abort(String sessionId, {String? directory}) async {
    await dio.post(
      '/session/$sessionId/abort',
      queryParameters: directory != null ? {'directory': directory} : null,
    );
  }

  /// `DELETE /session/:id` — permanently delete a session (hard delete).
  Future<void> deleteSession(String sessionId, {String? directory}) async {
    await dio.delete(
      '/session/$sessionId',
      queryParameters: directory != null ? {'directory': directory} : null,
    );
  }

  /// `PATCH /session/:id` — archive (set `time.archived`) or un-archive.
  Future<void> archive(String sessionId, {String? directory, int? archived}) async {
    await dio.patch(
      '/session/$sessionId',
      queryParameters: directory != null ? {'directory': directory} : null,
      data: {
        'time': {'archived': archived},
      },
    );
  }

  /// `PATCH /session/:id` — update session title.
  Future<void> updateTitle(String sessionId, String title,
      {String? directory}) async {
    await dio.patch(
      '/session/$sessionId',
      queryParameters: directory != null ? {'directory': directory} : null,
      data: {'title': title},
    );
  }

  /// `POST /session/:id/share` — generate a share link. Returns the updated session.
  Future<SessionModel> share(String sessionId, {String? directory}) async {
    final r = await dio.post(
      '/session/$sessionId/share',
      queryParameters: directory != null ? {'directory': directory} : null,
    );
    return SessionModel.fromJson(_asMap(r.data));
  }

  // ── Agent / Model switching (v2 API) ──

  /// `GET /agent?directory=<dir>` — list available agents.
  Future<List<AgentInfo>> listAgents({String? directory}) async {
    final r = await dio.get<dynamic>('/agent',
        queryParameters: directory != null && directory.isNotEmpty
            ? {'directory': directory}
            : null);
    if (r.data is List) {
      return (r.data as List)
          .map((e) => AgentInfo.fromJson((e as Map).cast<String, dynamic>()))
          .where((a) => !a.hidden && a.mode == 'primary')
          .toList();
    }
    return const [];
  }

  /// `GET /config/providers?directory=<dir>` — all connected (authenticated)
  /// providers and their models. Returns models flattened across providers.
  ///
  /// Unlike `GET /api/model` (which only surfaces the active `opencode` Zen
  /// catalog), this endpoint lists every configured provider (zai, deepseek,
  /// ollama-cloud, ...) and is the canonical source for switchable models.
  ///
  /// The provider objects contain a plaintext API `key`; it is intentionally
  /// not read here — only each model entry is parsed.
  Future<List<ModelInfo>> listConfigProviders({String? directory}) async {
    final params = <String, dynamic>{};
    if (directory != null && directory.isNotEmpty) {
      params['directory'] = directory;
    }
    final r = await dio.get<dynamic>(
      '/config/providers',
      queryParameters: params,
    );
    final d = r.data is Map ? (r.data as Map) : {};
    final providers = d['providers'];
    final out = <ModelInfo>[];
    if (providers is List) {
      for (final p in providers) {
        if (p is! Map) continue;
        final models = p['models'];
        if (models is Map) {
          for (final v in models.values) {
            if (v is Map) {
              out.add(ModelInfo.fromJson(v.cast<String, dynamic>()));
            }
          }
        }
      }
    }
    // Defensive: keep the enabled+active gate that the old /api/model path
    // applied. /config/providers exposes only connected providers, but a
    // provider may still advertise deprecated models; the OpenAPI contract
    // does not guarantee every entry is active. ModelInfo tolerates missing
    // enabled/status (defaults true / 'active').
    return out.where((m) => m.enabled && m.status == 'active').toList();
  }

  /// `POST /api/session/:id/agent` — switch the session's agent.
  Future<void> switchAgent(String sessionId, String agent) async {
    await dio.post('/api/session/$sessionId/agent', data: {'agent': agent});
  }

  /// `POST /api/session/:id/model` — switch the session's model.
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

  // ── Questions ──

  /// `GET /question?directory=<dir>` — list pending questions.
  Future<List<QuestionRequest>> listQuestions({String? directory}) async {
    final r = await dio.get<dynamic>('/question',
        queryParameters:
            directory != null && directory.isNotEmpty ? {'directory': directory} : null);
    if (r.data is List) {
      return (r.data as List)
          .map((e) => QuestionRequest.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    }
    return const [];
  }

  /// `POST /question/:id/reply?directory=<dir>` — reply to a question.
  ///
  /// opencode 的 question pending 是 per-directory instance 隔离的：HTTP 路由
  /// 由 `WorkspaceRoutingMiddleware` 按 `directory` query/header 解析到对应
  /// instance，不带 directory 会落到默认实例(cwd) → 404。这里必须带 directory
  /// 才能命中卡所在 instance（与 `listQuestions` 的 directory 用法一致）。
  /// [answers] is a list of answer arrays (one per question), each containing
  /// selected option labels.
  Future<void> replyQuestion(String questionId, String directory, List<List<String>> answers) async {
    await dio.post(
      '/question/$questionId/reply',
      queryParameters: {'directory': directory},
      data: {'answers': answers},
    );
  }

  /// `POST /question/:id/reject?directory=<dir>` — reject a question.
  Future<void> rejectQuestion(String questionId, String directory) async {
    await dio.post(
      '/question/$questionId/reject',
      queryParameters: {'directory': directory},
    );
  }

  /// `POST /session/:id/revert` — revert the session back to [messageID].
  Future<void> revert(
    String sessionId, {
    String? directory,
    required String messageID,
  }) async {
    await dio.post(
      '/session/$sessionId/revert',
      queryParameters: directory != null ? {'directory': directory} : null,
      data: {'messageID': messageID},
    );
  }

  /// `GET /session/:id/diff` → list of changed files.
  Future<List<FileDiff>> diff(String sessionId, {String? directory}) async {
    final r = await dio.get<dynamic>(
      '/session/$sessionId/diff',
      queryParameters: directory != null ? {'directory': directory} : null,
    );
    return _getModelsFromData(r.data, FileDiff.fromJson);
  }

  /// `GET /file` — list files/dirs under [path] within [directory].
  Future<List<FileNode>> listFiles({
    required String directory,
    required String path,
  }) async {
    final r = await dio.get<dynamic>('/file', queryParameters: {
      'directory': directory,
      'path': path,
    });
    return _getModelsFromData(r.data, FileNode.fromJson);
  }

  /// `GET /file/content` — read a file's full content.
  Future<FileContent> readFile({
    required String directory,
    required String path,
  }) async {
    final r = await dio.get<dynamic>('/file/content', queryParameters: {
      'directory': directory,
      'path': path,
    });
    return FileContent.fromJson(_asMap(r.data));
  }

  /// `GET /find/file?query=` — search files within [directory].
  Future<List<FileNode>> findFiles({
    required String directory,
    required String query,
  }) async {
    final r = await dio.get<dynamic>('/find/file', queryParameters: {
      'directory': directory,
      'query': query,
    });
    return _getModelsFromData(r.data, FileNode.fromJson);
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
