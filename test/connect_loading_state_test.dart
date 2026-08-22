import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/features/shell/projects_tab.dart';
import 'package:open_builder/features/shell/sessions_tab.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/widgets.dart';

// Discard port: connection refused instantly, so connect() fails fast and
// deterministically (no server needed) while still exercising the real
// bootstrap path.
const _unreachable = ConnectionProfile(
  id: 't',
  name: 'test',
  address: 'http://127.0.0.1:9',
  username: 'opencode',
  password: '',
);

final _en = lookupAppLocalizations(const Locale('en'));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect sets connecting and clears a stale bootstrapFailed', () async {
    final store = ServerStore();
    store.bootstrapFailed = true;
    final fut = store.connect(_unreachable);
    expect(store.connecting, isTrue);
    expect(store.bootstrapFailed, isFalse,
        reason: 'a retry in flight must not show the previous failure');
    await fut;
    expect(store.connecting, isFalse);
    expect(store.bootstrapFailed, isTrue);
    expect(store.connected, isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('overlapping connects settle with connecting cleared', () async {
    final store = ServerStore();
    final first = store.connect(_unreachable);
    final second = store.connect(_unreachable);
    expect(store.connecting, isTrue);
    await Future.wait([first, second]);
    expect(store.connecting, isFalse);
    expect(store.bootstrapFailed, isTrue);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test('a superseded connect does not clear the connecting flag', () async {
    final store = ServerStore();
    final fut = store.connect(_unreachable);
    expect(store.connecting, isTrue);
    store.setConnectingForTesting(true);
    await fut;
    expect(store.connecting, isTrue,
        reason: 'only the most recent generation may clear the flag');
    store.setConnectingForTesting(false);
    expect(store.connecting, isFalse);
  }, timeout: const Timeout(Duration(seconds: 20)));

  testWidgets('tabs show loading, not stale error/empty, while connecting',
      (tester) async {
    serverStore.bootstrapFailed = true;
    serverStore.setConnectingForTesting(true);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SessionsTab(),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(ErrorView), findsNothing);
    expect(find.text(_en.noSessions), findsNothing);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ProjectsTab(),
    ));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(ErrorView), findsNothing);
    expect(find.text(_en.noProjects), findsNothing);

    serverStore.setConnectingForTesting(false);
    serverStore.bootstrapFailed = false;
    await tester.pumpWidget(const SizedBox());
  });
}
