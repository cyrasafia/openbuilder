import 'package:flutter/foundation.dart';

class ProjectModel {
  final String id;
  final String worktree;
  final String? vcs;
  final String? name;
  final ProjectIcon? icon;
  final List<String> sandboxes;
  final int created;

  const ProjectModel({
    required this.id,
    required this.worktree,
    this.vcs,
    this.name,
    this.icon,
    this.sandboxes = const [],
    this.created = 0,
  });

  factory ProjectModel.fromJson(Map<String, dynamic> j) => ProjectModel(
        id: (j['id'] ?? '').toString(),
        worktree: (j['worktree'] ?? '').toString(),
        vcs: j['vcs']?.toString(),
        name: j['name']?.toString(),
        icon: j['icon'] is Map ? ProjectIcon.fromJson(j['icon']) : null,
        sandboxes: (j['sandboxes'] as List? ?? [])
            .map((e) => e.toString())
            .toList(growable: false),
        created: _i(j['time'] is Map ? (j['time'] as Map)['created'] : 0),
      );

  String get worktreeName =>
      worktree.isEmpty || worktree == '/' ? 'global' : worktree.split('/').last;

  String get displayName {
    final n = name;
    if (n != null && n.trim().isNotEmpty) return n;
    return worktreeName;
  }
}

class ProjectIcon {
  final String? url;
  final String? override;
  final String? color;
  const ProjectIcon({this.url, this.override, this.color});

  factory ProjectIcon.fromJson(Map<String, dynamic> j) => ProjectIcon(
        url: j['url']?.toString(),
        override: j['override']?.toString(),
        color: j['color']?.toString(),
      );

  /// Best image source (data URL or http URL); null → fallback to monogram.
  String? get image => override ?? url;
}

/// A slash command available in a session's directory, from `GET /api/command`.
class CommandInfo {
  final String name;
  final String description;
  final String? agent;
  const CommandInfo({
    required this.name,
    this.description = '',
    this.agent,
  });

  factory CommandInfo.fromJson(Map<String, dynamic> j) => CommandInfo(
        name: (j['name'] ?? '').toString(),
        description: (j['description'] ?? '').toString(),
        agent: j['agent']?.toString(),
      );

  String get slash => name.startsWith('/') ? name : '/$name';
}

class Tokens {
  final int input;
  final int output;
  final int reasoning;
  const Tokens({this.input = 0, this.output = 0, this.reasoning = 0});

  int get total => input + output;

  factory Tokens.fromJson(Map<String, dynamic> j) => Tokens(
        input: _i(j['input']),
        output: _i(j['output']),
        reasoning: _i(j['reasoning']),
      );
}

class SessionModel {
  final String id;
  final String projectID;
  final String directory;
  final String title;
  final int created;
  final int updated;
  final int? archived;
  final String? parentID;
  final double cost;
  final Tokens tokens;
  final String? agent;

  const SessionModel({
    required this.id,
    required this.projectID,
    required this.directory,
    required this.title,
    required this.created,
    required this.updated,
    this.archived,
    this.parentID,
    this.cost = 0,
    this.tokens = const Tokens(),
    this.agent,
  });

  factory SessionModel.fromJson(Map<String, dynamic> j) {
    final time = (j['time'] as Map?) ?? const {};
    return SessionModel(
      id: (j['id'] ?? '').toString(),
      projectID: (j['projectID'] ?? '').toString(),
      directory: (j['directory'] ?? '').toString(),
      title: (j['title'] ?? 'Untitled').toString(),
      created: _i(time['created']),
      updated: _i(time['updated']),
      archived: time['archived'] == null ? null : _i(time['archived']),
      parentID: j['parentID']?.toString(),
      cost: _d(j['cost']),
      tokens: j['tokens'] is Map
          ? Tokens.fromJson(j['tokens'] as Map<String, dynamic>)
          : const Tokens(),
      agent: j['agent']?.toString(),
    );
  }

  String get dirName =>
      directory.isEmpty ? 'global' : directory.split('/').last;
}

/// `idle` | `busy` | `retry`
class SessionStatusValue {
  final String type;
  const SessionStatusValue(this.type);

  factory SessionStatusValue.fromJson(Map<String, dynamic> j) =>
      SessionStatusValue((j['type'] ?? 'idle').toString());
}

class MessageInfo {
  final String id;
  final String role; // user | assistant
  final String? sessionID;
  final int? created;
  final int? completed;
  final double cost;
  final String? modelID;
  final String? finish;
  final Map<String, dynamic>? error;

