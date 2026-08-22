import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/servers/server_info_screen.dart';
import 'package:open_builder/features/servers/servers_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

ConnectionProfile _profile(String id) => ConnectionProfile(
      id: id,
      name: 'S-$id',
      address: 'https://oc.example.com',
      authMethod: AuthMethod.none,
    );

// Regression: adding a no-auth server from server management used to
// context.go('/sessions') unconditionally, yanking the user out of the
// management list. Non-first adds must return to /servers (OL-35 pattern);
// only the welcome-flow first server enters /sessions.
//
// The probe hits the stubbed HttpClient (400s → outcome unknown), so the flow
// goes through "choose manually" → none, which exercises the same
// _proceed(AuthMethod.none) branch.
Future<void> _runFlow(WidgetTester tester, {required bool firstServer}) async {
  final router = buildRouter(connectionStore);
  await tester.pumpWidget(
    MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pump();
  if (firstServer) {
    router.go('/servers/new');
    await tester.pumpAndSettle();
  } else {
    router.push('/servers');
    await tester.pumpAndSettle();
    router.push('/servers/new');
    await tester.pumpAndSettle();
  }

  await tester.enterText(
    find.byType(TextFormField).first,
    'No-Auth',
  );
  await tester.tap(find.byIcon(Icons.travel_explore));
  await tester.pumpAndSettle();

  final loc =
      AppLocalizations.of(tester.element(find.byType(ServerInfoScreen)))!;
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pumpAndSettle();
  await tester.tap(find.text(loc.probeMethodNone));
  // Bounded pumps, not pumpAndSettle: landing on /sessions kicks the
  // session-load retry timers (see design-load-retry.md), which never settle
  // in the fake zone (the oauth flow test does the same).
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));

  final path = router.routerDelegate.currentConfiguration.uri.path;
  expect(path, firstServer ? '/sessions' : '/servers',
      reason: 'wrong landing location: $path');
  if (!firstServer) {
    expect(find.byType(ServersScreen), findsOneWidget);
  }
  final added = connectionStore.servers.last;
  expect(added.authMethod, AuthMethod.none);
  expect(connectionStore.activeId, added.id);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  testWidgets('first no-auth server enters /sessions', (tester) async {
    await _runFlow(tester, firstServer: true);
  });

  testWidgets('non-first no-auth server returns to /servers, set active',
      (tester) async {
    await connectionStore.add(_profile('p0'));
    await connectionStore.setActive('p0');
    await _runFlow(tester, firstServer: false);
  });
}
