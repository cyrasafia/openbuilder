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

/// User-message collapse: a user message whose natural height exceeds
/// screen-height × 0.4 (test surface 800×600 → 240px, plus a 24px minimum
/// gain) renders collapsed by default — clamped to 240px with an expand
/// affordance — and tapping toggles expand/collapse. Short messages get no
/// affordance at all.
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

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

MessageEntry _user(String sid, String id, String text, int created) =>
    MessageEntry(
      info: MessageInfo(id: id, role: 'user', sessionID: sid, created: created),
      parts: [MessagePart({'type': 'text', 'id': 'p$id', 'text': text})],
    );

MessageEntry _assistant(String sid, String id, String text, int created) =>
    MessageEntry(
      info: MessageInfo(
        id: id,
        role: 'assistant',
        sessionID: sid,
        created: created,
        finish: 'stop',
      ),
      parts: [MessagePart({'type': 'text', 'id': 'p$id', 'text': text})],
    );

void main() {
  testWidgets(
    'tall user message is collapsed by default and toggles on tap',
    (tester) async {
      const sid = 'uc-tall';
      final longText = List.generate(
        30,
        (i) => 'line $i of the long user message',
      ).join('\n\n');
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', longText, 1000),
          _assistant(sid, 'a1', 'ok', 2000),
        ],
      );

      final host = find.byKey(const ValueKey('uc:u1'));
      // The app bar's agent/model chips also carry expand_more icons — scope
      // every affordance lookup to the collapse host.
      final expandMore = find.descendant(
        of: host,
        matching: find.byIcon(Icons.expand_more),
      );
      final expandLess = find.descendant(
        of: host,
        matching: find.byIcon(Icons.expand_less),
      );
      await _settle(tester, () {
        if (host.evaluate().isEmpty) return false;
        return tester.getSize(host).height == 240.0;
      });
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'tall user message must be clamped to 40% of the 600px '
            'screen height by default',
      );
      expect(expandMore, findsOneWidget);

      await tester.tap(expandMore);
      await _settle(tester, () {
        if (expandLess.evaluate().isEmpty) return false;
        return tester.getSize(host).height > 240.0;
      });
      expect(
        tester.getSize(host).height,
        greaterThan(240.0),
        reason: 'expanding must restore the natural height',
      );

      await tester.tap(expandLess);
      await _settle(tester, () => tester.getSize(host).height == 240.0);
      expect(
        tester.getSize(host).height,
        240.0,
        reason: 'collapsing again must clamp back to the threshold',
      );
      expect(expandMore, findsOneWidget);
    },
  );

  testWidgets(
    'short user message has no collapse affordance',
    (tester) async {
      const sid = 'uc-short';
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          _user(sid, 'u1', 'question', 1000),
          _assistant(sid, 'a1', 'short reply', 2000),
        ],
      );
      await _settle(
        tester,
        () => find.textContaining('short reply').evaluate().isNotEmpty,
      );
      // Extra frames: collapse decision is event-driven; give it a chance to
      // (incorrectly) fire before asserting the affordance stays absent.
      await tester.pump(const Duration(milliseconds: 200));

      final host = find.byKey(const ValueKey('uc:u1'));
      expect(
        find.descendant(of: host, matching: find.byIcon(Icons.expand_more)),
        findsNothing,
      );
      expect(
        find.descendant(of: host, matching: find.byIcon(Icons.expand_less)),
        findsNothing,
      );
      expect(tester.getSize(host).height, lessThan(240.0));
    },
  );
}
