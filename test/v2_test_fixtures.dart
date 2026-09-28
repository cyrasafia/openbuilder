import 'package:dio/dio.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

UserMessage userMsg({
  String id = 'msg_u1',
  String text = 'hello',
  int created = 1000,
  List<Map<String, dynamic>> files = const [],
}) =>
    SessionMessage.fromJson({
      'id': id,
      'type': 'user',
      'time': {'created': created},
      'text': text,
      if (files.isNotEmpty) 'files': files,
    }) as UserMessage;

AssistantMessage assistantMsg({
  String id = 'msg_a1',
  int created = 1100,
  List<AssistantContent> content = const [],
  String? finish,
  double cost = 0,
  String agent = 'build',
  Map<String, dynamic>? error,
  Map<String, dynamic>? model,
}) =>
    SessionMessage.fromJson({
      'id': id,
      'type': 'assistant',
      'time': {'created': created},
      'agent': agent,
      'model': ?model,
      'content': [
        for (final c in content) _contentToWire(c),
      ],
      'finish': ?finish,
      if (cost != 0) 'cost': cost,
      'error': ?error,
    }) as AssistantMessage;

SessionMessage syntheticMsg({
  String id = 'msg_s1',
  int created = 1050,
  String text = 'note',
  String? description,
}) =>
    SessionMessage.fromJson({
      'id': id,
      'type': 'synthetic',
      'time': {'created': created},
      'text': text,
      'description': ?description,
    });

TextContent textPart(String text, {String? id}) =>
    TextContent(id: id, text: text);

ReasoningContent reasoningPart(String text, {String? id}) =>
    ReasoningContent(id: id, text: text);

ToolContent toolPart({
  String id = 'call_1',
  String name = 'bash',
  String status = 'completed',
  Map<String, dynamic>? input,
  String? output,
  String? error,
  Map<String, dynamic>? metadata,
  int created = 1150,
}) =>
    ToolContent(
      id: id,
      name: name,
      executed: true,
      created: created,
      state: _toolState(status, input, output, error, metadata),
    );

ToolState _toolState(
  String status,
  Map<String, dynamic>? input,
  String? output,
  String? error,
  Map<String, dynamic>? metadata,
) {
  switch (status) {
    case 'streaming':
      return StreamingToolState(input: '');
    case 'running':
      return RunningToolState(input: input, metadata: metadata);
    case 'error':
      return ErrorToolState(
        input: input,
        error: StructuredError(
          type: 'error',
          message: error ?? 'tool failed',
        ),
        metadata: metadata,
      );
    default:
      return CompletedToolState(
        input: input,
        content: output == null || output.isEmpty
            ? const []
            : [ToolContentItem(type: 'text', text: output)],
        metadata: metadata,
      );
  }
}

Map<String, dynamic> _contentToWire(AssistantContent c) => switch (c) {
      TextContent() => {'type': 'text', 'text': c.text},
      ReasoningContent() => {'type': 'reasoning', 'text': c.text},
      ToolContent() => {
          'type': 'tool',
          'id': c.id,
          'name': c.name,
          'executed': c.executed,
          'time': {'created': c.created},
          'state': _toolStateToWire(c.state),
        },
    };

Map<String, dynamic> _toolStateToWire(ToolState s) => switch (s) {
      StreamingToolState() =>
        {'status': 'streaming', 'input': s.input},
      RunningToolState() => {
          'status': 'running',
          if (s.input != null) 'input': s.input,
          if (s.metadata != null) 'metadata': s.metadata,
        },
      CompletedToolState() => {
          'status': 'completed',
          if (s.input != null) 'input': s.input,
          if (s.content.isNotEmpty)
            'content': [
              for (final c in s.content) {'type': c.type, 'text': c.text},
            ],
          if (s.metadata != null) 'metadata': s.metadata,
        },
      ErrorToolState() => {
          'status': 'error',
          if (s.input != null) 'input': s.input,
          'error': {'type': 'error', 'message': s.error.message},
          if (s.content.isNotEmpty)
            'content': [
              for (final c in s.content) {'type': c.type, 'text': c.text},
            ],
        },
    };

class PageMockClient extends OpencodeClient {
  final List<SessionMessage> entries;
  final String? olderCursor;
  final String? pendingOlderCursor;
  PageMockClient(
    this.entries, {
    this.olderCursor,
    this.pendingOlderCursor,
  }) : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? cursor}) async {
    if (cursor != null) {
      return MessagesPage(const [], pendingOlderCursor, null);
    }
    return MessagesPage(entries, olderCursor, null);
  }
}

FormInfo formInfo({
  String id = 'frm_1',
  String sessionID = 'ses_1',
  String title = 'Proceed?',
  List<FormFieldSpec> fields = const [],
  String stateStatus = 'pending',
}) =>
    FormInfo.fromJson({
      'id': id,
      'sessionID': sessionID,
      'title': title,
      'fields': [
        for (final f in fields)
          {
            'key': f.key,
            'type': f.type,
            'title': f.title,
            'description': f.description,
            'required': f.required,
            'options': [
              for (final o in f.options)
                {'value': o.value, 'label': o.label},
            ],
          },
      ],
      if (stateStatus != 'pending') 'state': {'status': stateStatus},
    });

FormFieldSpec selectField(
  String key, {
  String? title,
  List<FormOption> options = const [],
}) =>
    FormFieldSpec(
      key: key,
      type: 'string',
      title: title,
      options: options,
    );

FormOption option(String value, String label) =>
    FormOption(value: value, label: label);

List<ToolContentItem> toolContent(String text) =>
    [ToolContentItem(type: 'text', text: text)];
