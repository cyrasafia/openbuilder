import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/servers/basic_auth_screen.dart';
import 'package:open_builder/features/servers/server_info_screen.dart';
import 'package:open_builder/features/servers/servers_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// Regression lock for the consecutive-basic-save stranding bug.
//
// `currentConfiguration.uri` does not reflect imperative (pushed) matches, so
// the old "pop until path == /servers" loop (a) never stopped on a PUSHED
// /servers — it popped everything and cold-`go`'d, resetting the declarative
// base to /servers; then (b) on the NEXT save from that state the loop's very
// first check succeeded and popped NOTHING, leaving the password page on top.
// Reproduced live (profile build, emulator): round 1 OK, round 2 stranded.
// The fix pops all imperative routes unconditionally, then only falls back
// to `go` when the declarative base is not /servers.
//
// This test drives the exact navigation sequence a real save performs
// (popToServerManagement), without network: two consecutive rounds must both
// end with the server-management list on top.
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
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
    ),
  );
  await tester.pump();
  return router;
}

void _expectServerManagement(GoRouter router, WidgetTester tester, int round) {
  expect(
    router.routerDelegate.currentConfiguration.uri.path,
    '/servers',
    reason: 'round $round: wrong landing location',
  );
  expect(find.byType(ServersScreen), findsOneWidget,
      reason: 'round $round: server list not on top');
  expect(find.byType(BasicAuthScreen), findsNothing,
      reason: 'round $round: password page still on top (bug)');
  expect(find.byType(ServerInfoScreen), findsNothing,
      reason: 'round $round: edit screen still on top');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  testWidgets('consecutive saves from the settings-tab push chain',
      (tester) async {
    await connectionStore.add(_basicProfile('p1'));
    final router = await _pumpApp(tester);

    // Entry chain from server management (settings tab → push /servers).
    router.go('/settings');
    await tester.pumpAndSettle();

    // Round 1: push /servers → edit → login → save navigates.
    router.push('/servers');
    await tester.pumpAndSettle();
    router.push('/servers/p1/edit');
    await tester.pumpAndSettle();
    router.push(
      '/servers/p1/login',
      extra: ServerLoginArgs(
        profile: connectionStore.byId('p1')!,
        metadata: null,
        newlyAdded: false,
      ),
    );
    await tester.pumpAndSettle();
    popToServerManagement(router);
    await tester.pumpAndSettle();
    _expectServerManagement(router, tester, 1);

    // Round 2: from wherever round 1 landed, open edit → login → save again.
    router.push('/servers/p1/edit');
    await tester.pumpAndSettle();
    router.push(
      '/servers/p1/login',
      extra: ServerLoginArgs(
        profile: connectionStore.byId('p1')!,
        metadata: null,
        newlyAdded: false,
      ),
    );
    await tester.pumpAndSettle();
    popToServerManagement(router);
    await tester.pumpAndSettle();
    _expectServerManagement(router, tester, 2);
  });
}
