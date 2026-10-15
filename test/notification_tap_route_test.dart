import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';

// Notification tap → conversation page routing (design-background-notify
// D23). The warm path dispatches through onSessionNotificationTap with the
// payload sid; this locks the router-level helper it lands on.
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

    now = now.add(const Duration(milliseconds: 500));
    expect(openSessionFromNotification(router, 's1'), isFalse,
        reason: 'tap on the same session inside the debounce window must not push');
    expect(openSessionFromNotification(router, 's2'), isTrue,
        reason: 'tap on another session must not be swallowed');

    now = now.add(const Duration(milliseconds: 400));
    expect(openSessionFromNotification(router, 's1'), isTrue);
    await tester.pumpAndSettle();
  });
}
