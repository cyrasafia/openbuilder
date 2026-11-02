import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'v2_test_fixtures.dart';

/// Per-part streaming render: an unfinished assistant message (finish == null)
/// renders each part as it arrives — a part still receiving deltas renders the
/// line-prefix markdown through GptMarkdown, while a part whose text.ended
/// arrived (DisplayPart.settled) switches to the final markdown view
/// immediately even though the message keeps streaming. Message settle
/// (step.ended carries finish) keeps the markdown render via the cache path.
class _MockClient extends OpencodeClient {
  _MockClient() : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async =>
      const MessagesPage([], null, null);
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

Future<void> _pumpConversation(
  WidgetTester tester, {
  required String sessionId,
}) async {
  SharedPreferences.setMockInitialValues({});
  serverStore.client = _MockClient();
  serverStore.upsertSessionForTesting(SessionModel(
    id: sessionId,
    projectID: 'p',
    directory: '',
    title: 'T',
    created: 1,
    updated: 2,
  ));
  final router = GoRouter(
    initialLocation: '/session/$sessionId',
    routes: [
      GoRoute(
        path: '/session/:id',
        builder: (_, s) =>
            ConversationScreen(sessionId: s.pathParameters['id']!),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('streaming renders per part: delta markdown, ended markdown',
      (tester) async {
    const sid = 'jank4';
    await _pumpConversation(tester, sessionId: sid);
    await _settle(
        tester, () => serverStore.conversationForRead(sid)?.loaded ?? false);
    // Open the transition gate (~300ms route animation) so the message body is
    // actually mounted before asserting on rendered output — otherwise the
    // streaming-phase expectations below would pass vacuously behind
    // SizedBox.shrink.
    await tester.pump(const Duration(milliseconds: 600));

    // Start an unfinished assistant message and stream tokens into it.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.step.started',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
      },
    ));
    await tester.pump();
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.text.delta',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'ordinal': 0,
        'delta': 'streaming **bold** body\n',
      },
    ));
    await tester.pump();

    // In-flight part → line-prefix markdown: no SelectableText registrar
    // overhead, and the raw markdown markers are not shown as literal text.
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(
      find.textContaining('**bold**', findRichText: true),
      findsNothing,
    );

    // Part settles (text.ended) while the message is STILL streaming
    // (finish == null): the completed part switches to the final markdown view.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.text.ended',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'ordinal': 0,
        'text': 'streaming **bold** body',
      },
    ));
    await tester.pumpAndSettle();
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('**bold**', findRichText: true),
      findsNothing,
    );

    // A second part starts streaming: its first unfinished line is hidden, so
    // only the first part remains visible while the message keeps streaming.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.text.started',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'ordinal': 1,
      },
    ));
    await tester.pump();
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.text.delta',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'ordinal': 1,
        'delta': 'part two',
      },
    ));
    await tester.pump();
    expect(find.byType(GptMarkdown), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );

    // Message settle: step.ended carries finish → every part goes to the final
    // markdown view via the cache path; exactly one copy of each part remains.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.step.ended',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'finish': 'stop',
      },
    ));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(GptMarkdown), findsNWidgets(2));
    expect(find.textContaining('part two'), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('user messages stay on flutter_markdown_plus', (tester) async {
    const sid = 'jank4-user';
    await _pumpConversation(tester, sessionId: sid);
    await _settle(
        tester, () => serverStore.conversationForRead(sid)?.loaded ?? false);
    await tester.pump(const Duration(milliseconds: 600));

    serverStore.conversationForRead(sid)!
        .debugInsertForTest(userMsg(id: 'u1', text: 'plain user text'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.byType(GptMarkdown), findsNothing);
  });
}
