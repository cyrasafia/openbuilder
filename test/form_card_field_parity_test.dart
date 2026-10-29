import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:open_builder/app_state.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/conversation/conversation_screen.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';
import 'package:open_builder/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockClient extends OpencodeClient {
  final List<FormInfo> forms;
  final Map<String, Map<String, dynamic>> replies = {};
  _MockClient({this.forms = const []}) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(
    String sessionId, {
    required int limit,
    String? cursor,
  }) async =>
      MessagesPage(const [], null, null);

  @override
  Future<List<FormInfo>> sessionForms(String sessionId) async => forms;

  @override
  Future<void> replyForm(
    String sessionId,
    String formId,
    Map<String, dynamic> answer,
  ) async {
    replies[formId] = answer;
  }
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

void _markBusy(ServerStore store, String sid) =>
    store.onEventForTesting(OpencodeEvent(
      type: 'session.execution.started',
      properties: {'sessionID': sid},
    ));

OpencodeEvent _formCreated(Map<String, dynamic> form) => OpencodeEvent(
      type: 'form.created',
      properties: {'form': form},
    );

const _session = SessionModel(
  id: 's1',
  projectID: 'p',
  directory: '/d',
  title: 't',
  created: 0,
  updated: 0,
);

Future<void> _pumpConversation(WidgetTester tester, String sessionId) async {
  SharedPreferences.setMockInitialValues({});
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
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      routerConfig: router,
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

bool _submitEnabled(WidgetTester tester) {
  final btn = tester.widget<FilledButton>(
    find.ancestor(of: find.text('Submit'), matching: find.byType(FilledButton)),
  );
  return btn.onPressed != null;
}

final _formTextField = find.byWidgetPredicate(
  (w) => w is TextField && w.maxLines == 3,
);

const _externalNoticeEn =
    'This form includes an authorization step that must be completed '
    'externally. Submit to acknowledge and continue.';

const _autoNoticeEn =
    'This form includes fields handled automatically by the server. Submit to '
    'acknowledge and continue.';

void main() {
  group('FormInfo.fromJson keeps hidden/external fields (T2/T3)', () {
    test('fields are retained for answer construction', () {
      final f = FormInfo.fromJson({
        'id': 'frm_1',
        'sessionID': 's1',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string'},
          {'key': 'q1', 'type': 'string', 'hidden': true},
          {
            'key': 'q2',
            'type': 'external',
            'url': 'https://example.com/auth',
          },
          {
            'key': 'q3',
            'type': 'multiselect',
            'options': [
              {'value': 'a', 'label': 'a'},
            ],
          },
        ],
      });
      expect(f.fields.map((e) => e.key), ['q0', 'q1', 'q2', 'q3']);
      expect(f.fields[1].hidden, isTrue);
    });
  });

  group('empty-field form is dropped (defensive)', () {
    test('SSE form.created with empty fields never enters the queue',
        () async {
      final store = ServerStore()..client = _MockClient();
      store.upsertSessionForTesting(_session);
      _markBusy(store, 's1');

      store.onEventForTesting(_formCreated({
        'id': 'frm_3',
        'sessionID': 's1',
        'title': 't',
        'fields': const [],
      }));
      expect(store.hasPendingQuestion('s1'), isFalse);
    });

    test('backfill skips empty-field forms', () async {
      final empty = FormInfo(
        id: 'frm_4',
        sessionID: 's1',
        title: 'q',
        fields: const [],
      );
      final store = ServerStore()..client = _MockClient(forms: [empty]);
      store.upsertSessionForTesting(_session);
      _markBusy(store, 's1');

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isFalse);
    });
  });

  group('form card step gating (T4)', () {
    testWidgets('required text field blocks submit until non-empty',
        (tester) async {
      serverStore.client = _MockClient();
      await _pumpConversation(tester, 'w1');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_5',
        'sessionID': 'w1',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Your name', 'required': true},
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Submit'), findsOneWidget);
      expect(_submitEnabled(tester), isFalse);

      await tester.enterText(_formTextField, 'ada');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_submitEnabled(tester), isTrue);
    });

    testWidgets('optional text field allows empty submit', (tester) async {
      serverStore.client = _MockClient();
      await _pumpConversation(tester, 'w2');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_6',
        'sessionID': 'w2',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Notes'},
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Submit'), findsOneWidget);
      expect(_submitEnabled(tester), isTrue);
    });

    testWidgets('hidden/external fields are not rendered as steps',
        (tester) async {
      serverStore.client = _MockClient();
      await _pumpConversation(tester, 'w3');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_7',
        'sessionID': 'w3',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Visible'},
          {'key': 'q1', 'type': 'string', 'title': 'Secret', 'hidden': true},
          {'key': 'q2', 'type': 'external', 'title': 'Auth', 'url': 'https://x'},
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Visible'), findsOneWidget);
      expect(find.text('Secret'), findsNothing);
      expect(find.text('Auth'), findsNothing);
      expect(find.text('Next'), findsNothing);
      expect(_formTextField, findsOneWidget);
    });
  });

  group('answer construction covers hidden/external fields', () {
    testWidgets('required hidden sends typed default; external acks true',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w4');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_8',
        'sessionID': 'w4',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Visible'},
          {
            'key': 'h1',
            'type': 'integer',
            'title': 'Hidden',
            'hidden': true,
            'required': true,
            'default': 7,
          },
          {
            'key': 'e2',
            'type': 'external',
            'title': 'Auth',
            'url': 'https://x',
          },
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(_formTextField, 'hi');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.replies['frm_8'], {
        'q0': 'hi',
        'h1': 7,
        'e2': true,
      });
    });

    testWidgets('optional hidden field sends no key', (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w5');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_9',
        'sessionID': 'w5',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Visible'},
          {'key': 'h1', 'type': 'string', 'title': 'Hidden', 'hidden': true},
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(_formTextField, 'hi');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.replies['frm_9'], {'q0': 'hi'});
    });

    testWidgets(
        'required hidden without default degrades to a visible step',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w6');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_10',
        'sessionID': 'w6',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Visible'},
          {
            'key': 'h1',
            'type': 'string',
            'title': 'Degraded',
            'hidden': true,
            'required': true,
          },
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Visible'), findsOneWidget);
      expect(find.text('Next'), findsOneWidget);

      await tester.enterText(_formTextField, 'a');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Next'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Degraded'), findsOneWidget);
      expect(_submitEnabled(tester), isFalse);

      await tester.enterText(_formTextField, 'b');
      await tester.pump(const Duration(milliseconds: 100));
      expect(_submitEnabled(tester), isTrue);

      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_10'], {'q0': 'a', 'h1': 'b'});
    });

    testWidgets('all-external form renders ack notice and submits true',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w7');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_11',
        'sessionID': 'w7',
        'title': 'Authorize MCP',
        'fields': [
          {
            'key': 'e0',
            'type': 'external',
            'title': 'Auth',
            'url': 'https://x',
          },
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(_externalNoticeEn), findsOneWidget);
      expect(find.text('Next'), findsNothing);
      expect(_submitEnabled(tester), isTrue);

      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_11'], {'e0': true});
    });

    testWidgets(
        'hidden+external ack-only form prefers the external notice',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w12');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_16',
        'sessionID': 'w12',
        'title': 'Auto + Auth',
        'fields': [
          {
            'key': 'h0',
            'type': 'string',
            'title': 'H',
            'hidden': true,
            'required': true,
            'default': 'auto',
          },
          {
            'key': 'e1',
            'type': 'external',
            'title': 'Auth',
            'url': 'https://x',
          },
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(_externalNoticeEn), findsOneWidget);
      expect(find.text(_autoNoticeEn), findsNothing);
      expect(_submitEnabled(tester), isTrue);

      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_16'], {'h0': 'auto', 'e1': true});
    });

    testWidgets('all-hidden optional form submits empty answer',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w8');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_12',
        'sessionID': 'w8',
        'title': 'Auto',
        'fields': [
          {'key': 'h0', 'type': 'string', 'title': 'H', 'hidden': true},
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text(_autoNoticeEn), findsOneWidget);
      expect(find.text('Next'), findsNothing);
      expect(_submitEnabled(tester), isTrue);

      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_12'], isEmpty);
    });

    testWidgets('typed defaults cover boolean, number and multiselect',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w9');

      serverStore.onEventForTesting(_formCreated({
        'id': 'frm_13',
        'sessionID': 'w9',
        'title': 't',
        'fields': [
          {'key': 'q0', 'type': 'string', 'title': 'Visible'},
          {
            'key': 'hb',
            'type': 'boolean',
            'hidden': true,
            'required': true,
            'default': true,
          },
          {
            'key': 'hn',
            'type': 'number',
            'hidden': true,
            'required': true,
            'default': 1.5,
          },
          {
            'key': 'hm',
            'type': 'multiselect',
            'hidden': true,
            'required': true,
            'default': ['a', 'b'],
            'options': [
              {'value': 'a', 'label': 'a'},
              {'value': 'b', 'label': 'b'},
            ],
          },
        ],
      }));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(_formTextField, 'hi');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));

      expect(client.replies['frm_13'], {
        'q0': 'hi',
        'hb': true,
        'hn': 1.5,
        'hm': ['a', 'b'],
      });
    });

    testWidgets('same-id payload with fewer steps clamps _step (no crash)',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w10');

      Map<String, dynamic> payload(int count) => {
            'id': 'frm_14',
            'sessionID': 'w10',
            'title': 't',
            'fields': [
              for (var i = 0; i < count; i++)
                {'key': 'q$i', 'type': 'string', 'title': 'Field $i'},
            ],
          };

      serverStore.onEventForTesting(_formCreated(payload(3)));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(_formTextField, 'a');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Next'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Field 1'), findsOneWidget);

      serverStore.onEventForTesting(_formCreated(payload(1)));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Field 0'), findsOneWidget);
      expect(find.text('Next'), findsNothing);
      expect(find.text('Submit'), findsOneWidget);

      await tester.enterText(_formTextField, 'b');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_14'], {'q0': 'b'});
    });

    testWidgets(
        'same-id payload gaining a default drops the degraded step (clamp)',
        (tester) async {
      final client = _MockClient();
      serverStore.client = client;
      await _pumpConversation(tester, 'w11');

      Map<String, dynamic> payload(Object? def) => {
            'id': 'frm_15',
            'sessionID': 'w11',
            'title': 't',
            'fields': [
              {'key': 'q0', 'type': 'string', 'title': 'Visible'},
              {
                'key': 'h1',
                'type': 'string',
                'title': 'Degraded',
                'hidden': true,
                'required': true,
                'default': ?def,
              },
            ],
          };

      serverStore.onEventForTesting(_formCreated(payload(null)));
      await tester.pump(const Duration(milliseconds: 100));

      await tester.enterText(_formTextField, 'a');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tap(find.text('Next'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Degraded'), findsOneWidget);

      serverStore.onEventForTesting(_formCreated(payload('auto')));
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('Visible'), findsOneWidget);
      expect(find.text('Next'), findsNothing);

      await tester.tap(find.text('Submit'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(client.replies['frm_15'], {'q0': 'a', 'h1': 'auto'});
    });
  });
}
