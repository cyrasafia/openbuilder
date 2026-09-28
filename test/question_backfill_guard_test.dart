import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

class _FormsMockClient extends OpencodeClient {
  List<FormInfo> forms;
  _FormsMockClient({this.forms = const []}) : super(_noopDio());

  @override
  Future<List<FormInfo>> listForms({String? directory}) async => forms;
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));

void main() {
  group('form backfill guard (_recentlyResolved)', () {
    test('resolved form is skipped on subsequent backfill', () async {
      final f1 = FormInfo(
          id: 'frm_g1', sessionID: 's1', title: 'q', fields: const []);
      final client = _FormsMockClient(forms: [f1]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(const SessionModel(
        id: 's1',
        projectID: 'p',
        directory: '/d',
        title: 't',
        created: 0,
        updated: 0,
      ));

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isTrue);

      final conv = store.ensureConversation('s1')!;
      expect(conv.onQuestionResolved, isNotNull);
      conv.onQuestionResolved!('frm_g1');
      expect(store.hasPendingQuestion('s1'), isFalse);

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s1'), isFalse);
    });

    test('guard expires after TTL, re-surfaces if still pending server-side',
        () async {
      final f1 = FormInfo(
          id: 'frm_g2', sessionID: 's2', title: 'q', fields: const []);
      final client = _FormsMockClient(forms: [f1]);
      final store = ServerStore()..client = client;
      store.upsertSessionForTesting(const SessionModel(
        id: 's2',
        projectID: 'p',
        directory: '/d',
        title: 't',
        created: 0,
        updated: 0,
      ));

      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s2'), isTrue);

      final conv = store.ensureConversation('s2')!;
      conv.onQuestionResolved!('frm_g2');
      expect(store.hasPendingQuestion('s2'), isFalse);

      store.expireRecentlyResolvedForTesting();
      await store.backfillQuestionsForTesting();
      expect(store.hasPendingQuestion('s2'), isTrue);
    });
  });
}
