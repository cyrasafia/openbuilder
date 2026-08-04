import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/attachments/file_ref.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/files/file_browsing_container.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends OpencodeClient {
  _MockClient() : super(_noopDio());

  @override
  Future<List<FileNode>> listFiles({
    required String directory,
    required String path,
  }) async =>
      [
        const FileNode(
          name: 'src',
          path: 'src/',
          absolute: '/tmp/proj/src',
          type: 'directory',
          ignored: false,
        ),
        const FileNode(
          name: 'main.dart',
          path: 'lib/main.dart',
          absolute: '/tmp/proj/lib/main.dart',
          type: 'file',
          ignored: false,
        ),
      ];
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

void main() {
  tearDown(() {
    serverStore.fileBrowsing.unregisterRefPicker('s1');
    serverStore.client = null;
  });

  testWidgets('long-press on file row shows the mention popup menu', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    serverStore.client = _MockClient();
    FileRef? picked;
    serverStore.fileBrowsing.registerRefPicker('s1', (r) => picked = r);
    final router = GoRouter(
      initialLocation: '/session/s1',
      routes: [
        GoRoute(
          path: '/session/:id',
          builder: (_, _) => const Scaffold(body: Text('conversation')),
        ),
        GoRoute(
          path: '/session/:id/files',
          builder: (_, s) => FileBrowsingContainer(
            sessionId: s.pathParameters['id']!,
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp.router(
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    router.push('/session/s1/files');
    await tester.pumpAndSettle();

    expect(find.text('main.dart'), findsOneWidget);
    await tester.longPress(find.text('main.dart'));
    await tester.pumpAndSettle();

    final loc = AppLocalizations.of(
      tester.element(find.byType(Scaffold).last),
    )!;
    final item = find.text(loc.fileMentionInConversation);
    expect(
      item,
      findsOneWidget,
      reason: 'long-press must open the mention popup menu',
    );

    await tester.tap(item);
    await tester.pumpAndSettle();

    expect(
      picked?.absolute,
      '/tmp/proj/lib/main.dart',
      reason: 'tapping the menu item must mention the file in the session',
    );
    expect(
      find.text('conversation'),
      findsOneWidget,
      reason: 'mentioning must collapse the file browser back to the session',
    );
  });
}
