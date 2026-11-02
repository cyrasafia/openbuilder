import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'v2_test_fixtures.dart';

class _MockClient extends OpencodeClient {
  final List<SessionMessage> entries;
  final SessionModel session;

  _MockClient(this.entries, this.session)
    : super(
        Dio(
          BaseOptions(
            connectTimeout: const Duration(milliseconds: 1),
            receiveTimeout: const Duration(milliseconds: 1),
          ),
        ),
      );

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async => MessagesPage(entries, null, null);

  @override
  Future<List<SessionModel>> sessionsForDirectory(
    String directory, {
    int limit = 1000,
  }) async => [session];
}

class _Harness {
  final opened = <FileBrowsingSnapshot>[];
  final launched = <String>[];
}

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
}

Future<_Harness> _pumpConversation(
  WidgetTester tester, {
  required String sessionId,
  required List<SessionMessage> entries,
}) async {
  SharedPreferences.setMockInitialValues({});
  final session = SessionModel(
    id: sessionId,
    projectID: 'p',
    directory: '/home/u/proj',
    title: 'T',
    created: 1,
    updated: 2,
  );
  serverStore.client = _MockClient(entries, session);
  serverStore.upsertSessionForTesting(session);
  final harness = _Harness();
  final router = GoRouter(
    initialLocation: '/session/$sessionId',
    routes: [
      GoRoute(
        path: '/session/:id',
        builder: (_, s) =>
            ConversationScreen(sessionId: s.pathParameters['id']!),
      ),
      GoRoute(
        path: '/session/:id/files',
        builder: (_, s) {
          harness.opened.add(s.extra as FileBrowsingSnapshot);
          return const Scaffold(body: Text('file route'));
        },
      ),
    ],
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          if (call.method == 'launch') {
            harness.launched.add((call.arguments as Map)['url'] as String);
            return true;
          }
          return null;
        },
      );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        );
  });
  await tester.pumpWidget(
    MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await _settle(
    tester,
    () => serverStore.conversationForRead(sessionId)?.loaded ?? false,
  );
  await tester.pump(const Duration(milliseconds: 600));
  return harness;
}

void main() {
  testWidgets('user explicit relative file link opens the in-app file route', (
    tester,
  ) async {
    const sid = 'explicit-user-file';
    const path =
        'reports/20261102-pl-pd-write-strategy-three-experiments-report.md';
    final harness = await _pumpConversation(
      tester,
      sessionId: sid,
      entries: [userMsg(id: 'u1', text: '[User report]($path)')],
    );
    await _settle(tester, () => find.text('User report').evaluate().isNotEmpty);

    await tester.tap(find.text('User report'));
    await tester.pumpAndSettle();

    expect(harness.launched, isEmpty);
    expect(harness.opened, hasLength(1));
    expect(harness.opened.single.openFiles.single.path, path);
    expect(harness.opened.single.openFiles.single.initialLine, isNull);
    expect(harness.opened.single.peek, isTrue);
  });

  testWidgets(
    'settled assistant explicit file link preserves the line number',
    (tester) async {
      const sid = 'explicit-assistant-file';
      final harness = await _pumpConversation(
        tester,
        sessionId: sid,
        entries: [
          assistantMsg(
            id: 'a1',
            content: [textPart('[Assistant source](./src/a.ts:42)')],
            finish: 'stop',
          ),
        ],
      );
      final link = find.textContaining('Assistant source', findRichText: true);
      await _settle(tester, () => link.evaluate().isNotEmpty);

      await tester.tap(link);
      await tester.pumpAndSettle();

      expect(harness.launched, isEmpty);
      expect(harness.opened, hasLength(1));
      expect(harness.opened.single.openFiles.single.path, 'src/a.ts');
      expect(harness.opened.single.openFiles.single.initialLine, 42);
      expect(harness.opened.single.openFiles.single.showSource, isTrue);
    },
  );

  testWidgets('streaming assistant explicit file link opens the in-app route', (
    tester,
  ) async {
    const sid = 'explicit-streaming-assistant-file';
    final harness = await _pumpConversation(
      tester,
      sessionId: sid,
      entries: const [],
    );
    serverStore.onEventForTesting(
      OpencodeEvent(
        type: 'session.step.started',
        properties: {'sessionID': sid, 'assistantMessageID': 'a1'},
      ),
    );
    await tester.pump();
    serverStore.onEventForTesting(
      OpencodeEvent(
        type: 'session.text.delta',
        properties: {
          'sessionID': sid,
          'assistantMessageID': 'a1',
          'ordinal': 0,
          'delta': '[Streaming report](reports/streaming.md)\n',
        },
      ),
    );
    await tester.pump();
    final link = find.textContaining('Streaming report', findRichText: true);
    await _settle(tester, () => link.evaluate().isNotEmpty);

    await tester.tap(link);
    await tester.pumpAndSettle();

    expect(harness.launched, isEmpty);
    expect(harness.opened, hasLength(1));
    expect(harness.opened.single.openFiles.single.path, 'reports/streaming.md');
  });

  testWidgets('explicit absolute file link outside the project stays in-app', (
    tester,
  ) async {
    const sid = 'explicit-outside-file';
    final harness = await _pumpConversation(
      tester,
      sessionId: sid,
      entries: [userMsg(id: 'u1', text: '[Outside](/etc/nginx/nginx.conf)')],
    );
    await _settle(tester, () => find.text('Outside').evaluate().isNotEmpty);
    final context = tester.element(find.byType(ConversationScreen));
    ScaffoldMessenger.of(context).clearSnackBars();
    await tester.pump();

    await tester.tap(find.text('Outside'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(harness.launched, isEmpty);
    expect(harness.opened, isEmpty);
    expect(
      find.text(AppLocalizations.of(context)!.fileLinkNotInProject),
      findsOneWidget,
    );
  });
}
