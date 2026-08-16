import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/files/code_view.dart';
import 'package:open_builder/features/files/diff_detail_screen.dart';
import 'package:open_builder/features/files/file_browsing_container.dart';
import 'package:open_builder/features/files/file_view_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _patch = '''
diff --git a/lib/main.dart b/lib/main.dart
index 1234567..abcdefg 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -10,3 +10,4 @@
 context a
-removed a
+added a1
+added a2
@@ -64,3 +67,4 @@
 context b
-removed b
+added b1
+added b2
''';

final _content =
    List.generate(200, (i) => 'line ${i + 1}').join('\n');

final _longFirstHunkPatch = '''
diff --git a/lib/main.dart b/lib/main.dart
index 1234567..abcdefg 100644
--- a/lib/main.dart
+++ b/lib/main.dart
@@ -10,38 +10,40 @@
${List.generate(36, (i) => ' context $i').join('\n')}
-removed a
+added a1
+added a2
+added a3
@@ -96,3 +100,4 @@
 context b
-removed b
+added b1
+added b2
''';

class _MockClient extends OpencodeClient {
  _MockClient(this._patch) : super(_noopDio());

  final String _patch;

  @override
  Future<List<FileDiff>> diff(
    String sessionId, {
    String? directory,
    String? mode,
    String? messageID,
    int? context,
  }) async =>
      [
        FileDiff(
          file: 'lib/main.dart',
          patch: _patch,
          additions: 4,
          deletions: 2,
          status: 'modified',
        ),
      ];

  @override
  Future<StreamedFile> readFileStream({
    required String directory,
    required String path,
    void Function(int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async =>
      StreamedFile(type: 'text', mimeType: 'text/plain', text: _content);
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

double _lineHeight() {
  final tp = TextPainter(
    text: TextSpan(
      text: '0',
      style: AppTheme.mono.copyWith(fontSize: codeFontSize),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final h = tp.height;
  tp.dispose();
  return h;
}

double _fileViewOffset(WidgetTester tester) {
  final lv = tester.widget<ListView>(
    find.descendant(
      of: find.byType(FileViewScreen),
      matching: find.byType(ListView),
    ),
  );
  return lv.controller!.offset;
}

GoRouter _router() => GoRouter(
      initialLocation: '/diff',
      routes: [
        GoRoute(
          path: '/diff',
          builder: (_, _) => const DiffDetailScreen(
            sessionId: 's1',
            path: 'lib/main.dart',
            directory: '/tmp/proj',
          ),
        ),
        GoRoute(
          path: '/session/:id/files',
          builder: (_, s) => FileBrowsingContainer(
            sessionId: s.pathParameters['id']!,
            directory: s.uri.queryParameters['directory'],
            initial: s.extra as FileBrowsingSnapshot?,
          ),
        ),
      ],
    );

void main() {
  tearDown(() {
    serverStore.client = null;
  });

  Future<void> pumpDiff(WidgetTester tester, {String patch = _patch}) async {
    SharedPreferences.setMockInitialValues({});
    serverStore.client = _MockClient(patch);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: _router(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('no scroll: anchors to first hunk start (line 10)', (tester) async {
    await pumpDiff(tester);
    expect(find.text('L10–12'), findsWidgets);

    await tester.tap(find.text('View full file'));
    await tester.pumpAndSettle();

    final expected = codeListVerticalPadding + 9 * _lineHeight();
    expect(_fileViewOffset(tester), closeTo(expected, 0.5));
  });

  Finder stickyText(String text) => find.descendant(
        of: find.byType(Positioned),
        matching: find.text(text),
      );

  testWidgets('scrolled to hunk 2: anchors to its start (line 67)', (tester) async {
    await pumpDiff(tester);
    expect(stickyText('L10–12'), findsOneWidget);

    // Scroll down until hunk 2 (L67) becomes the sticky header.
    await tester.drag(
      find.descendant(
        of: find.byType(DiffDetailScreen),
        matching: find.byType(ListView),
      ),
      const Offset(0, -120),
    );
    await tester.pumpAndSettle();
    expect(stickyText('L67–69'), findsOneWidget);

    await tester.tap(find.text('View full file'));
    await tester.pumpAndSettle();

    final expected = codeListVerticalPadding + 66 * _lineHeight();
    expect(_fileViewOffset(tester), closeTo(expected, 0.5));
  });

  testWidgets('deep inside a long hunk: sticky survives header unmount, anchors to its start',
      (tester) async {
    await pumpDiff(tester, patch: _longFirstHunkPatch);
    expect(stickyText('L10–48'), findsOneWidget);

    // Scroll far past the first hunk's header so it leaves the cache extent
    // and its render object is disposed; the sticky header must still track
    // the hunk the viewport is inside.
    await tester.drag(
      find.descendant(
        of: find.byType(DiffDetailScreen),
        matching: find.byType(ListView),
      ),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(stickyText('L10–48'), findsOneWidget);

    await tester.tap(find.text('View full file'));
    await tester.pumpAndSettle();

    final expected = codeListVerticalPadding + 9 * _lineHeight();
    expect(_fileViewOffset(tester), closeTo(expected, 0.5));
  });
}