  const MessageInfo({
    required this.id,
    required this.role,
    this.sessionID,
    this.created,
    this.completed,
    this.cost = 0,
    this.modelID,
    this.finish,
    this.error,
  });

  factory MessageInfo.fromJson(Map<String, dynamic> j) => MessageInfo(
        id: (j['id'] ?? '').toString(),
        role: (j['role'] ?? 'assistant').toString(),
        sessionID: j['sessionID']?.toString(),
        created: j['time'] is Map ? _i((j['time'] as Map)['created']) : null,
        completed:
            j['time'] is Map ? _i((j['time'] as Map)['completed']) : null,
        cost: _d(j['cost']),
        modelID: j['modelID']?.toString(),
        finish: j['finish']?.toString(),
        error: j['error'] is Map ? (j['error'] as Map).cast<String, dynamic>() : null,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'role': role,
        'sessionID': sessionID,
        'time': {
          if (created != null) 'created': created,
          if (completed != null) 'completed': completed,
        },
        'cost': cost,
        'modelID': modelID,
        'finish': finish,
        'error': error,
      };
}

/// Loose part wrapper over raw JSON. Types: text, reasoning, tool,
/// step-start, step-finish, file, subtask, snapshot, patch, agent, ...
@immutable
class MessagePart {
  final Map<String, dynamic> raw;
  const MessagePart(this.raw);

  String get type => (raw['type'] ?? '').toString();
  String get id => (raw['id'] ?? '').toString();
  String? get text => _str('text');
  String? get tool => _str('tool');
  Map<String, dynamic>? get state =>
      raw['state'] is Map ? (raw['state'] as Map).cast<String, dynamic>() : null;
  String? get stateStatus => state?['status']?.toString();
  String? get stateTitle => state?['title']?.toString();
  String? get stateOutput => state?['output']?.toString();

  String? _str(String k) {
    final v = raw[k];
    return v is String ? v : null;
  }

  /// One-line preview for the session list (frontend §2.2 D1).
  String get preview {
    switch (type) {
      case 'text':
      case 'reasoning':
        return (text ?? '').replaceAll('\n', ' ');
      case 'tool':
        final st = stateStatus ?? '';
        return '${tool ?? 'tool'}${st.isEmpty ? '' : ' · $st'}';
      default:
        return '';
    }
  }
}

class MessageEntry {
  final MessageInfo info;
  final List<MessagePart> parts;
  const MessageEntry({required this.info, required this.parts});

  factory MessageEntry.fromJson(Map<String, dynamic> j) => MessageEntry(
        info: MessageInfo.fromJson(
            (j['info'] as Map?)?.cast<String, dynamic>() ?? const {}),
        parts: ((j['parts'] as List?) ?? [])
            .map((e) => MessagePart((e as Map).cast<String, dynamic>()))
            .toList(growable: false),
      );
}

class Todo {
  final String? id;
  final String content;
  final String status; // pending | in_progress | completed | cancelled
  final String priority;
  const Todo({this.id, required this.content, required this.status, this.priority = 'medium'});

  factory Todo.fromJson(Map<String, dynamic> j) => Todo(
        id: j['id']?.toString(),
        content: (j['content'] ?? '').toString(),
        status: (j['status'] ?? 'pending').toString(),
        priority: (j['priority'] ?? 'medium').toString(),
      );

  bool get done => status == 'completed' || status == 'cancelled';
  bool get active => status == 'in_progress';
  bool get cancelled => status == 'cancelled';

  Map<String, dynamic> toJson() =>
      {'id': id, 'content': content, 'status': status, 'priority': priority};
}

/// Result of `POST /experimental/worktree` — a newly created worktree.
class WorktreeResult {
  final String name;
  final String? branch;
  final String directory;
  const WorktreeResult(
      {required this.name, this.branch, required this.directory});

  factory WorktreeResult.fromJson(Map<String, dynamic> j) => WorktreeResult(
        name: (j['name'] ?? '').toString(),
        branch: j['branch']?.toString(),
        directory: (j['directory'] ?? '').toString(),
      );
}

class Permission {
  final String id;
  final String type;
  final String title;
  final String sessionID;
  final List<String> patterns;
  final Map<String, dynamic>? metadata;
  const Permission({
    required this.id,
    required this.type,
    required this.title,
    required this.sessionID,
    this.patterns = const [],
    this.metadata,
  });

