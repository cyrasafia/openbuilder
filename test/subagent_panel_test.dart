import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'v2_test_fixtures.dart';

/// SubagentPanel (design-subagent-status) widget 约定：
/// - task tool part 渲染为面板而非 ToolChip：收起态显示 agent 名 + 描述
/// - 点击展开 → post-frame 触发 loadChildSessionMessages（REST 快照）→
///   子会话消息流出现在内嵌块中
/// - metadata.sessionID（subagent）/ sessionId（task）是权威来源（不依赖
///   findChildSession 启发式）；agent 标题读 input.agent / subagent_type
/// - 子会话晚注册时面板监听 serverStore 自动自愈
/// - 无 childSessionId 时展开显示「子会话未就绪」
class _MockClient extends OpencodeClient {
  final Map<String, List<SessionMessage>> entriesBySession;
  _MockClient(this.entriesBySession) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async =>
      MessagesPage(entriesBySession[sessionId] ?? const [], null, null);
}

Dio _noopDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(milliseconds: 1),
        receiveTimeout: const Duration(milliseconds: 1),
      ),
    );

Future<void> _pumpConversation(
  WidgetTester tester, {
  required String sessionId,
  required Map<String, List<SessionMessage>> entriesBySession,
}) async {
  SharedPreferences.setMockInitialValues({});
  serverStore.resetForTesting();
  serverStore.client = _MockClient(entriesBySession);
  final router = GoRouter(
    initialLocation: '/session/$sessionId',
    routes: [
      GoRoute(
        path: '/session/:id',
        builder: (_, s) =>
            ConversationScreen(sessionId: s.pathParameters['id']!),
      ),
    ],
  );
  await tester.pumpWidget(
    MaterialApp.router(
      locale: const Locale('zh'),
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
}

SessionMessage _taskMessage(String sid, String id, int created,
    {required String status,
    String? childSessionId,
    String tool = 'task',
    String metadataKey = 'sessionId',
    String inputKey = 'subagent_type',
    String agent = 'explore',
    String description = '调研仓库结构'}) {
  return assistantMsg(
    id: id,
    created: created,
    finish: 'stop',
    content: [
      toolPart(
        id: 'p$id',
        name: tool,
        status: status,
        input: {
          inputKey: agent,
          'description': description,
        },
        metadata:
            childSessionId != null ? {metadataKey: childSessionId} : null,
      ),
    ],
  );
}

SessionMessage _childExchange(String sid, int created) => assistantMsg(
      id: 'cm$created',
      created: created,
      finish: 'stop',
      content: [textPart('子会话产出 $created')],
    );

Future<void> _settle(WidgetTester tester, bool Function() probe) async {
  for (var i = 0; i < 60 && !probe(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('collapsed panel shows agent label + description', (tester) async {
    await _pumpConversation(
      tester,
      sessionId: 'sp1',
      entriesBySession: {
        'sp1': [_taskMessage('sp1', 'm1', 1, status: 'running')],
      },
    );
    await _settle(tester, () => find.text('Explore').evaluate().isNotEmpty);
    expect(find.text('Explore'), findsOneWidget,
        reason: 'subagent_type capitalized as the panel label');
    expect(find.text('调研仓库结构'), findsOneWidget,
        reason: 'running state surfaces the description as summary');
    expect(find.textContaining('task:'), findsNothing,
        reason: 'task tool must not render as a generic ToolChip');
  });

  testWidgets('expand loads the child session and renders its messages',
      (tester) async {
    const kid = 'sp2-kid';
    await _pumpConversation(
      tester,
      sessionId: 'sp2',
      entriesBySession: {
        'sp2': [
          _taskMessage('sp2', 'm1', 1, status: 'completed', childSessionId: kid)
        ],
        kid: [_childExchange(kid, 10), _childExchange(kid, 20)],
      },
    );
    await _settle(tester, () => find.text('Explore').evaluate().isNotEmpty);
    expect(find.text('子会话产出 10'), findsNothing,
        reason: 'child messages hidden while collapsed');

    await tester.tap(find.text('Explore'));
    await _settle(
        tester, () => find.text('子会话产出 10').evaluate().isNotEmpty);
    expect(find.text('子会话产出 10'), findsOneWidget);
    expect(find.text('子会话产出 20'), findsOneWidget,
        reason: 'REST snapshot of the child session renders in the panel');
  });

  testWidgets('expand without child session shows the not-ready state',
      (tester) async {
    await _pumpConversation(
      tester,
      sessionId: 'sp3',
      entriesBySession: {
        'sp3': [_taskMessage('sp3', 'm1', 1, status: 'running')],
      },
    );
    await _settle(tester, () => find.text('Explore').evaluate().isNotEmpty);
    await tester.tap(find.text('Explore'));
    await _settle(tester, () => find.text('子会话未就绪').evaluate().isNotEmpty);
    expect(find.text('子会话未就绪'), findsOneWidget);
  });

  testWidgets(
      'short transcript: expanding the panel keeps the child list scrollable',
      (tester) async {
    // A transcript shorter than the viewport (outer list maxScrollExtent == 0)
    // must not let the expand animation's reversed-scroll sync push the outer
    // pixels out of range, which would shove the panel off screen and make the
    // child stream unreachable.
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    const kid = 'sp4-kid';
    final childMsgs = <SessionMessage>[
      for (var i = 0; i < 20; i++)
        assistantMsg(
          id: 'cm$i',
          created: i,
          finish: 'stop',
          content: [textPart('子会话产出 $i ${'x' * 200}')],
        ),
    ];
    await _pumpConversation(
      tester,
      sessionId: 'sp4',
      entriesBySession: {
        'sp4': [
          _taskMessage('sp4', 'm1', 1,
              status: 'completed', childSessionId: kid),
        ],
        kid: childMsgs,
      },
    );
    await _settle(tester, () => find.text('Explore').evaluate().isNotEmpty);
    await tester.tap(find.text('Explore'));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (find.byType(ListView).evaluate().isNotEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 300));

    final outer = tester.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(CustomScrollView).first,
            matching: find.byType(Scrollable),
          )
          .first,
    );
    expect(outer.position.maxScrollExtent, 0,
        reason: 'transcript is shorter than the viewport');
    expect(outer.position.pixels, 0,
        reason: 'no phantom overscroll pushing the panel off screen');

    final listView = find.byType(ListView);
    final innerPos = tester
        .state<ScrollableState>(
          find.descendant(of: listView, matching: find.byType(Scrollable)),
        )
        .position;
    expect(innerPos.maxScrollExtent, greaterThan(0),
        reason: 'child stream overflows the 400px window');

    await tester.drag(listView, const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(innerPos.pixels, greaterThan(0),
        reason: 'short transcript must not disable child-list scrolling');
  });

  testWidgets('subagent tool resolves child via metadata.sessionID + agent label',
      (tester) async {
    const kid = 'sp5-kid';
    await _pumpConversation(
      tester,
      sessionId: 'sp5',
      entriesBySession: {
        'sp5': [
          _taskMessage(
            'sp5',
            'm1',
            1,
            status: 'completed',
            childSessionId: kid,
            tool: 'subagent',
            metadataKey: 'sessionID',
            inputKey: 'agent',
            agent: 'reviewer',
            description: '评审改动',
          ),
        ],
        kid: [_childExchange(kid, 10)],
      },
    );
    await _settle(tester, () => find.text('Reviewer').evaluate().isNotEmpty);
    expect(find.text('Reviewer'), findsOneWidget,
        reason: 'subagent input uses the agent key');

    await tester.tap(find.text('Reviewer'));
    await _settle(
        tester, () => find.text('子会话产出 10').evaluate().isNotEmpty);
    expect(find.text('子会话产出 10'), findsOneWidget,
        reason: 'metadata.sessionID must resolve the child session');
  });

  testWidgets('panel self-heals when the child session registers late',
      (tester) async {
    const parent = 'sp6';
    const kid = 'sp6-kid';
    await _pumpConversation(
      tester,
      sessionId: parent,
      entriesBySession: {
        parent: [
          _taskMessage(
            parent,
            'm1',
            1,
            status: 'running',
            tool: 'subagent',
            inputKey: 'agent',
            agent: 'reviewer',
            description: 'late kid',
          ),
        ],
        kid: [_childExchange(kid, 10)],
      },
    );
    await _settle(tester, () => find.text('Reviewer').evaluate().isNotEmpty);
    await tester.tap(find.text('Reviewer'));
    await _settle(
        tester, () => find.text('子会话未就绪').evaluate().isNotEmpty);
    expect(find.text('子会话未就绪'), findsOneWidget);

    serverStore.onEventForTesting(OpencodeEvent(
      id: 'evt-late',
      created: 100,
      type: 'session.created',
      properties: {
        'sessionID': kid,
        'projectID': 'p',
        'parentID': parent,
        'title': 'late kid',
        'location': {'directory': '/repo'},
      },
    ));

    await _settle(
        tester, () => find.text('子会话产出 10').evaluate().isNotEmpty);
    expect(find.text('子会话未就绪'), findsNothing);
    expect(find.text('子会话产出 10'), findsOneWidget,
        reason: 'late child registration must rebuild the panel');
  });
}
