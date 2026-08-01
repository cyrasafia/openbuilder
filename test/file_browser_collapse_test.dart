import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/features/files/file_list_screen.dart';
import 'package:open_builder/features/files/file_view_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

GoRouter _buildTestRouter() {
  return GoRouter(
    initialLocation: '/',
    observers: [fileRouteObserver],
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const Scaffold(body: Text('home')),
      ),
      GoRoute(
        path: '/session/:id/files',
        builder: (_, s) => FileListScreen(
          sessionId: s.pathParameters['id']!,
          directory: s.uri.queryParameters['directory'],
          initialPath: s.uri.queryParameters['path'],
          restore: s.extra is FileListRestore ? s.extra as FileListRestore : null,
        ),
      ),
      GoRoute(
        path: '/session/:id/file',
        builder: (_, s) => FileViewScreen(
          sessionId: s.pathParameters['id']!,
          path: s.uri.queryParameters['path'] ?? '',
          directory: s.uri.queryParameters['directory'],
          restore: s.extra is OpenFileEntry ? s.extra as OpenFileEntry : null,
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

void main() {
  testWidgets('collapse from file view pops whole chain and seals snapshot',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s1';
    router.push('/session/$sid/files?directory=&path=a/b');
    await _flush(tester);
    router.push('/session/$sid/file?path=a/b/c.txt&directory=');
    await _flush(tester);
    expect(find.byType(FileViewScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    expect(find.byType(FileListScreen), findsNothing);
    final snap = serverStore.fileBrowsing.snapshotFor(sid, '');
    expect(snap, isNotNull);
    expect(snap!.listPath, 'a/b');
    expect(snap.openFiles.map((e) => e.path).toList(), ['a/b/c.txt']);
  });

  testWidgets(
      'collapse tapped on FileListScreen in subdirectory bypasses PopScope '
      'and keeps the sealed snapshot', (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s2';
    router.push('/session/$sid/files?directory=&path=a/b');
    await _flush(tester);
    expect(find.byType(FileListScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    final snap = serverStore.fileBrowsing.snapshotFor(sid, '');
    expect(snap, isNotNull);
    expect(snap!.listPath, 'a/b');
    expect(snap.openFiles, isEmpty);
  });

  testWidgets('system back at root list clears the sealed snapshot',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s3';
    final store = serverStore.fileBrowsing;
    store.beginCollapse(sid, '');
    store.collectList(sid, '',
        path: 'x', scrollOffset: 0, searchQuery: '', searchExpanded: false);
    expect(store.snapshotFor(sid, ''), isNotNull);

    router.push('/session/$sid/files?directory=');
    await _flush(tester);
    await tester.pageBack();
    await _flush(tester);

    expect(find.text('home'), findsOneWidget);
    expect(store.snapshotFor(sid, ''), isNull);
  });

  testWidgets('collapse button hidden when chain has no list anchor',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s5';
    router.push('/session/$sid/file?path=a/b/c.txt&directory=');
    await _flush(tester);

    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
  });

  testWidgets('restore re-pushes list and open files from snapshot',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'collapse-s4';
    final store = serverStore.fileBrowsing;
    final snap = store.snapshotFor(sid, '');
    expect(snap, isNull);
    store.beginCollapse(sid, '');
    store.collectFile(
      sid,
      '',
      const OpenFileEntry(
        path: 'a/b/c.txt',
        scrollOffset: 10,
        wrap: true,
        mdShowSource: false,
        hadContent: true,
      ),
    );
    store.collectList(sid, '',
        path: 'a/b', scrollOffset: 5, searchQuery: '', searchExpanded: false);

    final sealed = store.snapshotFor(sid, '')!;
    router.push(
      '/session/$sid/files?directory=&path=${Uri.encodeQueryComponent(sealed.listPath)}',
      extra: FileListRestore(
        scrollOffset: sealed.listScrollOffset,
        searchQuery: sealed.searchQuery,
        searchExpanded: sealed.searchExpanded,
      ),
    );
    for (final e in sealed.openFiles) {
      router.push(
        '/session/$sid/file?path=${Uri.encodeQueryComponent(e.path)}&directory=',
        extra: e,
      );
    }
    await _flush(tester);

    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(FileListScreen, skipOffstage: false), findsOneWidget);
  });
}
