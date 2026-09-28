import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'v2_test_fixtures.dart';

class _MockClient extends OpencodeClient {
  final List<SessionMessage> entries;
  _MockClient(this.entries) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async =>
      MessagesPage(entries, null, null);
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
  required List<SessionMessage> entries,
}) async {
  SharedPreferences.setMockInitialValues({});
  serverStore.client = _MockClient(entries);
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

Padding _messagePadding(WidgetTester tester, String id) =>
    find
        .byKey(ValueKey(id))
        .evaluate()
        .map((e) => e.widget)
        .whereType<Padding>()
        .single;

void main() {
  testWidgets(
    'streaming token prunes finished messages, rebuilds only the streaming one',
    (tester) async {
      const sid = 'stream-prune';
      final entries = <SessionMessage>[
        userMsg(id: 'u1', text: 'question', created: 1000),
        assistantMsg(
          id: 'a1',
          created: 2000,
          content: [textPart('finished reply')],
          finish: 'stop',
        ),
        assistantMsg(
          id: 'a2',
          created: 3000,
          content: [textPart('streaming')],
        ),
      ];
      await _pumpConversation(tester, sessionId: sid, entries: entries);
      for (var i = 0;
          i < 40 && find.byKey(const ValueKey('a2')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final a1Before = _messagePadding(tester, 'a1');
      final a2Before = _messagePadding(tester, 'a2');

      final store = serverStore.conversationFor(sid);
      expect(store, isNotNull, reason: 'conversation store must be wired');
      store!.onStepStarted('a2');
      store.onTextDelta('a2', 0, ' more');
      await tester.pump();
      await tester.pump();

      final a1After = _messagePadding(tester, 'a1');
      final a2After = _messagePadding(tester, 'a2');

      expect(
        identical(a1Before, a1After),
        isTrue,
        reason: 'finished message a1 must be pruned (identity short-circuit): '
            'same Padding instance across the streaming token. If this fails, '
            'either the cache was cleared (version bumped per token?) or the '
            'finished message is being mis-classified as streaming.',
      );
      expect(
        identical(a2Before, a2After),
        isFalse,
        reason: 'streaming message a2 must rebuild on each token '
            '(fresh Padding instance).',
      );
    },
  );
}
