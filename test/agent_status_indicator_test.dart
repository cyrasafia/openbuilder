import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/ui/widgets.dart';

void main() {
  test('pending requests project over run status without replacing it', () {
    final store = ServerStore();

    store.onEventForTesting(const OpencodeEvent(
      type: 'permission.asked',
      properties: {
        'id': 'perm-1',
        'sessionID': 'session-1',
        'permission': 'bash',
      },
    ));
    store.onEventForTesting(const OpencodeEvent(
      type: 'question.asked',
      properties: {
        'id': 'question-1',
        'sessionID': 'session-1',
        'questions': [],
      },
    ));
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.status',
      properties: {
        'sessionID': 'session-1',
        'status': {'type': 'busy'},
      },
    ));

    var state = store.agentIndicatorStateOf('session-1');
    expect(state.state, AgentRunState.paused);
    expect(state.pauseReason, AgentPauseReason.permission);
    expect(state.pendingCount, 2);

    store.onEventForTesting(const OpencodeEvent(
      type: 'permission.replied',
      properties: {'sessionID': 'session-1', 'requestID': 'perm-1'},
    ));
    state = store.agentIndicatorStateOf('session-1');
    expect(state.state, AgentRunState.paused);
    expect(state.pauseReason, AgentPauseReason.choice);
    expect(state.pendingCount, 1);

    store.onEventForTesting(const OpencodeEvent(
      type: 'question.replied',
      properties: {'sessionID': 'session-1', 'requestID': 'question-1'},
    ));
    state = store.agentIndicatorStateOf('session-1');
    expect(state.state, AgentRunState.working);
    expect(state.pendingCount, 0);
  });

  testWidgets('indicator renders all visible states and pending count',
      (tester) async {
    Future<void> show(AgentIndicatorState state) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AgentStatusIndicator(state: state),
        ),
      ));
      await tester.pump();
    }

    await show(const AgentIndicatorState(AgentRunState.working));
    expect(find.text('运行中'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.retrying));
    expect(find.text('重试中'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.idle));
    expect(find.text('空闲'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.permission, pendingCount: 2));
    expect(find.text('需要授权 · 2'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.choice, pendingCount: 1));
    expect(find.text('需要选择'), findsOneWidget);
  });

  testWidgets('indicator exposes one combined semantics label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: AgentStatusIndicator(
          state: AgentIndicatorState(AgentRunState.paused,
              pauseReason: AgentPauseReason.permission, pendingCount: 2),
        ),
      ),
    ));

    expect(
      tester.getSemantics(find.byType(AgentStatusIndicator)),
      matchesSemantics(label: 'Agent 需要授权，共 2 项待处理'),
    );
    semantics.dispose();
  });
}
