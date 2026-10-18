import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/nav/app_route_observer.dart';
import 'package:open_builder/core/notifications/notification_service.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';

// Notification tap → conversation page routing (design-background-notify
// D23). The warm path dispatches through onSessionNotificationTap with the
// payload sid; this locks the router-level helper it lands on. An in-stack
// session page is revealed (never duplicated): already-visible taps stay put,
// buried pages are uncovered by popping — the reported bug was a second
// conversation page stacked after backgrounding from that very page.
ConnectionProfile _basicProfile(String id) => ConnectionProfile(
      id: id,
      name: 'S-$id',
      address: 'http://oc.example.com',
      username: 'opencode',
      password: 'pw',
      authMethod: AuthMethod.basic,
    );

Future<GoRouter> _pumpApp(WidgetTester tester) async {
  final router = buildRouter(connectionStore);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pump();
  return router;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    resetNotificationTapDebounce();
    appRouteObserver.debugReset();
    serverStore.setActiveConversation(null);
    NotificationService.debugMarkInitialized();
    NotificationService.debugFakeShow = true;
    NotificationService.debugResetSlots();
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  tearDown(() {
    notificationTapClock = DateTime.now;
  });

  testWidgets('notification tap pushes the conversation page', (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget);
  });

  testWidgets('empty payload is ignored; double taps are debounced',
      (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    expect(openSessionFromNotification(router, ''), isFalse);

    var now = DateTime(2026, 1, 1, 12);
    notificationTapClock = () => now;
    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();

    router.pop();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    now = now.add(const Duration(milliseconds: 500));
    expect(openSessionFromNotification(router, 's1'), isFalse,
        reason: 'a re-tap inside the debounce window must not re-push');
    expect(find.byType(ConversationScreen), findsNothing);

    expect(openSessionFromNotification(router, 's2'), isTrue,
        reason: 'tap on another session must not be swallowed');

    now = now.add(const Duration(milliseconds: 400));
    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
  });

  testWidgets('tap for the already-visible session does not stack a second '
      'page', (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    expect(serverStore.activeConversationId, 's1');
    final element = find.byType(ConversationScreen).evaluate().single;

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget,
        reason: 'the session page is already visible; tapping its own '
        'notification must not stack a second copy');
    expect(find.byType(ConversationScreen).evaluate().single, same(element),
        reason: 'the page must stay in place, not be popped and re-pushed');
    expect(serverStore.activeConversationId, 's1');
  });

  testWidgets('tap for the visible session clears its tray slots',
      (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();

    taskCompleteNotify.value = true;
    await NotificationService.notifyRunComplete('s1', null);
    expect(NotificationService.debugHasRunSlot('s1'), isTrue);

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    expect(NotificationService.debugHasRunSlot('s1'), isFalse,
        reason: 'skipping the push skips setActiveConversation, so the '
        'rule-1 clear must run explicitly');
  });

  testWidgets('tap for a buried session reveals it instead of stacking',
      (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    final s1Element = find.byType(ConversationScreen).evaluate().single;

    expect(openSessionFromNotification(router, 's2'), isTrue);
    await tester.pumpAndSettle();
    expect(serverStore.activeConversationId, 's2');

    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
    expect(find.byType(ConversationScreen), findsOneWidget,
        reason: 'the buried s1 page must be revealed, not duplicated');
    expect(
      tester
          .widget<ConversationScreen>(find.byType(ConversationScreen))
          .sessionId,
      's1',
    );
    expect(find.byType(ConversationScreen).evaluate().single, same(s1Element),
        reason: 'the original s1 element must be re-mounted, not replaced by '
        'a fresh push after popping everything');
    expect(serverStore.activeConversationId, 's1');
  });
}
