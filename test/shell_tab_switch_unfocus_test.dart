import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:open_builder/app_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/features/shell/main_shell.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// TS-1/TS-2: tab branches are keep-alive pages in a PageView, so a focused
// text field (the projects-tab app-bar search) keeps its open
// TextInputConnection when the user switches tabs — the IME stayed up over
// the destination tab with no visible field. MainShell._goBranch (bottom-nav
// taps) and SwipeableShellContainer._onPageChanged (swipes) must both
// unfocus, i.e. the primary focus must leave the field's node. (After
// unfocus, primaryFocus is the enclosing scope — NOT null — so the assertion
// compares node identity instead of null-ness.)
// TS-3: re-tapping the current tab re-goes with initialLocation — must keep
// the shell intact.

const _profile = ConnectionProfile(
  id: 't',
  name: 'test',
  address: 'http://127.0.0.1:9',
  username: 'opencode',
  password: '',
);

AppLocalizations _loc() => lookupAppLocalizations(const Locale('en'));

// Bottom-nav destination labels also appear in tab titles — scope taps to
// the NavigationBar so "Settings" resolves to the nav destination only.
Finder _navDest(String label) => find.descendant(
    of: find.byType(NavigationBar), matching: find.text(label));

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

// Bounded pumps, not pumpAndSettle: landing on a tab kicks the session-load
// retry timers (see design-load-retry.md), which never settle in the fake
// zone (the oauth flow test does the same).
Future<void> _settleFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _focusProjectsSearch(
    WidgetTester tester, GoRouter router) async {
  router.go('/projects');
  await _settleFrames(tester);
  await tester.tap(find.byIcon(Icons.search));
  await _settleFrames(tester);
  expect(FocusManager.instance.primaryFocus, isNotNull,
      reason: 'search field should hold focus after expanding');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
    await connectionStore.add(_profile);
  });

  tearDown(() async {
    for (final s in connectionStore.servers.toList()) {
      await connectionStore.remove(s.id);
    }
  });

  testWidgets('bottom-nav tab switch unfocuses the search field (TS-1)',
      (tester) async {
    final router = await _pumpApp(tester);
    await _focusProjectsSearch(tester, router);
    final fieldNode = FocusManager.instance.primaryFocus!;

    await tester.tap(_navDest(_loc().tabSessions));
    await _settleFrames(tester);
    expect(FocusManager.instance.primaryFocus, isNot(same(fieldNode)),
        reason: 'IME must close when switching tabs via bottom nav');
  });

  testWidgets('swipe-initiated branch change unfocuses the search field (TS-2)',
      (tester) async {
    final router = await _pumpApp(tester);
    await _focusProjectsSearch(tester, router);
    final fieldNode = FocusManager.instance.primaryFocus!;

    // Fling the PageView toward the Sessions tab (index 0, to the left of
    // projects at index 1) — velocity ensures the page actually changes.
    await tester.fling(
        find.byType(PageView), const Offset(400, 0), 800);
    await _settleFrames(tester);
    expect(FocusManager.instance.primaryFocus, isNot(same(fieldNode)),
        reason: 'IME must close when swiping to another tab');
  });

  testWidgets('re-tapping the current tab keeps the shell intact (TS-3)',
      (tester) async {
    final router = await _pumpApp(tester);
    router.go('/settings');
    await _settleFrames(tester);
    expect(find.byType(MainShell), findsOneWidget);

    await tester.tap(_navDest(_loc().tabSettings));
    await _settleFrames(tester);
    expect(find.byType(MainShell), findsOneWidget,
        reason: 'initialLocation re-tap must not pop the shell');
  });
}