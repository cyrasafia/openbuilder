import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/files/code_view.dart';
import 'package:open_builder/features/files/file_browsing_container.dart';
import 'package:open_builder/features/files/file_list_screen.dart';
import 'package:open_builder/features/files/file_view_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';

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
      theme: AppTheme.dark,
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

  testWidgets('peek-collapsed state restores as full mode via file icon (no '
      'self-perpetuating peek)', (tester) async {
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
  });

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
    expect(preserved.openFiles.map((e) => e.path).toList(), ['a/b/old.txt']);
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

  testWidgets('openFile with an already-open path re-pushes animated route', (
    tester,
  ) async {
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

    expect(find.byType(FileViewScreen, skipOffstage: false), findsNWidgets(2));
    final view = tester.widget<FileViewScreen>(find.byType(FileViewScreen));
    expect(view.path, 'a/b/c.txt');

    await tester.pageBack();
    await _flush(tester);
    expect(
      tester.widget<FileViewScreen>(find.byType(FileViewScreen)).path,
      'a/b/d.txt',
    );
  });

  testWidgets('peek restore gates content mount on root route animation', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-1';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.txt',
      StreamedFile(type: 'text', text: 'line1\nline2\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.txt',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: false,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Mid root-transition: content stays gated behind the loading UI even
    // though the inner route (initial, un-animated) reports completed.
    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);

    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('markdown preview stays on loading until HTML is ready', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-2';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.md',
      StreamedFile(type: 'text', text: '# title\n\nbody\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.md',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: false,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    // Root transition completed but the off-isolate HTML build gates the
    // preview mount: the loading UI must still be up. (No further pump, so
    // the WebView widget itself is never mounted in the test environment.)
    expect(find.byType(FileViewScreen), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('imperative openFile gates content on inner route animation', (
    tester,
  ) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-4';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.txt',
      StreamedFile(type: 'text', text: 'line1\nline2\n'),
    );
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/d.txt',
      StreamedFile(type: 'text', text: 'other\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.txt',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: false,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await _flush(tester);
    expect(find.byType(CodeView), findsOneWidget);

    final container = serverStore.fileBrowsing
        .containerFor<FileBrowsingContainerState>(sid, '')!;
    container.openFile('a/b/d.txt', initialLine: 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('other'), findsNothing);

    await _flush(tester);
    expect(find.text('other'), findsOneWidget);
  });

  testWidgets('markdown source mode skips the HTML gate', (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-3';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.md',
      StreamedFile(type: 'text', text: '# title\n\nbody\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.md',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: true,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('source-opened markdown toggling to preview builds HTML',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-5';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.md',
      StreamedFile(type: 'text', text: '# title\n\nbody\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.md',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: true,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await _flush(tester);
    expect(find.byType(CodeView), findsOneWidget);

    // Open the menu programmatically and let its own transition settle —
    // while the menu route is still animating, taps are swallowed by the
    // modal barrier.
    final popup =
        find.byWidgetPredicate((w) => w is PopupMenuButton<dynamic>);
    tester.state<PopupMenuButtonState<dynamic>>(popup).showButtonMenu();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final itemInkWell = find.descendant(
      of: find.byWidgetPredicate((w) => w is PopupMenuItem<dynamic>),
      matching: find.byType(InkWell),
    );
    await tester.tapAt(tester.getCenter(itemInkWell.first));
    await tester.pump();

    // Toggled to preview: the gate holds the loading UI up while the
    // off-isolate HTML build is pending.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);

    // compute() runs on a real isolate, which FakeAsync never drains — let
    // the result land via runAsync. The gate then opens and MarkdownWebView
    // mounts; in the test environment that build fails an assert (no
    // WebViewPlatform registered), so an AssertionError here is the proof
    // the gate opened — without the menu-action kick nothing would ever
    // build the HTML and the spinner would stay, producing no exception.
    // The render overlay keeps its spinner up until onPageFinished, which
    // never fires in tests.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(tester.takeException(), isA<AssertionError>());
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('code file mount waits for off-isolate highlight',
      (tester) async {
    final router = await _pumpApp(tester);
    const sid = 'defer-gate-6';
    serverStore.fileBrowsing.cacheContent(
      sid,
      '',
      'a/b/c.dart',
      StreamedFile(type: 'text', text: 'void main() {}\n'),
    );
    router.push(
      '/session/$sid/files?directory=',
      extra: FileBrowsingSnapshot(
        openFiles: const [
          OpenFileEntry(
            path: 'a/b/c.dart',
            scrollOffset: 0,
            wrap: false,
            mdShowSource: false,
            hadContent: true,
          ),
        ],
        peek: true,
      ),
    );
    await _flush(tester);

    // Transitions done and content cached, but the highlight pre-build runs
    // on a real isolate (never completes under FakeAsync) — the gate holds
    // the loading UI.
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(CodeView), findsNothing);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));

    expect(find.byType(CodeView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
