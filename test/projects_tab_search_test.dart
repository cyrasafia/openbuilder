import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:open_builder/app_state.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/shell/projects_tab.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

// PS-1..PS-5: the projects tab search bar. Collapsed by default (search icon
// only), tap expands the app-bar TextField, typing filters entries by display
// name OR path (worktree / global directory), and the no-match empty state
// distinguishes a filtered-out list from a genuinely empty server.

final _en = lookupAppLocalizations(const Locale('en'));

Widget _wrap() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const ProjectsTab(),
    );

void _seed() {
  serverStore.setProjectsForTesting(const [
    ProjectModel(id: 'alpha', worktree: '/home/dev/alpha', name: 'Alpha'),
    ProjectModel(id: 'beta', worktree: '/work/other/beta', name: 'Rocket'),
  ]);
  serverStore.connected = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    serverStore.setProjectsForTesting(const []);
    serverStore.clearSessionsForTesting();
    serverStore.connected = false;
  });

  testWidgets('search icon shown collapsed; tap expands the field (PS-1)',
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

  testWidgets('typing filters by name and by path (PS-2)', (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    // Both entries visible before typing.
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Rocket'), findsOneWidget);

    // Match by display name.
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Rocket'), findsNothing);

    // Match by path (worktree dir segment, not the display name).
    await tester.enterText(find.byType(TextField), 'other');
    await tester.pump();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Rocket'), findsOneWidget);

    // Case-insensitive.
    await tester.enterText(find.byType(TextField), 'ROCKET');
    await tester.pump();
    expect(find.text('Rocket'), findsOneWidget);
  });

  testWidgets('no-match shows dedicated empty text (PS-3)', (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text(_en.projectNoMatch), findsOneWidget);
    expect(find.text(_en.noProjects), findsNothing);
  });

  testWidgets('clear button resets the filter (PS-4)', (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    expect(find.text('Rocket'), findsNothing);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Alpha'), findsOneWidget);
    expect(find.text('Rocket'), findsOneWidget);
  });

  testWidgets('global project entries match per-directory (PS-5)',
      (tester) async {
    serverStore.setProjectsForTesting(
        const [ProjectModel(id: 'global', worktree: '/')]);
    serverStore.upsertSessionForTesting(SessionModel(
      id: 'g1',
      projectID: 'global',
      directory: '/mnt/proj/one',
      title: 'one',
      created: 0,
      updated: 1000,
    ));
    serverStore.upsertSessionForTesting(SessionModel(
      id: 'g2',
      projectID: 'global',
      directory: '/mnt/proj/two',
      title: 'two',
      created: 0,
      updated: 2000,
    ));
    serverStore.connected = true;
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'one');
    await tester.pump();
    // Global expands one entry per directory: name = last path segment.
    // Scoping to ListTile avoids matching the search field's own content.
    Finder tileText(String s) =>
        find.descendant(of: find.byType(ListTile), matching: find.text(s));
    expect(tileText('one'), findsOneWidget);
    expect(tileText('two'), findsNothing);
  });

  testWidgets('X collapses the search bar once the field is empty (PS-6)',
      (tester) async {
    _seed();
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    // With typed text, X clears the query but keeps the field expanded.
    await tester.enterText(find.byType(TextField), 'alpha');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text('Rocket'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    // With an empty field, X collapses back to the title + search icon.
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.text(_en.tabProjects), findsOneWidget);
  });

  testWidgets('empty server keeps the noProjects wording under query (PS-7)',
      (tester) async {
    // No projects on the server at all — a typed query must not flip the
    // wording to "no matching projects".
    serverStore.setProjectsForTesting(const []);
    serverStore.connected = true;
    await tester.pumpWidget(_wrap());
    await tester.pump();
    await tester.tap(find.byIcon(Icons.search));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();
    expect(find.text(_en.noProjects), findsOneWidget);
    expect(find.text(_en.projectNoMatch), findsNothing);
  });
}