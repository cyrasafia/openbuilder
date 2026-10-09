import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
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

    store.onEventForTesting(const OpencodeEvent(
      type: 'session.execution.failed',
      properties: {'sessionID': 'session-1'},
    ));
    state = store.agentIndicatorStateOf('session-1');
    expect(state.state, AgentRunState.failed);
    store.dispose();
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
    expect(find.byIcon(Icons.autorenew), findsNothing);

    await show(const AgentIndicatorState(AgentRunState.failed));
    expect(find.text('Failed'), findsOneWidget);

    await show(const AgentIndicatorState(AgentRunState.idle));
    expect(find.text('Idle'), findsOneWidget);
    expect(find.byIcon(Icons.circle), findsNothing);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.permission, pendingCount: 2));
    expect(find.text('Authorization needed · 2'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);

    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.choice, pendingCount: 1));
    expect(find.text('Selection needed'), findsOneWidget);
    expect(find.byIcon(Icons.help_outline), findsNothing);
  });

  testWidgets('dots carry the per-brightness four-color palette',
      (tester) async {
    List<BoxDecoration> circleDecorations() => tester
        .widgetList<DecoratedBox>(find.byType(DecoratedBox))
        .map((b) => b.decoration)
        .whereType<BoxDecoration>()
        .where((d) => d.shape == BoxShape.circle)
        .toList();

    Future<void> show(AgentIndicatorState state, {bool dark = false}) async {
      await tester.pumpWidget(MaterialApp(
        theme: dark ? AppTheme.dark : AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [Locale('en'), Locale('zh')],
        home: Scaffold(body: AgentStatusGlyph(state: state)),
      ));
      // MaterialApp animates theme switches via AnimatedTheme (200ms); a
      // bare pump() would sample the lerp start. Pump past the transition —
      // pumpAndSettle would hang on the _HaloDot breathing animation.
      await tester.pump(const Duration(milliseconds: 300));
    }

    // Halo states: center dot renders the accent at full opacity (the halo
    // layer is alpha-animated).
    await show(const AgentIndicatorState(AgentRunState.working));
    expect(circleDecorations().map((d) => d.color),
        contains(const Color(0xFF15803D)));
    await show(const AgentIndicatorState(AgentRunState.working), dark: true);
    expect(circleDecorations().map((d) => d.color),
        contains(const Color(0xFF1DAE4E)));

    await show(const AgentIndicatorState(AgentRunState.retrying));
    expect(circleDecorations().map((d) => d.color),
        contains(const Color(0xFFB91C1C)));
    await show(const AgentIndicatorState(AgentRunState.retrying), dark: true);
    expect(circleDecorations().map((d) => d.color),
        contains(const Color(0xFFE5484D)));

    // Static states: exactly one dot. The waiting amber is per-brightness;
    // idle is dimmed to 0.55 alpha.
    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.permission, pendingCount: 1));
    expect(circleDecorations().single.color, const Color(0xFFB8860B));
    await show(const AgentIndicatorState(AgentRunState.paused,
        pauseReason: AgentPauseReason.permission, pendingCount: 1),
        dark: true);
    expect(circleDecorations().single.color, const Color(0xFFFBBF24));

    await show(const AgentIndicatorState(AgentRunState.idle));
    expect((circleDecorations().single.color!.a * 255).round(), 140);
    await show(const AgentIndicatorState(AgentRunState.idle), dark: true);
    expect((circleDecorations().single.color!.a * 255).round(), 140);
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
