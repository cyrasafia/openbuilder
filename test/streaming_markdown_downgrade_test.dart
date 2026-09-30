import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Per-part streaming render: an unfinished assistant message (finish == null)
/// renders each part as it arrives — a part still receiving deltas downgrades
/// to plain Text (no full-document markdown re-parse per token, JANK-4), while
/// a part whose text.ended arrived (DisplayPart.settled) switches to MarkdownBody
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
  testWidgets('streaming renders per part: delta plain, ended markdown',
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
        'delta': 'streaming **bold** body',
      },
    ));
    await tester.pump();

    // In-flight part → plain-Text downgrade: visible immediately, no markdown
    // re-parse, no SelectableText registrar overhead.
    expect(find.byType(SelectableText), findsNothing);
    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('streaming **bold** body'), findsOneWidget);

    // Part settles (text.ended) while the message is STILL streaming
    // (finish == null): the completed part switches to markdown at once.
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
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );
    // Markdown-rendered: the raw ** markers must not survive as literal text.
    expect(
      find.textContaining('**bold**', findRichText: true),
      findsNothing,
    );

    // A second part starts streaming: it renders as plain text downgrade while
    // the first part stays markdown (not duplicated, not downgraded).
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
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.text('part two'), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );

    // Message settle: step.ended carries finish → every part goes markdown via
    // the message cache path; the plain-Text downgrade disappears (exactly one
    // rendered copy of the second part remains — the markdown paragraph).
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'session.step.ended',
      properties: {
        'sessionID': sid,
        'assistantMessageID': 'a1',
        'finish': 'stop',
      },
    ));
    await tester.pumpAndSettle();
    // Flush the streaming-preview throttle timer (120ms trailing edge) armed
    // by the last delta so no Timer is pending at test end.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(MarkdownBody), findsNWidgets(2));
    expect(find.textContaining('part two'), findsOneWidget);
    expect(
      find.textContaining('streaming', findRichText: true),
      findsOneWidget,
    );
  });
}
