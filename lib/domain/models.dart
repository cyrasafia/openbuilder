import 'package:flutter/foundation.dart';

class ProjectModel {
  final String id;
  final String canonical;
  final String? vcs;
  final String? name;
  final ProjectIcon? icon;
  final ProjectCommands? commands;
  final List<String> sandboxes;
  final int created;
  final int updated;
  final int active;

  const ProjectModel({
    required this.id,
    required this.canonical,
    this.vcs,
    this.name,
    this.icon,
    this.commands,
    this.sandboxes = const [],
    this.created = 0,
    this.updated = 0,
    this.active = 0,
  });

  factory ProjectModel.fromJson(Map<String, dynamic> j) {
    final time = (j['time'] as Map?) ?? const {};
    return ProjectModel(
      id: (j['id'] ?? '').toString(),
      canonical: (j['canonical'] ?? j['worktree'] ?? '').toString(),
      vcs: j['vcs']?.toString(),
      name: j['name']?.toString(),
      icon: j['icon'] is Map ? ProjectIcon.fromJson(j['icon']) : null,
      commands: j['commands'] is Map
          ? ProjectCommands.fromJson(
              (j['commands'] as Map).cast<String, dynamic>(),
            )
          : null,
      sandboxes: (j['sandboxes'] as List? ?? [])
          .map((e) => e.toString())
          .toList(growable: false),
      created: _i(time['created']),
      updated: _i(time['updated']),
      active: _i(time['active']),
    );
  }

  String get worktreeName =>
      canonical.isEmpty || canonical == '/' ? 'global' : canonical.split('/').last;

  bool get workspacesEnabled => commands != null;

  bool get workspaceCapable => id != 'global' && vcs != null && vcs!.isNotEmpty;

  String get displayName {
    final n = name;
    if (n != null && n.trim().isNotEmpty) return n;
    return worktreeName;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'canonical': canonical,
    if (vcs != null) 'vcs': vcs,
    if (name != null) 'name': name,
    if (icon != null) 'icon': icon!.toJson(),
    if (commands != null) 'commands': commands!.toJson(),
    'sandboxes': sandboxes,
    'time': {'created': created, 'updated': updated, 'active': active},
  };
}

class ProjectCommands {
  final String? start;

  const ProjectCommands({this.start});

  factory ProjectCommands.fromJson(Map<String, dynamic> j) =>
      ProjectCommands(start: j['start']?.toString());

  Map<String, dynamic> toJson() => {if (start != null) 'start': start};
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

  Map<String, dynamic> toJson() => {
    if (url != null) 'url': url,
    if (override != null) 'override': override,
    if (color != null) 'color': color,
  };

  String? get image => override ?? url;
}

class CommandInfo {
  final String name;
  final String description;
  final String? agent;
  final bool skill;
  const CommandInfo({
    required this.name,
    this.description = '',
    this.agent,
    this.skill = false,
  });

  factory CommandInfo.fromJson(Map<String, dynamic> j) => CommandInfo(
    name: (j['name'] ?? '').toString(),
    description: (j['description'] ?? '').toString(),
    agent: j['agent']?.toString(),
    skill: j['skill'] == true || j['source'] == 'skill',
  );

  String get slash => name.startsWith('/') ? name : '/$name';
}

class SkillInfo {
  final String id;
  final String name;
  final String? description;
  const SkillInfo({required this.id, required this.name, this.description});

  factory SkillInfo.fromJson(Map<String, dynamic> j) => SkillInfo(
    id: (j['id'] ?? '').toString(),
    name: (j['name'] ?? j['id'] ?? '').toString(),
    description: j['description']?.toString(),
  );
}

class Tokens {
  final int input;
  final int output;
  final int reasoning;
  final int cacheRead;
  final int cacheWrite;
  const Tokens({
    this.input = 0,
    this.output = 0,
    this.reasoning = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
  });

  int get total => input + output;

  factory Tokens.fromJson(Map<String, dynamic> j) {
    final cache = (j['cache'] as Map?) ?? const {};
    return Tokens(
      input: _i(j['input']),
      output: _i(j['output']),
      reasoning: _i(j['reasoning']),
      cacheRead: _i(cache['read']),
      cacheWrite: _i(cache['write']),
    );
  }

  Map<String, dynamic> toJson() => {
    'input': input,
    'output': output,
    'reasoning': reasoning,
    'cache': {'read': cacheRead, 'write': cacheWrite},
  };
}

class SessionModel {
  final String id;
  final String projectID;
  final String directory;
  final String title;
  final int created;
  final int updated;
  final int? archived;
  final int? metadataArchivedAt;
  final String? parentID;
  final double cost;
  final Tokens tokens;
  final String? agent;
  final ModelRef? model;
  final String? outcome;
  final int? idle;
  final int? viewed;
  final String? subpath;

