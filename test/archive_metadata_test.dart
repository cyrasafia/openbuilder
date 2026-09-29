import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// Archived sessions carry two mutually exclusive markers on the v2 server:
// legacy `time.archived` (v1 stock, no v2 write path) and the cross-client
// private contract `metadata.archivedAt` written by openbuilder-desktop
// (design-v2-migration D1). Recognition must be dual-source; filtering on
// `archived == null` alone leaks desktop-archived sessions into the list
// (29-session worktree showed 8 instead of 1).

class _SessionsAdapter implements HttpClientAdapter {
  final String body;
  int calls = 0;
  _SessionsAdapter(this.body);
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    return ResponseBody.fromString(
      body,
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

OpencodeClient _clientWithBody(String body) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = _SessionsAdapter(body);
  return OpencodeClient(dio);
}

OpencodeClient _clientWithAdapter(HttpClientAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'))
    ..httpClientAdapter = adapter;
  return OpencodeClient(dio);
}

OpencodeClient _unreachableClient() => OpencodeClient(
  dioFor(
    const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    ),
  ),
);

SessionModel _session(String id, {String? parentID}) {
  final j = <String, dynamic>{
    'id': id,
    'projectID': 'p1',
    'location': {'directory': '/dirA'},
    'title': 't',
    'time': {'updated': 1000},
  };
  if (parentID != null) j['parentID'] = parentID;
  return SessionModel.fromJson(j);
}

OpencodeEvent _metaEvent(String sid, Map<String, dynamic> metadata) =>
    OpencodeEvent(
      type: 'session.metadata.updated',
      properties: {'sessionID': sid, 'metadata': metadata},
    );

void main() {
  test('fromJson recognizes both archive sources independently', () {
    final plain = SessionModel.fromJson({
      'id': 's1',
      'time': {'updated': 1},
    });
    expect(plain.archived, isNull);
    expect(plain.metadataArchivedAt, isNull);
    expect(plain.isArchived, isFalse);

    final legacy = SessionModel.fromJson({
      'id': 's2',
      'time': {'updated': 1, 'archived': 100},
    });
    expect(legacy.archived, 100);
    expect(legacy.metadataArchivedAt, isNull);
    expect(legacy.isArchived, isTrue);

    final contract = SessionModel.fromJson({
      'id': 's3',
      'time': {'updated': 1},
      'metadata': {'archivedAt': 200},
    });
    expect(contract.archived, isNull);
    expect(contract.metadataArchivedAt, 200);
    expect(contract.isArchived, isTrue);

    final both = SessionModel.fromJson({
      'id': 's4',
      'time': {'updated': 1, 'archived': 100},
      'metadata': {'archivedAt': 200},
    });
    expect(both.isArchived, isTrue);
  });

  test('toJson round-trips metadataArchivedAt through the cache shape', () {
    final s = SessionModel.fromJson({
      'id': 's3',
      'time': {'updated': 1},
      'metadata': {'archivedAt': 200},
    });
    final back = SessionModel.fromJson(s.toJson());
    expect(back.metadataArchivedAt, 200);
    expect(back.isArchived, isTrue);

    final cleared = s.withMetadataArchivedAt(null);
    expect(cleared.metadataArchivedAt, isNull);
    expect(cleared.isArchived, isFalse);
    expect(SessionModel.fromJson(cleared.toJson()).isArchived, isFalse);

    final keepsLegacy = SessionModel.fromJson({
      'id': 's2',
      'time': {'updated': 1, 'archived': 100},
    }).withMetadataArchivedAt(null);
    expect(keepsLegacy.isArchived, isTrue);
  });

  test('sessions() filters both archive sources', () async {
    final client = _clientWithBody(
      '{"data":['
      '{"id":"s1","time":{"updated":1}},'
      '{"id":"s2","time":{"updated":1,"archived":100}},'
      '{"id":"s3","time":{"updated":1},"metadata":{"archivedAt":200}},'
      '{"id":"s4","time":{"updated":1,"archived":100},"metadata":{"archivedAt":200}}'
      ']}',
    );
    final list = await client.sessions();
    expect(list.map((s) => s.id).toList(), ['s1']);
  });

  test('upsert removes session archived via metadata.archivedAt', () {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('s1'));
    expect(store.sessionById('s1'), isNotNull);

    store.upsertSessionForTesting(
      SessionModel.fromJson({
        'id': 's1',
        'projectID': 'p1',
        'location': {'directory': '/dirA'},
        'title': 't',
        'time': {'updated': 1000},
        'metadata': {'archivedAt': 200},
      }),
    );
    expect(store.sessionById('s1'), isNull);
  });

  test(
    'session.metadata.updated event archives and unarchives in place',
    () async {
      final adapter = _SessionsAdapter(
        '{"data":{"id":"s1","projectID":"p1",'
        '"location":{"directory":"/dirA"},"title":"t",'
        '"time":{"updated":1000}}}',
      );
      final store = ServerStore()..client = _clientWithAdapter(adapter);
      store.upsertSessionForTesting(_session('s1'));

      store.onEventForTesting(_metaEvent('s1', {'archivedAt': 300}));
      expect(store.sessionById('s1'), isNull);
      expect(adapter.calls, 0);

      store.onEventForTesting(_metaEvent('s1', {'other': 'v'}));
      var notifies = 0;
      store.addListener(() => notifies++);
      await pumpEventQueue();
      expect(store.sessionById('s1'), isNotNull);
      expect(adapter.calls, 1);
      expect(notifies, 1);
    },
  );

  test('unarchive refetch failure is swallowed', () async {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('s1'));
    store.onEventForTesting(_metaEvent('s1', {'archivedAt': 300}));
    store.onEventForTesting(_metaEvent('s1', {'other': 'v'}));
    await pumpEventQueue();
    expect(store.sessionById('s1'), isNull);
  });

  test('unknown archived session is ignored without refetch', () {
    final adapter = _SessionsAdapter('{}');
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    store.onEventForTesting(_metaEvent('ghost', {'archivedAt': 300}));
    expect(store.sessionById('ghost'), isNull);
    expect(adapter.calls, 0);
  });

  test('session.metadata.updated archives child sessions', () {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('parent'));
    store.upsertSessionForTesting(_session('child', parentID: 'parent'));
    expect(store.isChildSession('child'), isTrue);

    store.onEventForTesting(_metaEvent('child', {'archivedAt': 300}));
    expect(store.isChildSession('child'), isFalse);
  });
}
