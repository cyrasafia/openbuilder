import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/net/net_error.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// Archive recognition stays dual-source during the legacy transition: the
// official `time.archived` (written by PATCH {archived:true/false} since
// 2.1.3) plus the retired cross-client private contract
// `metadata.archivedAt` (openbuilder-desktop D1). Writes go official-only;
// a reconcile backfill promotes marker-only sessions (convert + clear the
// private key) so the marker set drains to empty.

class _SessionsAdapter implements HttpClientAdapter {
  final String body;
  int calls = 0;
  final List<String> queries = [];
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
    queries.add(options.uri.query);
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

OpencodeEvent _archiveEvent(String sid, {int? created}) => OpencodeEvent(
      type: 'session.archived',
      properties: {'sessionID': sid},
      created: created,
    );

OpencodeEvent _unarchiveEvent(String sid) => OpencodeEvent(
      type: 'session.unarchived',
      properties: {'sessionID': sid},
    );

class _ArchiveAdapter implements HttpClientAdapter {
  final String getBody;
  final String serverVersion;
  final patches = <Map<String, dynamic>>[];
  int getCalls = 0;
  int infoCalls = 0;
  _ArchiveAdapter(this.getBody, {this.serverVersion = '2.1.3'});

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      if (options.path == '/api/info') {
        infoCalls++;
        return _json('{"version":"$serverVersion","healthy":true}');
      }
      getCalls++;
      return _json(getBody);
    }
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    patches.add(
      (jsonDecode(utf8.decode(bytes)) as Map).cast<String, dynamic>(),
    );
    return _json('{}');
  }

  static ResponseBody _json(String body) => ResponseBody.fromString(
        body,
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
}

class _FailingGetAdapter implements HttpClientAdapter {
  final patches = <Map<String, dynamic>>[];
  int getCalls = 0;
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      if (options.path == '/api/info') {
        return _ArchiveAdapter._json('{"version":"2.1.3","healthy":true}');
      }
      getCalls++;
      throw DioException(requestOptions: RequestOptions(path: options.path));
    }
    patches.add(const {});
    return _ArchiveAdapter._json('{}');
  }
}