  const SessionModel({
    required this.id,
    required this.projectID,
    required this.directory,
    required this.title,
    required this.created,
    required this.updated,
    this.archived,
    this.metadataArchivedAt,
    this.parentID,
    this.cost = 0,
    this.tokens = const Tokens(),
    this.agent,
    this.model,
    this.outcome,
    this.idle,
    this.viewed,
    this.subpath,
  });

  factory SessionModel.fromJson(Map<String, dynamic> j) {
    final time = (j['time'] as Map?) ?? const {};
    final archivedAt = _i(time['archived']);
    final metadata = (j['metadata'] as Map?) ?? const {};
    final location = (j['location'] as Map?) ?? const {};
    return SessionModel(
      id: (j['id'] ?? '').toString(),
      projectID: (j['projectID'] ?? '').toString(),
      directory: (location['directory'] ?? j['directory'] ?? '').toString(),
      title: (j['title'] ?? 'Untitled').toString(),
      created: _i(time['created']),
      updated: _i(time['updated']),
      archived: archivedAt != 0 ? archivedAt : null,
      metadataArchivedAt: _ni(metadata['archivedAt']),
      parentID: j['parentID']?.toString(),
      cost: _d(j['cost']),
      tokens: j['tokens'] is Map
          ? Tokens.fromJson(j['tokens'] as Map<String, dynamic>)
          : const Tokens(),
      agent: j['agent']?.toString(),
      model: j['model'] is Map
          ? ModelRef.fromJson((j['model'] as Map).cast<String, dynamic>())
          : null,
      outcome: j['outcome']?.toString(),
      idle: _ni(time['idle']),
      viewed: _ni(time['viewed']),
      subpath: j['subpath']?.toString(),
    );
  }

  SessionModel copyWith({
    String? title,
    String? agent,
    ModelRef? model,
    double? cost,
    Tokens? tokens,
    int? updated,
    int? idle,
    int? viewed,
    String? outcome,
  }) =>
      SessionModel(
        id: id,
        projectID: projectID,
        directory: directory,
        title: title ?? this.title,
        created: created,
        updated: updated ?? this.updated,
        archived: archived,
        metadataArchivedAt: metadataArchivedAt,
        parentID: parentID,
        cost: cost ?? this.cost,
        tokens: tokens ?? this.tokens,
        agent: agent ?? this.agent,
        model: model ?? this.model,
        outcome: outcome ?? this.outcome,
        idle: idle ?? this.idle,
        viewed: viewed ?? this.viewed,
        subpath: subpath,
      );

  String get dirName =>
      directory.isEmpty ? 'global' : directory.split('/').last;

  bool get isArchived => archived != null || metadataArchivedAt != null;

  SessionModel withMetadataArchivedAt(int? at) => SessionModel(
        id: id,
        projectID: projectID,
        directory: directory,
        title: title,
        created: created,
        updated: updated,
        archived: archived,
        metadataArchivedAt: at,
        parentID: parentID,
        cost: cost,
        tokens: tokens,
        agent: agent,
        model: model,
        outcome: outcome,
        idle: idle,
        viewed: viewed,
        subpath: subpath,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'projectID': projectID,
    'location': {'directory': directory},
    'title': title,
    'time': {
      'created': created,
      'updated': updated,
      if (archived != null) 'archived': archived,
      if (idle != null) 'idle': idle,
      if (viewed != null) 'viewed': viewed,
    },
    if (metadataArchivedAt != null)
      'metadata': {'archivedAt': metadataArchivedAt},
    if (parentID != null) 'parentID': parentID,
    if (cost != 0) 'cost': cost,
    'tokens': tokens.toJson(),
    if (agent != null) 'agent': agent,
    if (model != null) 'model': model!.toJson(),
    if (outcome != null) 'outcome': outcome,
    if (subpath != null) 'subpath': subpath,
  };
}

class SessionStatusValue {
  final String type;
  final String? message;

  const SessionStatusValue(this.type, {this.message});

  Map<String, dynamic> toJson() => {
    'type': type,
    if (message != null) 'message': message,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionStatusValue &&
      other.type == type &&
      other.message == message;

  @override
  int get hashCode => Object.hash(type, message);
}

enum AgentRunState { working, retrying, idle, paused }

enum AgentPauseReason { permission, choice }

class AgentIndicatorState {
  final AgentRunState state;
  final AgentPauseReason? pauseReason;
  final int pendingCount;

