import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/app_state.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/shell/sessions_tab.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// SS-1..SS-7: the sessions tab search bar. Collapsed by default (search icon
// only), tap expands the app-bar TextField, typing filters entries by session
// title OR project name/path OR directory, and the no-match empty state
// distinguishes a filtered-out list from a genuinely empty server.

final _en = lookupAppLocalizations(const Locale('en'));

Widget _wrap() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const SessionsTab(),
    );

void _seed() {
  serverStore.setProjectsForTesting(const [
    ProjectModel(id: 'alpha', worktree: '/home/dev/alpha', name: 'Alpha'),
    ProjectModel(id: 'beta', worktree: '/work/other/beta', name: 'Rocket'),
  ]);
  serverStore.upsertSessionForTesting(const SessionModel(
    id: 's1',
    projectID: 'alpha',
    directory: '/home/dev/alpha',
    title: 'Fix login bug',
    created: 0,
    updated: 1000,
  ));
  serverStore.upsertSessionForTesting(const SessionModel(
    id: 's2',
    projectID: 'beta',
    directory: '/work/other/beta',
    title: 'Refactor parser',
    created: 0,
    updated: 2000,
  ));
  serverStore.connected = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    serverStore.setProjectsForTesting(const []);
    serverStore.clearSessionsForTesting();
    serverStore.connected = false;
  });

  testWidgets('search icon shown collapsed; tap expands the field (SS-1)',
      (tester) async {
    await tester.pumpWidget(_wrap());
    await tester.pump();
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.search), findsNothing);
  });

  testWidgets('typing filters by title and by project name/path (SS-2)',
      (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    // Both sessions visible before typing.
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Refactor parser'), findsOneWidget);

    // Match by session title.
    await tester.enterText(find.byType(TextField), 'login');
    await tester.pump();
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Refactor parser'), findsNothing);

    // Match by project display name (not the session title).
    await tester.enterText(find.byType(TextField), 'rocket');
    await tester.pump();
    expect(find.text('Fix login bug'), findsNothing);
    expect(find.text('Refactor parser'), findsOneWidget);

    // Match by project path (worktree dir segment).
    await tester.enterText(find.byType(TextField), 'other');
    await tester.pump();
    expect(find.text('Fix login bug'), findsNothing);
    expect(find.text('Refactor parser'), findsOneWidget);

    // Case-insensitive.
    await tester.enterText(find.byType(TextField), 'PARSER');
    await tester.pump();
    expect(find.text('Refactor parser'), findsOneWidget);
  });

  testWidgets('global sessions match by directory path (SS-3)',
      (tester) async {
    serverStore.setProjectsForTesting(
        const [ProjectModel(id: 'global', worktree: '/')]);
    serverStore.upsertSessionForTesting(const SessionModel(
      id: 'g1',
      projectID: 'global',
      directory: '/mnt/proj/one',
      title: 'task one',
      created: 0,
      updated: 1000,
    ));
    serverStore.upsertSessionForTesting(const SessionModel(
      id: 'g2',
      projectID: 'global',
      directory: '/mnt/proj/two',
      title: 'task two',
      created: 0,
      updated: 2000,
    ));
    serverStore.connected = true;
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    // Global project: project label is the last directory segment.
    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    expect(find.text('task one'), findsOneWidget);
    expect(find.text('task two'), findsNothing);
  });

  testWidgets('no-match shows dedicated empty text (SS-4)', (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text(_en.sessionNoMatch), findsOneWidget);
    expect(find.text(_en.noSessions), findsNothing);
  });

  testWidgets('clear button resets the filter (SS-5)', (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'login');
    await tester.pump();
    expect(find.text('Refactor parser'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Fix login bug'), findsOneWidget);
    expect(find.text('Refactor parser'), findsOneWidget);
  });

  testWidgets('X collapses the search bar once the field is empty (SS-6)',
      (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    // With typed text, X clears the query but keeps the field expanded.
    await tester.enterText(find.byType(TextField), 'login');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Refactor parser'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // With an empty field, X collapses back to the title + search icon.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.text(_en.tabSessions), findsOneWidget);
  });

  testWidgets('empty server keeps the noSessions wording under query (SS-7)',
      (tester) async {
    // No sessions on the server at all — a typed query must not flip the
    // wording to "no matching sessions".
    serverStore.setProjectsForTesting(const []);
    serverStore.connected = true;
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text(_en.noSessions), findsOneWidget);
    expect(find.text(_en.sessionNoMatch), findsNothing);
  });
}