  factory Permission.fromJson(Map<String, dynamic> j) {
    final perm = (j['permission'] ?? j['type'] ?? '').toString();
    final meta = j['metadata'] is Map
        ? (j['metadata'] as Map).cast<String, dynamic>()
        : null;
    return Permission(
      id: (j['id'] ?? '').toString(),
      type: perm,
      title: _permissionTitle(perm, meta),
      sessionID: (j['sessionID'] ?? '').toString(),
      patterns: j['patterns'] is List
          ? (j['patterns'] as List).map((e) => e.toString()).toList()
          : const [],
      metadata: meta,
    );
  }
}

/// Derive a human-readable title from permission type + metadata.
String _permissionTitle(String type, Map<String, dynamic>? meta) {
  switch (type) {
    case 'external_directory':
      final filepath = meta?['filepath']?.toString();
      return filepath != null ? '访问目录 $filepath' : '外部目录访问';
    case 'bash':
      return '执行命令';
    default:
      return type.isEmpty ? '权限请求' : type;
  }
}

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

class FileNode {
  final String name;
  final String path;
  final String absolute;
  final String type; // file | directory
  final bool ignored;
  const FileNode({
    required this.name,
    required this.path,
    required this.absolute,
    required this.type,
    required this.ignored,
  });

  factory FileNode.fromJson(Map<String, dynamic> j) => FileNode(
        name: (j['name'] ?? '').toString(),
        path: (j['path'] ?? '').toString(),
        absolute: (j['absolute'] ?? '').toString(),
        type: (j['type'] ?? 'file').toString(),
        ignored: j['ignored'] == true,
      );

  bool get isDir => type == 'directory';
}

class FileContent {
  final String type; // text | binary
  final String content;
  final String? mimeType;
  const FileContent({
    required this.type,
    required this.content,
    this.mimeType,
  });

  factory FileContent.fromJson(Map<String, dynamic> j) => FileContent(
        type: (j['type'] ?? 'text').toString(),
        content: (j['content'] ?? '').toString(),
        mimeType: j['mimeType']?.toString(),
      );
}

class FileDiff {
  final String file;
  final String patch; // unified diff text
  final int additions;
  final int deletions;
  final String status; // added | deleted | modified
  const FileDiff({
    required this.file,
    required this.patch,
    required this.additions,
    required this.deletions,
    required this.status,
  });

  factory FileDiff.fromJson(Map<String, dynamic> j) => FileDiff(
        file: (j['file'] ?? '').toString(),
        patch: (j['patch'] ?? '').toString(),
        additions: _i(j['additions']),
        deletions: _i(j['deletions']),
        status: (j['status'] ?? 'modified').toString(),
      );

  String get fileName => file.split('/').last;
}

/// A single rendered line of a unified diff.
class DiffLine {
  /// '+' added | '-' removed | ' ' context | '@' hunk header
  final String kind;
  final String text;
  final int? oldNo;
  final int? newNo;
  const DiffLine(this.kind, this.text, this.oldNo, this.newNo);
}

/// Parse a unified diff (`git diff` style) into renderable [DiffLine]s with
/// old/new line numbers, so the UI can show dual gutters.
List<DiffLine> parseUnifiedDiff(String patch) {
  final lines = patch.split('\n');
  final out = <DiffLine>[];
  int oldNo = 0;
  int newNo = 0;
  for (final raw in lines) {
    if (raw.startsWith('@@')) {
      // @@ -l,s +l,s @@
      final m = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@')
          .firstMatch(raw);
      if (m != null) {
        oldNo = int.tryParse(m.group(1)!) ?? 0;
        newNo = int.tryParse(m.group(2)!) ?? 0;
      }
      out.add(DiffLine('@', raw, null, null));
      continue;
    }
    if (raw.startsWith('+')) {
      out.add(DiffLine('+', raw.substring(1), null, newNo));
      newNo++;
    } else if (raw.startsWith('-')) {
      out.add(DiffLine('-', raw.substring(1), oldNo, null));
      oldNo++;
    } else if (raw.startsWith(' ')) {
      out.add(DiffLine(' ', raw.substring(1), oldNo, newNo));
      oldNo++;
      newNo++;
    } else if (raw.isEmpty) {
      // Trailing newline artifact; skip.
      continue;
    } else {
      // Unprefixed line (e.g. diff header like "diff --git ..." / "+++ ...").
      out.add(DiffLine('h', raw, null, null));
    }
  }
  return out;
}