  const AgentIndicatorState(
    this.state, {
    this.pauseReason,
    this.pendingCount = 0,
  }) : assert(
          (state == AgentRunState.paused &&
                  pauseReason != null &&
                  pendingCount >= 1) ||
              (state != AgentRunState.paused &&
                  pauseReason == null &&
                  pendingCount == 0),
        );

  @override
  bool operator ==(Object other) =>
      other is AgentIndicatorState &&
      other.state == state &&
      other.pauseReason == pauseReason &&
      other.pendingCount == pendingCount;

  @override
  int get hashCode => Object.hash(state, pauseReason, pendingCount);
}

sealed class SessionMessage {
  final String id;
  final Map<String, dynamic> raw;
  final Map<String, dynamic>? metadata;
  final int created;
  const SessionMessage({
    required this.id,
    required this.raw,
    this.metadata,
    required this.created,
  });

  factory SessionMessage.fromJson(Map<String, dynamic> j) {
    final id = (j['id'] ?? '').toString();
    final time = (j['time'] as Map?) ?? const {};
    final created = _i(time['created']);
    final metadata = j['metadata'] is Map
        ? (j['metadata'] as Map).cast<String, dynamic>()
        : null;
    switch (j['type']) {
      case 'user':
        return UserMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          text: (j['text'] ?? '').toString(),
          files: (j['files'] as List? ?? [])
              .whereType<Map>()
              .map((e) => FileAttachment.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false),
        );
      case 'assistant':
        return AssistantMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          streamed: _ni(time['streamed']),
          completed: _ni(time['completed']),
          agent: (j['agent'] ?? '').toString(),
          model: j['model'] is Map
              ? ModelRef.fromJson((j['model'] as Map).cast<String, dynamic>())
              : null,
          content: (j['content'] as List? ?? [])
              .whereType<Map>()
              .map((e) => AssistantContent.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false),
          snapshot: j['snapshot'] is Map
              ? SnapshotRef.fromJson((j['snapshot'] as Map).cast<String, dynamic>())
              : null,
          finish: j['finish']?.toString(),
          rawFinish: j['rawFinish']?.toString(),
          cost: _d(j['cost']),
          tokens: j['tokens'] is Map
              ? Tokens.fromJson((j['tokens'] as Map).cast<String, dynamic>())
              : null,
          error: j['error'] is Map
              ? StructuredError.fromJson(
                  (j['error'] as Map).cast<String, dynamic>())
              : null,
          retry: j['retry'] is Map
              ? RetryInfo.fromJson((j['retry'] as Map).cast<String, dynamic>())
              : null,
        );
      case 'agent-switched':
        return AgentSwitchedMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          agent: j['agent']?.toString(),
          previous: j['previous']?.toString(),
        );
      case 'model-switched':
        return ModelSwitchedMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          model: j['model'] is Map
              ? ModelRef.fromJson((j['model'] as Map).cast<String, dynamic>())
              : null,
          previous: j['previous'] is Map
              ? ModelRef.fromJson((j['previous'] as Map).cast<String, dynamic>())
              : null,
        );
      case 'location-switched':
        final loc = (j['location'] as Map?) ?? const {};
        return LocationSwitchedMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          directory: (loc['directory'] ?? '').toString(),
          projectID: (j['projectID'] ?? '').toString(),
          subpath: j['subpath']?.toString(),
          previous: (j['previous'] as Map?)?['directory']?.toString(),
        );
      case 'synthetic':
        return SyntheticMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          text: (j['text'] ?? '').toString(),
          description: j['description']?.toString(),
        );
      case 'system':
        return SystemMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          text: (j['text'] ?? '').toString(),
          description: j['description']?.toString(),
        );
      case 'skill':
        return SkillMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          skill: (j['skill'] ?? '').toString(),
          name: (j['name'] ?? '').toString(),
          text: (j['text'] ?? '').toString(),
        );
      case 'shell':
        final output = (j['output'] as Map?) ?? const {};
        return ShellMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          completed: _ni(time['completed']),
          shellID: (j['shellID'] ?? '').toString(),
          command: (j['command'] ?? '').toString(),
          status: (j['status'] ?? 'running').toString(),
          exit: _ni(j['exit']),
          output: output['output']?.toString() ?? '',
        );
      case 'compaction':
        return CompactionMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          status: (j['status'] ?? 'running').toString(),
          reason: j['reason']?.toString(),
          text: j['text']?.toString(),
          cost: _d(j['cost']),
          tokens: j['tokens'] is Map
              ? Tokens.fromJson((j['tokens'] as Map).cast<String, dynamic>())
              : null,
          error: j['error'] is Map
              ? StructuredError.fromJson(
                  (j['error'] as Map).cast<String, dynamic>())
              : null,
        );
      case 'idle':
        return IdleMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          outcome: j['outcome']?.toString(),
        );
      default:
        return UnknownMessage(
          id: id,
          raw: j,
          metadata: metadata,
          created: created,
          type: (j['type'] ?? '').toString(),
        );
    }
  }

  String get kind => switch (this) {
    UserMessage() => 'user',
    AssistantMessage() => 'assistant',
    AgentSwitchedMessage() => 'agent-switched',
    ModelSwitchedMessage() => 'model-switched',
    LocationSwitchedMessage() => 'location-switched',
    SyntheticMessage() => 'synthetic',
    SystemMessage() => 'system',
    SkillMessage() => 'skill',
    ShellMessage() => 'shell',
    CompactionMessage() => 'compaction',
    IdleMessage() => 'idle',
    UnknownMessage() => (raw['type'] ?? '').toString(),
  };

  Map<String, dynamic> toJson() => raw;
}

