import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Regression lock: the pre-assembly driver actually expands the viewport's
/// cacheExtent when the run top is unmounted (a height gap exists).
///
/// `_drivePreAssembly` calls `setState(() => _cacheExtent = next)` on
/// `_ConversationScreenState`. The `CustomScrollView` consuming `_cacheExtent`
/// (`scrollCacheExtent: ScrollCacheExtent.pixels(_cacheExtent)`) lives inside
/// `body: ListenableBuilder(...)`. A parent `setState` DOES rebuild a child
/// `ListenableBuilder`: `ListenableBuilder` is an `AnimatedWidget`
/// (`StatefulWidget`), and `StatefulElement.update` overrides the generic
/// `Element.update` to call `rebuild(force: true)` (framework.dart:6007), so
/// the new `_cacheExtent` propagates to `RenderViewport`.
///
/// This test builds one long multi-message assistant run pinned at the bottom
/// with the run top outside the initial 250px cache window (a gap), then
/// asserts cacheExtent grows past 250 during pre-assembly (max seen across
/// frames, not just the final post-reset value — the driver resets cacheExtent
/// to base after the gap closes, so a final-only read would misleadingly show
/// 250).

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

double? _readCacheExtent(WidgetTester tester) {
  final vp = find.byType(Viewport);
  if (vp.evaluate().isEmpty) return null;
  final ro = tester.renderObject<RenderAbstractViewport>(vp.first);
  if (ro is RenderViewport) {
    // ignore: deprecated_member_use
    return ro.cacheExtent;
  }
  return null;
}

void main() {
  testWidgets(
    'driver expands cacheExtent when run top is unmounted (gap present)',
    (tester) async {
      const sid = 'driver-gap';
      // 1 user (own run) + 25 consecutive assistant messages = one long run.
      // Each assistant reply is tall enough that, pinned at the bottom, the
      // run top (a0) sits well outside the initial 250px cache window → gap.
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
        for (var i = 0; i < 25; i++)
          MessageEntry(
            info: MessageInfo(
              id: 'a$i',
              role: 'assistant',
              sessionID: sid,
              created: 2000 + i,
              finish: 'stop',
            ),
            parts: [
              MessagePart({
                'type': 'text',
                'id': 'pa$i',
                'text': 'assistant reply number $i\n' * 6,
              }),
            ],
          ),
      ];
      await _pumpConversation(tester, sessionId: sid, entries: entries);

      // Track cacheExtent across all frames (not just final): the driver
      // resets cacheExtent to base after the gap closes, so a final-only read
      // would misleadingly show 250 even though it expanded mid-sequence.
      var maxCe = 0.0;
      for (var i = 0; i < 50; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        final v = _readCacheExtent(tester) ?? 0;
        if (v > maxCe) maxCe = v;
      }

      expect(
        maxCe,
        greaterThan(250.0),
        reason: 'driver must expand cacheExtent past the 250px base to measure '
            'the off-screen run top and close the gap. If max stays 250, the '
            'driver is not propagating cacheExtent to the viewport.',
      );
    },
  );
}