class _StalledPromoteAdapter implements HttpClientAdapter {
  final gate = Completer<void>();
  int promoteStarts = 0;
  int infoCalls = 0;
  bool failInfo;
  _StalledPromoteAdapter({this.failInfo = false});
  @override
  void close({bool force = false}) {}
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'GET') {
      if (options.path == '/api/info') {
        infoCalls++;
        if (failInfo) {
          throw DioException(requestOptions: RequestOptions(path: options.path));
        }
        return _ArchiveAdapter._json('{"version":"2.1.3","healthy":true}');
      }
      promoteStarts++;
      await gate.future;
      return _ArchiveAdapter._json('{}');
    }
    patches.add(const {});
    return _ArchiveAdapter._json('{}');
  }

  final patches = <Map<String, dynamic>>[];
}

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

  test('withArchived sets and clears the official flag explicitly', () {
    final s = _session('s1');
    final archived = s.withArchived(300);
    expect(archived.archived, 300);
    expect(archived.isArchived, isTrue);

    final restored = archived.withArchived(null);
    expect(restored.archived, isNull);
    expect(restored.isArchived, isFalse);
    expect(SessionModel.fromJson(restored.toJson()).isArchived, isFalse);
  });

  test('sessions() filters both archive sources by default', () async {
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

  test('sessions() sends archived param and keeps marker-only rows when asked',
      () async {
    final adapter = _SessionsAdapter(
      '{"data":['
      '{"id":"s1","time":{"updated":1}},'
      '{"id":"s3","time":{"updated":1},"metadata":{"archivedAt":200}}'
      ']}',
    );
    final client = OpencodeClient(
      Dio(BaseOptions(baseUrl: 'http://test'))..httpClientAdapter = adapter,
    );
    final list = await client.sessions(archived: false, filterArchived: false);
    expect(list.map((s) => s.id).toList(), ['s1', 's3']);
    expect(adapter.queries.single, contains('archived=false'));
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

  test('session.archived event removes in place without refetch', () async {
    final adapter = _SessionsAdapter('{}');
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    store.upsertSessionForTesting(_session('s1'));

    store.onEventForTesting(_archiveEvent('s1', created: 300));
    await pumpEventQueue();
    expect(store.sessionById('s1'), isNull);
    expect(adapter.calls, 0);
  });

  test('session.archived event archives child sessions', () {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('parent'));
    store.upsertSessionForTesting(_session('child', parentID: 'parent'));

    store.onEventForTesting(_archiveEvent('child', created: 300));
    expect(store.isChildSession('child'), isFalse);
  });

  test('unknown session.archived event is ignored without refetch', () async {
    final adapter = _SessionsAdapter('{}');
    final store = ServerStore()..client = _clientWithAdapter(adapter);

    store.onEventForTesting(_archiveEvent('ghost', created: 300));
    await pumpEventQueue();
    expect(store.sessionById('ghost'), isNull);
    expect(adapter.calls, 0);
  });

  test('session.unarchived event restores removed session via refetch',
      () async {
    final adapter = _SessionsAdapter(
      '{"data":{"id":"s1","projectID":"p1",'
      '"location":{"directory":"/dirA"},"title":"t",'
      '"time":{"updated":1000}}}',
    );
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    store.upsertSessionForTesting(_session('s1'));
    store.onEventForTesting(_archiveEvent('s1', created: 300));
    expect(store.sessionById('s1'), isNull);

    store.onEventForTesting(_unarchiveEvent('s1'));
    await pumpEventQueue();
    expect(store.sessionById('s1'), isNotNull);
    expect(adapter.calls, 1);
  });

  test('session.unarchived event clears stale flags on known session', () {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('s1'));

    store.onEventForTesting(_unarchiveEvent('s1'));
    expect(store.sessionById('s1'), isNotNull);
  });

  test('archiveSession patches the official archived boolean', () async {
    final adapter = _ArchiveAdapter('{}');
    final client = _clientWithAdapter(adapter);
    await client.archiveSession('s1');
    expect(adapter.getCalls, 0);
    expect(adapter.patches, [
      {'archived': true}
    ]);
  });

  test('archiveSession applies flag locally, SSE echo is no-op', () async {
    final adapter = _ArchiveAdapter('{}');
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    store.upsertSessionForTesting(_session('s1'));
    var notifies = 0;
    store.addListener(() => notifies++);

    await store.archiveSession('s1');

    expect(store.sessionById('s1'), isNull);
    expect(notifies, 1);
    expect(adapter.getCalls, 0);
    expect(adapter.patches, hasLength(1));

    store.onEventForTesting(_archiveEvent('s1', created: 999));
    await pumpEventQueue();
    expect(store.sessionById('s1'), isNull);
    expect(adapter.getCalls, 0);
  });

  test('archiveSession failure propagates as operation error', () async {
    final store = ServerStore()..client = _unreachableClient();
    store.upsertSessionForTesting(_session('s1'));
    await expectLater(
      store.archiveSession('s1'),
      throwsA(isA<OperationException>()),
    );
    expect(store.sessionById('s1'), isNotNull);
  });

  test('promoteLegacyArchive merges metadata minus archivedAt into one patch',
      () async {
    final adapter = _ArchiveAdapter(
      '{"data":{"id":"s1","metadata":{"customKey":"v","archivedAt":100}}}',
    );
    final client = _clientWithAdapter(adapter);
    await client.promoteLegacyArchive('s1');
    expect(adapter.getCalls, 1);
    expect(adapter.patches, [
      {
        'archived': true,
        'metadata': {'customKey': 'v'},
      }
    ]);
  });

  test('promoteLegacyArchive clears marker-only metadata', () async {
    final adapter = _ArchiveAdapter(
      '{"data":{"id":"s1","metadata":{"archivedAt":100}}}',
    );
    final client = _clientWithAdapter(adapter);
    await client.promoteLegacyArchive('s1');
    expect(adapter.patches, [
      {
        'archived': true,
        'metadata': {},
      }
    ]);
  });

  test('backfill promotes marker-only sessions and skips clean ones',
      () async {
    final adapter = _ArchiveAdapter('{}');
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    final markerOnly = SessionModel.fromJson({
      'id': 's1',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
      'metadata': {'archivedAt': 200},
    });
    final official = SessionModel.fromJson({
      'id': 's2',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000, 'archived': 100},
    });
    final clean = _session('s3');

    await store.backfillLegacyArchivesForTesting([markerOnly, official, clean]);

    expect(adapter.infoCalls, 1);
    expect(adapter.getCalls, 1);
    expect(adapter.patches, hasLength(1));
  });

  test('backfill skips servers without the official archive API', () async {
    final adapter = _ArchiveAdapter('{}', serverVersion: '2.0.18');
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    final markerOnly = SessionModel.fromJson({
      'id': 's1',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
      'metadata': {'archivedAt': 200},
    });

    await store.backfillLegacyArchivesForTesting([markerOnly]);
    await store.backfillLegacyArchivesForTesting([markerOnly]);

    expect(adapter.infoCalls, 1);
    expect(adapter.getCalls, 0);
    expect(adapter.patches, isEmpty);
  });

  test('backfill gate failure does not cache and retries next round',
      () async {
    final adapter = _StalledPromoteAdapter(failInfo: true);
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    final markerOnly = SessionModel.fromJson({
      'id': 's1',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
      'metadata': {'archivedAt': 200},
    });

    await store.backfillLegacyArchivesForTesting([markerOnly]);
    expect(adapter.infoCalls, 1);
    expect(adapter.promoteStarts, 0);

    adapter.failInfo = false;
    final second = store.backfillLegacyArchivesForTesting([markerOnly]);
    await pumpEventQueue();
    expect(adapter.infoCalls, 2);
    expect(adapter.promoteStarts, 1);
    adapter.gate.complete();
    await second;
    expect(adapter.patches, hasLength(1));
  });

  test('backfill concurrent run is deduped by the in-flight guard',
      () async {
    final adapter = _StalledPromoteAdapter();
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    final markerOnly = SessionModel.fromJson({
      'id': 's1',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
      'metadata': {'archivedAt': 200},
    });

    final first = store.backfillLegacyArchivesForTesting([markerOnly]);
    await pumpEventQueue();
    final second = store.backfillLegacyArchivesForTesting([markerOnly]);
    await second;
    expect(adapter.promoteStarts, 1);

    adapter.gate.complete();
    await first;
    expect(adapter.patches, hasLength(1));
  });

  test('backfill swallows promote failures and retries next round',
      () async {
    final adapter = _FailingGetAdapter();
    final store = ServerStore()..client = _clientWithAdapter(adapter);
    final markerOnly = SessionModel.fromJson({
      'id': 's1',
      'projectID': 'p1',
      'location': {'directory': '/dirA'},
      'title': 't',
      'time': {'updated': 1000},
      'metadata': {'archivedAt': 200},
    });

    await store.backfillLegacyArchivesForTesting([markerOnly]);
    expect(adapter.getCalls, 1);
    expect(adapter.patches, isEmpty);

    await store.backfillLegacyArchivesForTesting([markerOnly]);
    expect(adapter.getCalls, 2);
    expect(adapter.patches, isEmpty);
  });
}
