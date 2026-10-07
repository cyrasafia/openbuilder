import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/servers/basic_auth_screen.dart';
import 'package:open_builder/features/servers/server_info_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// Manual selection after an inconclusive probe. The dialog must offer basic
// and oauth ONLY — v2 servers always enforce auth, the "no auth" shortcut no
// longer exists (design/v2/design-auth-adaptation.md). Choosing basic saves
// the profile and lands on the password-only credential screen.
//
// The probe hits flutter_test's stubbed HttpClient (400s → outcome unknown),
// so the flow always goes through "choose manually".
Future<void> _runFlow(WidgetTester tester) async {
  final router = buildRouter(connectionStore);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pump();
  router.go('/servers/new');
  await tester.pumpAndSettle();

  await tester.enterText(
    find.byType(TextFormField).first,
    'Manual',
  );
  await tester.tap(find.byIcon(Icons.travel_explore));
  await tester.pumpAndSettle();

  final loc =
      AppLocalizations.of(tester.element(find.byType(ServerInfoScreen)))!;
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pumpAndSettle();
  expect(find.byType(SimpleDialogOption), findsNWidgets(2),
      reason: 'basic + oauth only; the no-auth option must stay removed');
  await tester.tap(find.text(loc.probeMethodBasic));
  await tester.pumpAndSettle();

  expect(find.byType(BasicAuthScreen), findsOneWidget);
  final added = connectionStore.servers.last;
  expect(added.authMethod, AuthMethod.basic);
  expect(added.username, 'opencode');
  expect(added.password, isEmpty);
  expect(added.needsLogin, isTrue);
  // Password-only credential screen: exactly one text field, no username.
  expect(find.byType(TextFormField), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  testWidgets('unknown probe → manual basic → password-only credential screen',
      _runFlow);
}
