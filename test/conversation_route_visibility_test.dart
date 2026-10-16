import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/nav/app_route_observer.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// design/v2/design-unread-marker.md §4.2：ack 只在详情页**可见**（未被不透明路由盖住）
/// 且 app 在前台时成立。被文件列表 / 详情 / diff 等页面覆盖时必须解除激活，否则停留期间
/// 的终态会被误判为「已看」（未读被清、完成通知被本端 ack 回声撤掉）。
/// 反向：bottom sheet / dialog 等非不透明弹层不算盖住——用户仍在看详情页。
class _EmptyClient extends OpencodeClient {
  _EmptyClient()
      : super(Dio(BaseOptions(
          connectTimeout: const Duration(milliseconds: 1),
          receiveTimeout: const Duration(milliseconds: 1),
        )));

  @override
  Future<MessagesPage> messagesPage(String sessionId,
          {required int limit, String? cursor}) async =>
      MessagesPage(const [], null, null);
}

void main() {
  testWidgets('detail page is active only while it is visible', (tester) async {
    SharedPreferences.setMockInitialValues({});
    serverStore.client = _EmptyClient();
    serverStore.setActiveConversation(null);
    const sid = 'vis-1';
    final router = GoRouter(
      initialLocation: '/session/$sid',
      observers: [appRouteObserver],
      routes: [
        GoRoute(
          path: '/session/:id',
          builder: (_, s) =>
              ConversationScreen(sessionId: s.pathParameters['id']!),
        ),
        GoRoute(
          path: '/cover',
          builder: (_, _) => const Scaffold(body: Text('cover')),
        ),
      ],
    );
    await tester.pumpWidget(MaterialApp.router(
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ));
    await tester.pump(const Duration(milliseconds: 50));
    expect(serverStore.activeConversationId, sid);

    final covered = router.push('/cover');
    await tester.pump(const Duration(milliseconds: 350));
    expect(serverStore.activeConversationId, isNull,
        reason: 'a covering page must clear the activation (no ack while '
            'the user is not looking at the conversation)');

    router.pop();
    await covered;
    await tester.pump(const Duration(milliseconds: 350));
    expect(serverStore.activeConversationId, sid,
        reason: 'popping back to the conversation must restore the activation');

    final ctx = tester.element(find.byType(ConversationScreen));
    showModalBottomSheet<void>(
      context: ctx,
      builder: (_) => const SizedBox(height: 120, child: Text('sheet')),
    );
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('sheet'), findsOneWidget);
    expect(serverStore.activeConversationId, sid,
        reason: 'a non-opaque overlay does not count as covering the page');

    final overSheet = router.push('/cover');
    await tester.pump(const Duration(milliseconds: 350));
    expect(serverStore.activeConversationId, isNull,
        reason: 'an opaque page above the sheet still covers the conversation');

    router.pop();
    await overSheet;
    await tester.pump(const Duration(milliseconds: 350));
    expect(serverStore.activeConversationId, sid,
        reason: 'popping it back must reveal the conversation again, even with '
            'the sheet still open');

    Navigator.of(ctx).pop();
    await tester.pump(const Duration(milliseconds: 350));
    expect(serverStore.activeConversationId, sid);
  });
}
