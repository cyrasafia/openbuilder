import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/features/files/file_browsing_container.dart';
import 'package:open_builder/features/files/file_list_screen.dart';
import 'package:open_builder/features/files/file_view_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

GoRouter _buildTestRouter() {
  return GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/session/:id/files',
        builder: (_, s) => FileBrowsingContainer(
          sessionId: s.pathParameters['id']!,
          directory: s.uri.queryParameters['directory'],
          initial: s.extra is FileBrowsingSnapshot
              ? s.extra as FileBrowsingSnapshot
              : null,
        ),
      ),
    ],
  );
}

Future<GoRouter> _pumpApp(WidgetTester tester) async {
  final router = _buildTestRouter();
  await tester.pumpWidget(
    MaterialApp.router(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await _flush(tester);
  return router;
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

FileBrowsingSnapshot _seal(
  String sid, {
  String listPath = 'a/b',
  List<OpenFileEntry> openFiles = const [],
}) {
  final store = serverStore.fileBrowsing;
  store.beginCollapse(sid, '');
  for (final e in openFiles.reversed) {
    store.collectFile(sid, '', e);
  }
  store.collectList(
    sid,
    '',
    path: listPath,
    scrollOffset: 0,
    searchQuery: '',
    searchExpanded: false,
  );
  return store.snapshotFor(sid, '')!;
}

void main() {
  testWidgets(
    'collapse from file view pops whole container and seals snapshot',
    (tester) async {
      final router = await _pumpApp(tester);
      const sid = 'collapse-s1';
      final snap = _seal(
        sid,
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.txt',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: false,
          ),
        ],
      );
      router.push('/session/$sid/files?directory=', extra: snap);
      await _flush(tester);
      expect(find.byType(FileViewScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.unfold_less));
      await _flush(tester);

      expect(find.text('home'), findsOneWidget);
      expect(find.byType(FileListScreen), findsNothing);
      final sealed = serverStore.fileBrowsing.snapshotFor(sid, '');
      expect(sealed, isNotNull);
      expect(sealed!.listPath, 'a/b');
      expect(sealed.openFiles.map((e) => e.path).toList(), ['a/b/c.txt']);
    },
  );

  testWidgets(
    'collapse tapped on FileListScreen in subdirectory pops container '
    'and keeps the sealed snapshot',
    (tester) async {
      final router = await _pumpApp(tester);
      const sid = 'collapse-s2';
      final snap = _seal(sid);
      router.push('/session/$sid/files?directory=', extra: snap);
      await _flush(tester);
      expect(find.byType(FileListScreen), findsOneWidget);

      await tester.tap(find.byIcon(Icons.unfold_less));
      await _flush(tester);

      expect(find.text('home'), findsOneWidget);
      final sealed = serverStore.fileBrowsing.snapshotFor(sid, '');
      expect(sealed, isNotNull);
      expect(sealed!.listPath, 'a/b');
      expect(sealed.openFiles, isEmpty);
    },
  );

  testWidgets('system back at root list clears the sealed snapshot', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s3';
    final snap = _seal(sid, listPath: '');
    expect(serverStore.fileBrowsing.snapshotFor(sid, ''), isNotNull);

    router.push('/session/$sid/files?directory=', extra: snap);
    await _flush(tester);
    await tester.tap(find.byIcon(Icons.arrow_back));
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    expect(serverStore.fileBrowsing.snapshotFor(sid, ''), isNull);
  });

  testWidgets('peek collapse seals the file state into the snapshot', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'peek-collapse';
    final snap = FileBrowsingSnapshot(
      openFiles: const [
        OpenFileEntry(
          path: 'a/b/c.txt',
          scrollOffset: 0,
          wrap: false,
          mdShowSource: true,
        ),
      ],
      peek: true,
    );

    router.push('/session/$sid/files?directory=', extra: snap);
    await _flush(tester);

    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(FileListScreen, skipOffstage: false), findsNothing);

    await tester.tap(find.byIcon(Icons.unfold_less));
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    final sealed = serverStore.fileBrowsing.snapshotFor(sid, '');
    expect(sealed, isNotNull);
    expect(sealed!.peek, isFalse);
    expect(sealed.openFiles.map((e) => e.path).toList(), ['a/b/c.txt']);
  });

  testWidgets(
    'peek-collapsed state restores as full mode via file icon (no '
    'self-perpetuating peek)',
    (tester) async {
      final router = await _pumpApp(tester);
      const sid = 'peek-restore';
      router.push(
        '/session/$sid/files?directory=',
        extra: FileBrowsingSnapshot(
          openFiles: const [
            OpenFileEntry(
              path: 'a/b/c.txt',
              scrollOffset: 0,
              wrap: false,
              mdShowSource: true,
            ),
          ],
          peek: true,
        ),
      );
      await _flush(tester);
      expect(find.byType(FileListScreen, skipOffstage: false), findsNothing);

      await tester.tap(find.byIcon(Icons.unfold_less));
      await _flush(tester);
      final sealed = serverStore.fileBrowsing.snapshotFor(sid, '')!;

      router.push('/session/$sid/files?directory=', extra: sealed);
      await _flush(tester);

      expect(find.byType(FileViewScreen), findsOneWidget);
      expect(find.byType(FileListScreen, skipOffstage: false), findsOneWidget);
    },
  );

  testWidgets('back from a peek preserves a previously saved session', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'peek-back';
    final saved = _seal(
      sid,
      listPath: 'a/b',
      openFiles: const [
        OpenFileEntry(
          path: 'a/b/old.txt',
          scrollOffset: 0,
          wrap: false,
          mdShowSource: false,
        ),
      ],
    );
    expect(saved.listPath, 'a/b');

    final peekSnap = FileBrowsingSnapshot(
      openFiles: const [
        OpenFileEntry(
          path: 'x/y/new.txt',
          scrollOffset: 0,
          wrap: false,
          mdShowSource: true,
        ),
      ],
      peek: true,
    );
    router.push('/session/$sid/files?directory=', extra: peekSnap);
    await _flush(tester);
    expect(find.byType(FileViewScreen), findsOneWidget);

    await tester.pageBack();
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    final preserved = serverStore.fileBrowsing.snapshotFor(sid, '');
    expect(preserved, isNotNull);
    expect(preserved!.listPath, 'a/b');
    expect(
      preserved.openFiles.map((e) => e.path).toList(),
      ['a/b/old.txt'],
    );
  });

  testWidgets('restore builds list and open files from snapshot', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s4';
    final store = serverStore.fileBrowsing;
    expect(store.snapshotFor(sid, ''), isNull);
    final snap = _seal(
      sid,
      openFiles: const [
        OpenFileEntry(
          path: 'a/b/c.txt',
          scrollOffset: 10,
          wrap: true,
          mdShowSource: false,
          hadContent: true,
        ),
      ],
    );

    router.push('/session/$sid/files?directory=', extra: snap);
    await _flush(tester);

    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(FileListScreen, skipOffstage: false), findsOneWidget);
  });

  testWidgets('openFile from list pushes detail with horizontal route', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s5';
    router.push('/session/$sid/files?directory=');
    await _flush(tester);
    expect(find.byType(FileListScreen), findsOneWidget);

    final container = serverStore.fileBrowsing
        .containerFor<FileBrowsingContainerState>(sid, '');
    expect(container, isNotNull);
    container!.openFile('a/b/c.txt');
    await _flush(tester);

    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(FileListScreen, skipOffstage: false), findsOneWidget);

    await tester.pageBack();
    await _flush(tester);
    expect(find.byType(FileViewScreen), findsNothing);
    expect(find.byType(FileListScreen), findsOneWidget);
  });

  testWidgets('openFile with an already-open path pops back to it',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s6';
    router.push('/session/$sid/files?directory=');
    await _flush(tester);

    final container = serverStore.fileBrowsing
        .containerFor<FileBrowsingContainerState>(sid, '')!;
    container.openFile('a/b/c.txt');
    await _flush(tester);
    container.openFile('a/b/d.txt');
    await _flush(tester);
    expect(find.byType(FileViewScreen, skipOffstage: false), findsNWidgets(2));

    container.openFile('a/b/c.txt');
    await _flush(tester);

    expect(find.byType(FileViewScreen, skipOffstage: false), findsOneWidget);
    final view = tester.widget<FileViewScreen>(find.byType(FileViewScreen));
    expect(view.path, 'a/b/c.txt');
  });
}