class UserMessage extends SessionMessage {
  final String text;
  final List<FileAttachment> files;
  const UserMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.text,
    this.files = const [],
  });
}

class AssistantMessage extends SessionMessage {
  final int? streamed;
  final int? completed;
  final String agent;
  final ModelRef? model;
  final List<AssistantContent> content;
  final SnapshotRef? snapshot;
  final String? finish;
  final String? rawFinish;
  final double cost;
  final Tokens? tokens;
  final StructuredError? error;
  final RetryInfo? retry;
  const AssistantMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    this.streamed,
    this.completed,
    required this.agent,
    required this.model,
    required this.content,
    this.snapshot,
    this.finish,
    this.rawFinish,
    this.cost = 0,
    this.tokens,
    this.error,
    this.retry,
  });
}

class AgentSwitchedMessage extends SessionMessage {
  final String? agent;
  final String? previous;
  const AgentSwitchedMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    this.agent,
    this.previous,
  });
}

class ModelSwitchedMessage extends SessionMessage {
  final ModelRef? model;
  final ModelRef? previous;
  const ModelSwitchedMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    this.model,
    this.previous,
  });
}

class LocationSwitchedMessage extends SessionMessage {
  final String directory;
  final String projectID;
  final String? subpath;
  final String? previous;
  const LocationSwitchedMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.directory,
    required this.projectID,
    this.subpath,
    this.previous,
  });
}

class SyntheticMessage extends SessionMessage {
  final String text;
  final String? description;
  const SyntheticMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.text,
    this.description,
  });
}

class SystemMessage extends SessionMessage {
  final String text;
  final String? description;
  const SystemMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.text,
    this.description,
  });
}

class SkillMessage extends SessionMessage {
  final String skill;
  final String name;
  final String text;
  const SkillMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.skill,
    required this.name,
    required this.text,
  });
}

class ShellMessage extends SessionMessage {
  final int? completed;
  final String shellID;
  final String command;
  final String status;
  final int? exit;
  final String output;
  const ShellMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    this.completed,
    required this.shellID,
    required this.command,
    required this.status,
    this.exit,
    this.output = '',
  });
}

class CompactionMessage extends SessionMessage {
  final String status;
  final String? reason;
  final String? text;
  final double cost;
  final Tokens? tokens;
  final StructuredError? error;
  const CompactionMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.status,
    this.reason,
    this.text,
    this.cost = 0,
    this.tokens,
    this.error,
  });
}

class IdleMessage extends SessionMessage {
  final String? outcome;
  const IdleMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    this.outcome,
  });
}

class UnknownMessage extends SessionMessage {
  final String type;
  const UnknownMessage({
    required super.id,
    required super.raw,
    super.metadata,
    required super.created,
    required this.type,
  });
}

sealed class AssistantContent {
  final String type;
  const AssistantContent(this.type);

  factory AssistantContent.fromJson(Map<String, dynamic> j) {
    switch (j['type']) {
      case 'text':
        return TextContent(
          id: j['id']?.toString(),
          text: (j['text'] ?? '').toString(),
        );
      case 'reasoning':
        return ReasoningContent(
          id: j['id']?.toString(),
          text: (j['text'] ?? '').toString(),
        );
      case 'tool':
        final time = (j['time'] as Map?) ?? const {};
        return ToolContent(
          id: (j['id'] ?? '').toString(),
          name: (j['name'] ?? '').toString(),
          executed: j['executed'] == true,
          state: ToolState.fromJson(
            (j['state'] as Map?)?.cast<String, dynamic>() ??
                const <String, dynamic>{},
          ),
          created: _i(time['created']),
          ran: _ni(time['ran']),
          completed: _ni(time['completed']),
        );
      default:
        return TextContent(id: j['id']?.toString(), text: j['text']?.toString() ?? '');
    }
  }
}

