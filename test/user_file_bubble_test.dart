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

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

/// The user bubble is the maxWidth-320 container mounted by `_userBubble`.
Finder _bubble(Finder host) => find.descendant(
      of: host,
      matching: find.byWidgetPredicate(
        (w) => w is Container && w.constraints == const BoxConstraints(maxWidth: 320),
      ),
    );

void main() {
  // A file-only user message carries an empty text part on the wire
  // (`_toDisplay` always prepends one). Rendering that empty part used to add
  // ~4px markdown padding above and demote the file chip to "not first",
  // stacking another 6px — the bubble's top gap was visibly larger than the
  // bottom. The renderer must skip empty text parts so the file is the sole,
  // first child and both inner paddings stay at 12.
  testWidgets(
    'file-only user bubble has symmetric vertical padding',
    (tester) async {
      const sid = 'file-bubble';
      await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          userMsg(
            id: 'u1',
            text: '',
            created: 1000,
            files: [
              {'uri': 'data:application/pdf;base64,AAAA', 'name': 'report.pdf'},
            ],
          ),
          assistantMsg(
            id: 'a1',
            created: 2000,
            content: [textPart('ok')],
            finish: 'stop',
          ),
        ],
      );

      final host = find.byKey(const ValueKey('uc:u1'));
      await _settle(
        tester,
        () => find.text('report.pdf').evaluate().isNotEmpty,
      );
      expect(host, findsOneWidget);
      expect(find.text('report.pdf'), findsOneWidget);

      final bubble = _bubble(host);
      expect(bubble, findsOneWidget);

      final bubbleRect = tester.getRect(bubble);
      final fileRect = tester.getRect(find.text('report.pdf'));
      final topGap = fileRect.top - bubbleRect.top;
      final bottomGap = bubbleRect.bottom - fileRect.bottom;

      expect(
        (topGap - bottomGap).abs(),
        lessThan(1.0),
        reason: 'file-only bubble content must be vertically centered '
            '(top=$topGap, bottom=$bottomGap)',
      );
      expect(
        fileRect.center.dy,
        closeTo(bubbleRect.center.dy, 1.0),
        reason: 'the sole file row must sit at the bubble center',
      );
    },
  );
}
