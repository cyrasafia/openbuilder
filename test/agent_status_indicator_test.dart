import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/widgets.dart';

Widget _wrap(Widget child) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('zh')],
      home: Scaffold(body: child),
    );

void main() {
  test('pending requests project over run status without replacing it', () {
    final store = ServerStore();

    store.onEventForTesting(const OpencodeEvent(
      type: 'permission.asked',
      properties: {
        'id': 'perm-1',
        'sessionID': 'session-1',
        'action': 'bash',
      },
    ));
    store.onEventForTesting(const OpencodeEvent(
      type: 'form.created',
      properties: {
        'form': {
          'id': 'question-1',
          'sessionID': 'session-1',
          'title': 'proceed?',
          'fields': [],
        },
      },
    ));
    store.onEventForTesting(const OpencodeEvent(
      type: 'session.execution.started',
      properties: {
        'sessionID': 'session-1',
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
      type: 'form.replied',
      properties: {'sessionID': 'session-1', 'id': 'question-1'},
    ));
    state = store.agentIndicatorStateOf('session-1');
    expect(state.state, AgentRunState.working);
    expect(state.pendingCount, 0);
  });

  testWidgets('indicator renders all visible states and pending count',
      (tester) async {
    Future<void> show(AgentIndicatorState state) async {
      await tester.pumpWidget(_wrap(AgentStatusIndicator(state: state)));
      await tester.pump();
    }

    await show(const AgentIndicatorState(AgentRunState.working));
    expect(find.text('Running'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.retrying));
    expect(find.text('Retrying'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.idle));
    expect(find.text('Idle'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.permission, pendingCount: 2));
    expect(find.text('Authorization needed · 2'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.choice, pendingCount: 1));
    expect(find.text('Selection needed'), findsOneWidget);
  });

  testWidgets('indicator exposes one combined semantics label', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_wrap(const AgentStatusIndicator(
      state: AgentIndicatorState(AgentRunState.paused,
          pauseReason: AgentPauseReason.permission, pendingCount: 2),
    )));

    expect(
      tester.getSemantics(find.byType(AgentStatusIndicator)),
      matchesSemantics(label: 'Agent Authorization needed, 2 items pending'),
    );
    semantics.dispose();
  });
}