class TextContent extends AssistantContent {
  final String? id;
  final String text;
  const TextContent({this.id, required this.text}) : super('text');
}

class ReasoningContent extends AssistantContent {
  final String? id;
  final String text;
  const ReasoningContent({this.id, required this.text}) : super('reasoning');
}

class ToolContent extends AssistantContent {
  final String id;
  final String name;
  final bool executed;
  final ToolState state;
  final int created;
  final int? ran;
  final int? completed;
  const ToolContent({
    required this.id,
    required this.name,
    required this.executed,
    required this.state,
    required this.created,
    this.ran,
    this.completed,
  }) : super('tool');
}

sealed class ToolState {
  const ToolState();

  factory ToolState.fromJson(Map<String, dynamic> j) {
    switch (j['status']) {
      case 'streaming':
        return StreamingToolState(input: j['input']?.toString() ?? '');
      case 'running':
        return RunningToolState(
          input: _map(j['input']),
          metadata: _map(j['metadata']),
        );
      case 'completed':
        return CompletedToolState(
          input: _map(j['input']),
          content: (j['content'] as List? ?? [])
              .whereType<Map>()
              .map((e) => ToolContentItem.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false),
          metadata: _map(j['metadata']),
        );
      case 'error':
        return ErrorToolState(
          input: _map(j['input']),
          error: j['error'] is Map
              ? StructuredError.fromJson(
                  (j['error'] as Map).cast<String, dynamic>())
              : StructuredError(type: 'error', message: j['error']?.toString() ?? ''),
          content: (j['content'] as List? ?? [])
              .whereType<Map>()
              .map((e) => ToolContentItem.fromJson(e.cast<String, dynamic>()))
              .toList(growable: false),
          metadata: _map(j['metadata']),
        );
      default:
        return RunningToolState(input: _map(j['input']), metadata: null);
    }
  }

  String get status => switch (this) {
    StreamingToolState() => 'streaming',
    RunningToolState() => 'running',
    CompletedToolState() => 'completed',
    ErrorToolState() => 'error',
  };
}

class StreamingToolState extends ToolState {
  final String input;
  const StreamingToolState({required this.input});
}

class RunningToolState extends ToolState {
  final Map<String, dynamic>? input;
  final Map<String, dynamic>? metadata;
  const RunningToolState({this.input, this.metadata});
}

class CompletedToolState extends ToolState {
  final Map<String, dynamic>? input;
  final List<ToolContentItem> content;
  final Map<String, dynamic>? metadata;
  const CompletedToolState({
    this.input,
    required this.content,
    this.metadata,
  });
}

class ErrorToolState extends ToolState {
  final Map<String, dynamic>? input;
  final StructuredError error;
  final List<ToolContentItem> content;
  final Map<String, dynamic>? metadata;
  const ErrorToolState({
    this.input,
    required this.error,
    this.content = const [],
    this.metadata,
  });
}

class ToolContentItem {
  final String type;
  final String text;
  const ToolContentItem({required this.type, required this.text});

  factory ToolContentItem.fromJson(Map<String, dynamic> j) => ToolContentItem(
    type: (j['type'] ?? 'text').toString(),
    text: (j['text'] ?? '').toString(),
  );
}

class SnapshotRef {
  final String? start;
  final String? end;
  final List<String> files;
  const SnapshotRef({this.start, this.end, this.files = const []});

  factory SnapshotRef.fromJson(Map<String, dynamic> j) => SnapshotRef(
    start: j['start']?.toString(),
    end: j['end']?.toString(),
    files: (j['files'] as List? ?? []).map((e) => e.toString()).toList(),
  );
}

class StructuredError {
  final String type;
  final String message;
  final int? status;
  const StructuredError({required this.type, required this.message, this.status});

  factory StructuredError.fromJson(Map<String, dynamic> j) => StructuredError(
    type: (j['type'] ?? 'error').toString(),
    message: (j['message'] ?? '').toString(),
    status: _ni(j['status']),
  );

  Map<String, dynamic> toJson() =>
      {'type': type, 'message': message, if (status != null) 'status': status};
}

class RetryInfo {
  final int? attempt;
  final int? at;
  final StructuredError? error;
  const RetryInfo({this.attempt, this.at, this.error});

  factory RetryInfo.fromJson(Map<String, dynamic> j) => RetryInfo(
    attempt: _ni(j['attempt']),
    at: _ni(j['at']),
    error: j['error'] is Map
        ? StructuredError.fromJson((j['error'] as Map).cast<String, dynamic>())
        : null,
  );
}

