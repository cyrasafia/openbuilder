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

/// Locks 方案 B 的头条收益：流式逐 token 时，已完成消息被剪枝（identity
/// 短路——同一 widget 实例），仅流式消息重建。
///
/// 机制：`_cachedMessage` 缓存已完成消息的 `_message(...)` widget 实例；版本
/// 门控 clear 不会逐 token 触发（`onPartUpdated` 原地变异、不 bump
/// `messagesVersion`）。故流式 rebuild 时，已完成消息缓存的 `Padding`
/// （key = `ValueKey(id)`）是同一实例 → `Element.updateChild` 短路 → 整棵消息
/// 子树不 rebuild。流式消息（`finish==null`）每帧重建（新实例）。

class _MockClient extends OpencodeClient {
  final List<MessageEntry> entries;
  _MockClient(this.entries) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? before,
  }) async =>
      MessagesPage(entries, null);

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
  required List<MessageEntry> entries,
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

/// The `_message(...)` subtree's top widget is a `Padding` keyed
/// `ValueKey(id)`. After a prune (cache hit) it is the identical instance; after
/// a rebuild it is a fresh instance.
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
      final entries = <MessageEntry>[
        MessageEntry(
          info: MessageInfo(
            id: 'u1',
            role: 'user',
            sessionID: sid,
            created: 1000,
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pu1', 'text': 'question'}),
          ],
        ),
        MessageEntry(
          info: MessageInfo(
            id: 'a1',
            role: 'assistant',
            sessionID: sid,
            created: 2000,
            finish: 'stop',
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pa1', 'text': 'finished reply'}),
          ],
        ),
        MessageEntry(
          // finish omitted → streaming (finish == null)
          info: MessageInfo(
            id: 'a2',
            role: 'assistant',
            sessionID: sid,
            created: 3000,
          ),
          parts: [
            MessagePart({'type': 'text', 'id': 'pa2', 'text': 'streaming'}),
          ],
        ),
      ];
      await _pumpConversation(tester, sessionId: sid, entries: entries);
      // Wait for the conversation to load + lay out.
      for (var i = 0;
          i < 40 && find.byKey(const ValueKey('a2')).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      final a1Before = _messagePadding(tester, 'a1');
      final a2Before = _messagePadding(tester, 'a2');

      // Simulate a streaming token on a2: in-place part mutation, no
      // messagesVersion bump (the load-bearing fact for 方案 B).
      final store = serverStore.conversationFor(sid);
      expect(store, isNotNull, reason: 'conversation store must be wired');
      store!.onPartUpdated(
        {'type': 'text', 'id': 'pa2', 'messageID': 'a2'},
        ' more',
      );
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
