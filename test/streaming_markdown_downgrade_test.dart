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

/// JANK-4 streaming downgrade: an unfinished assistant text part (finish ==
/// null) must render as plain SelectableText (no full-document markdown
/// re-parse per token); when the message settles (message.updated carries
/// finish), the same part switches to MarkdownBody via the cache path.
class _MockClient extends OpencodeClient {
  _MockClient() : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? before,
  }) async =>
      MessagesPage(const [], null);

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
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
  testWidgets('streaming part renders plain text, settled renders markdown',
      (tester) async {
    const sid = 'jank4';
    await _pumpConversation(tester, sessionId: sid);
    await _settle(
        tester, () => serverStore.conversationForRead(sid)?.loaded ?? false);

    // Start an unfinished assistant message and stream tokens into it.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'message.updated',
      properties: {
        'info': {
          'id': 'a1',
          'role': 'assistant',
          'sessionID': sid,
          'time': {'created': 1000},
        },
      },
    ));
    await tester.pump();
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'message.part.updated',
      properties: {
        'part': {
          'id': 'pa1',
          'type': 'text',
          'messageID': 'a1',
          'sessionID': sid,
        },
        'delta': 'streaming **bold** body',
      },
    ));
    await tester.pump();

    // Unfinished → plain downgrade (SelectableText), not MarkdownBody.
    expect(find.byType(SelectableText), findsOneWidget);
    expect(find.text('streaming **bold** body'), findsOneWidget);
    expect(find.byType(MarkdownBody), findsNothing);

    // Settle: message.updated with finish → cache invalidation → markdown.
    serverStore.onEventForTesting(OpencodeEvent(
      type: 'message.updated',
      properties: {
        'info': {
          'id': 'a1',
          'role': 'assistant',
          'sessionID': sid,
          'time': {'created': 1000},
          'finish': 'stop',
        },
      },
    ));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('streaming'), findsOneWidget);
  });
}