class FileAttachment {
  final String uri;
  final String? name;
  final String? description;
  const FileAttachment({
    required this.uri,
    this.name,
    this.description,
  });

  factory FileAttachment.fromJson(Map<String, dynamic> j) => FileAttachment(
    uri: (j['uri'] ?? '').toString(),
    name: j['name']?.toString(),
    description: j['description']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'uri': uri,
    if (name != null) 'name': name,
    if (description != null) 'description': description,
  };
}

class Todo {
  final String? id;
  final String content;
  final String status;
  final String priority;
  const Todo({
    this.id,
    required this.content,
    required this.status,
    this.priority = 'medium',
  });

  factory Todo.fromJson(Map<String, dynamic> j) => Todo(
    id: j['id']?.toString(),
    content: (j['content'] ?? '').toString(),
    status: (j['status'] ?? 'pending').toString(),
    priority: (j['priority'] ?? 'medium').toString(),
  );

  bool get done => status == 'completed' || status == 'cancelled';
  bool get active => status == 'in_progress';
  bool get cancelled => status == 'cancelled';

  Map<String, dynamic> toJson() => {
    'id': id,
    'content': content,
    'status': status,
    'priority': priority,
  };
}

class WorktreeInfo {
  final String directory;
  final String strategy;
  const WorktreeInfo({required this.directory, this.strategy = 'git'});

  factory WorktreeInfo.fromJson(Map<String, dynamic> j) => WorktreeInfo(
    directory: (j['directory'] ?? '').toString(),
    strategy: (j['strategy'] ?? 'git').toString(),
  );
}

class Permission {
  final String id;
  final String action;
  final String sessionID;
  final List<String> resources;
  final List<String> save;
  final Map<String, dynamic>? metadata;
  final String? message;
  const Permission({
    required this.id,
    required this.action,
    required this.sessionID,
    this.resources = const [],
    this.save = const [],
    this.metadata,
    this.message,
  });

  String? get externalDirectoryPath =>
      _externalDirectoryPath(metadata, resources);

  factory Permission.fromJson(Map<String, dynamic> j) {
    final meta = j['metadata'] is Map
        ? (j['metadata'] as Map).cast<String, dynamic>()
        : null;
    final resources = j['resources'] is List
        ? (j['resources'] as List).map((e) => e.toString()).toList()
        : (j['patterns'] is List
              ? (j['patterns'] as List).map((e) => e.toString()).toList()
              : const <String>[]);
    return Permission(
      id: (j['id'] ?? j['requestID'] ?? '').toString(),
      action: (j['action'] ?? j['permission'] ?? j['type'] ?? '').toString(),
      sessionID: (j['sessionID'] ?? '').toString(),
      resources: resources,
      save: j['save'] is List
          ? (j['save'] as List).map((e) => e.toString()).toList()
          : const [],
      metadata: meta,
      message: j['message']?.toString(),
    );
  }
}

String? _externalDirectoryPath(
  Map<String, dynamic>? meta,
  List<String> patterns,
) {
  final parentDir = meta?['parentDir']?.toString();
  if (parentDir != null && parentDir.isNotEmpty) return parentDir;
  final filepath = meta?['filepath']?.toString();
  if (filepath != null && filepath.isNotEmpty) return filepath;
  for (final p in patterns) {
    if (p.endsWith('/*')) return p.substring(0, p.length - 2);
    if (p.isNotEmpty) return p;
  }
  return null;
}

int _i(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v) ?? 0;
  return 0;
}

int? _ni(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}

double _d(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v) ?? 0;
  return 0;
}

Map<String, dynamic>? _map(dynamic v) =>
    v is Map ? v.cast<String, dynamic>() : null;

class FileNode {
  final String name;
  final String path;
  final String absolute;
  final String type;
  const FileNode({
    required this.name,
    required this.path,
    required this.absolute,
    required this.type,
  });

  factory FileNode.fromJson(Map<String, dynamic> j) => FileNode(
    name: (j['name'] ?? '').toString(),
    path: (j['path'] ?? '').toString(),
    absolute: (j['absolute'] ?? '').toString(),
    type: (j['type'] ?? 'file').toString(),
  );

  factory FileNode.fromFsEntry(
    String path,
    String type, {
    String baseDirectory = '',
  }) {
    final isDir = type == 'directory';
    final normalized = isDir && path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    final segs = normalized.split('/').where((s) => s.isNotEmpty).toList();
    final base = baseDirectory.endsWith('/')
        ? baseDirectory.substring(0, baseDirectory.length - 1)
        : baseDirectory;
    return FileNode(
      name: segs.isEmpty ? normalized : segs.last,
      path: path,
      absolute: base.isEmpty ? normalized : '$base/$normalized',
      type: type,
    );
  }

  factory FileNode.fromSearchPath(String relPath) {
    final isDir = relPath.endsWith('/');
    final withoutSlash = isDir ? relPath.substring(0, relPath.length - 1) : relPath;
    final segs = withoutSlash.split('/').where((s) => s.isNotEmpty).toList();
    return FileNode(
      name: segs.isEmpty ? relPath : segs.last,
      path: relPath,
      absolute: '',
      type: isDir ? 'directory' : 'file',
    );
  }

  bool get isDir => type == 'directory';
}

class StreamedFile {
  final String type;
  final String? mimeType;
  final String? text;
  final Uint8List? bytes;

  const StreamedFile({
    required this.type,
    this.mimeType,
    this.text,
    this.bytes,
  });

  bool get isBinary => type == 'binary';
}

class FileDiff {
  final String file;
  final String patch;
  final int additions;
  final int deletions;
  final String status;
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

enum DiffMode { uncommitted, branch, lastMessage }

class DiffLine {
  final String kind;
  final String text;
  final int? oldNo;
  final int? newNo;
  const DiffLine(this.kind, this.text, this.oldNo, this.newNo);
}

class DiffHunk {
  final int? oldStart;
  final int? newStart;
  final List<DiffLine> lines;
  final int additions;
  final int deletions;
  const DiffHunk({
    required this.oldStart,
    required this.newStart,
    required this.lines,
    required this.additions,
    required this.deletions,
  });
}

List<DiffHunk> parseDiffHunks(String patch) {
  final out = <DiffHunk>[];
  final raws = patch.split('\n');
  const beforeHunk = 0;
  const inHunk = 1;
  var state = beforeHunk;
  int? oldStart;
  int? newStart;
  int oldNo = 0;
  int newNo = 0;
  var add = 0;
  var del = 0;
  final lines = <DiffLine>[];

  void flush() {
    if (lines.isNotEmpty) {
      out.add(DiffHunk(
        oldStart: oldStart,
        newStart: newStart,
        lines: List.unmodifiable(lines),
        additions: add,
        deletions: del,
      ));
    }
    lines.clear();
    add = 0;
    del = 0;
  }

  final hunkRe = RegExp(r'@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@');

  for (final raw in raws) {
    if (raw.startsWith('@@')) {
      flush();
      final m = hunkRe.firstMatch(raw);
      oldStart = m == null ? null : int.tryParse(m.group(1)!);
      newStart = m == null ? null : int.tryParse(m.group(2)!);
      oldNo = oldStart ?? 0;
      newNo = newStart ?? 0;
      state = inHunk;
      continue;
    }
    if (state == beforeHunk) continue;
    if (raw.startsWith('+')) {
      lines.add(DiffLine('+', raw.substring(1), null, newNo));
      newNo++;
      add++;
    } else if (raw.startsWith('-')) {
      lines.add(DiffLine('-', raw.substring(1), oldNo, null));
      oldNo++;
      del++;
    } else if (raw.startsWith(' ')) {
      lines.add(DiffLine(' ', raw.substring(1), oldNo, newNo));
      oldNo++;
      newNo++;
    } else if (raw.isEmpty) {
      continue;
    } else if (raw.startsWith('diff ') || raw.startsWith('index ')) {
      flush();
      break;
    } else {
      continue;
    }
  }
  flush();
  return out;
}

class ModelRef {
  final String id;
  final String providerID;
  final String? variant;
  const ModelRef({required this.id, required this.providerID, this.variant});

  factory ModelRef.fromJson(Map<String, dynamic> j) => ModelRef(
    id: (j['id'] ?? '').toString(),
    providerID: (j['providerID'] ?? '').toString(),
    variant: j['variant']?.toString(),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'providerID': providerID,
    if (variant != null) 'variant': variant,
  };

  @override
  String toString() => '$providerID/$id';
}

class AgentInfo {
  final String id;
  final String name;
  final String? description;
  final String mode;
  final bool hidden;
  const AgentInfo({
    required this.id,
    required this.name,
    this.description,
    required this.mode,
    this.hidden = false,
  });

  factory AgentInfo.fromJson(Map<String, dynamic> j) => AgentInfo(
    id: (j['id'] ?? '').toString(),
    name: (j['name'] ?? j['id'] ?? '').toString(),
    description: j['description']?.toString(),
    mode: (j['mode'] ?? 'primary').toString(),
    hidden: j['hidden'] == true,
  );
}

class ModelVariant {
  final String id;
  const ModelVariant({required this.id});

  factory ModelVariant.fromJson(Map<String, dynamic> j) =>
      ModelVariant(id: (j['id'] ?? '').toString());
}

class ModelInfo {
  final String id;
  final String providerID;
  final String name;
  final bool enabled;
  final String status;
  final List<ModelVariant> variants;
  const ModelInfo({
    required this.id,
    required this.providerID,
    required this.name,
    this.enabled = true,
    this.status = 'active',
    this.variants = const [],
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) {
    List<ModelVariant> variants;
    final raw = j['variants'];
    if (raw is List) {
      variants = raw
          .map((e) => ModelVariant.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } else if (raw is Map) {
      variants = raw.keys.map((k) => ModelVariant(id: k.toString())).toList();
    } else {
      variants = const [];
    }
    return ModelInfo(
      id: (j['id'] ?? '').toString(),
      providerID: (j['providerID'] ?? '').toString(),
      name: (j['name'] ?? j['id'] ?? '').toString(),
      enabled: j['enabled'] != false,
      status: (j['status'] ?? 'active').toString(),
      variants: variants,
    );
  }
}

class FormOption {
  final String value;
  final String label;
  final String? description;
  const FormOption({
    required this.value,
    required this.label,
    this.description,
  });

  factory FormOption.fromJson(Map<String, dynamic> j) => FormOption(
    value: (j['value'] ?? '').toString(),
    label: (j['label'] ?? j['value'] ?? '').toString(),
    description: j['description']?.toString(),
  );

  @override
  bool operator ==(Object other) =>
      other is FormOption &&
      other.value == value &&
      other.label == label &&
      other.description == description;

  @override
  int get hashCode => Object.hash(value, label, description);
}

class FormFieldSpec {
  final String key;
  final String type;
  final String? title;
  final String? description;
  final bool required;
  final bool hidden;
  final String? placeholder;
  final bool custom;
  final List<FormOption> options;
  final String? defaultValue;

  const FormFieldSpec({
    required this.key,
    required this.type,
    this.title,
    this.description,
    this.required = false,
    this.hidden = false,
    this.placeholder,
    this.custom = false,
    this.options = const [],
    this.defaultValue,
  });

  factory FormFieldSpec.fromJson(Map<String, dynamic> j) => FormFieldSpec(
    key: (j['key'] ?? '').toString(),
    type: (j['type'] ?? 'string').toString(),
    title: j['title']?.toString(),
    description: j['description']?.toString(),
    required: j['required'] == true,
    hidden: j['hidden'] == true,
    placeholder: j['placeholder']?.toString(),
    custom: j['custom'] == true,
    options: j['options'] is List
        ? (j['options'] as List)
              .map((e) => FormOption.fromJson((e as Map).cast<String, dynamic>()))
              .toList()
        : const [],
    defaultValue: j['default'] is List
        ? (j['default'] as List).map((e) => e.toString()).join(',')
        : j['default']?.toString(),
  );

  bool get isMultiselect => type == 'multiselect';

  @override
  bool operator ==(Object other) =>
      other is FormFieldSpec &&
      other.key == key &&
      other.type == type &&
      other.title == title &&
      other.required == required &&
      other.custom == custom &&
      other.options.length == options.length &&
      other.options.asMap().entries
          .every((e) => options[e.key] == e.value);

  @override
  int get hashCode => Object.hash(key, type, title, required);
}

class FormInfo {
  final String id;
  final String sessionID;
  final String title;
  final List<FormFieldSpec> fields;
  final String? stateStatus;
  const FormInfo({
    required this.id,
    required this.sessionID,
    required this.title,
    required this.fields,
    this.stateStatus,
  });

  factory FormInfo.fromJson(Map<String, dynamic> j) => FormInfo(
    id: (j['id'] ?? '').toString(),
    sessionID: (j['sessionID'] ?? '').toString(),
    title: (j['title'] ?? '').toString(),
    fields: j['fields'] is List
        ? (j['fields'] as List)
              .map((e) => FormFieldSpec.fromJson((e as Map).cast<String, dynamic>()))
              .toList()
        : const [],
    stateStatus: j['state'] is Map
        ? (j['state'] as Map)['status']?.toString()
        : null,
  );

  bool get pending => stateStatus == null || stateStatus == 'pending';

  @override
  bool operator ==(Object other) =>
      other is FormInfo &&
      other.id == id &&
      other.title == title &&
      other.stateStatus == stateStatus &&
      other.fields.length == fields.length &&
      other.fields.asMap().entries.every((e) => fields[e.key] == e.value);

  @override
  int get hashCode =>
      Object.hash(id, title, stateStatus, Object.hashAll(fields));
}
