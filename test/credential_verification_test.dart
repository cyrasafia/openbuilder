import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/connection/connection_store.dart';
import 'package:open_builder/features/servers/basic_auth_screen.dart';

class _RecordingAdapter implements HttpClientAdapter {
  final List<String> authHeaders = [];
  final List<String> uris = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    authHeaders.add(options.headers['Authorization']?.toString() ?? '');
    uris.add(options.uri.toString());
    return ResponseBody.fromString('{"version":"2.0.23"}', 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }
}

class _FakeStore extends ConnectionStore {
  final Map<String, ConnectionProfile> db = {};

  @override
  ConnectionProfile? byId(String id) => db[id];

  @override
  Future<void> update(ConnectionProfile p) async => db[p.id] = p;
}

void main() {
  // Review B2 regression: the gateway-mode "test & save" must verify the
  // password from the INPUT BOX. A live-store read replays the stale one
  // (empty during first add, previously-rejected during re-entry) and 401s
  // forever, deadlocking the two-step login and the password re-entry flow.
  test('credentialVerificationDio sends the draft password, not the store copy',
      () async {
    final store = _FakeStore();
    store.db['p1'] = ConnectionProfile(
      id: 'p1',
      name: 'n',
      address: 'http://api.test',
      authMethod: AuthMethod.oauth,
      username: 'opencode',
      password: 'stale-pw',
      accessToken: 'at-old',
      refreshToken: 'rt-old',
      tokenExpiresAt: DateTime.now().millisecondsSinceEpoch + 3600000,
      tokenEndpoint: 'http://authstub.test/token',
    );
    final draft = store.db['p1']!.copyWith(password: 'fresh-pw');
    final adapter = _RecordingAdapter();

    final dio = credentialVerificationDio(draft, store: store)
      ..httpClientAdapter = adapter;
    final resp = await dio.get<Object>('/api/info');

    expect(resp.statusCode, 200);
    expect(adapter.authHeaders.single, 'Bearer at-old',
        reason: 'the gateway token still rides the Authorization header');
    expect(
      Uri.parse(adapter.uris.single).queryParameters['auth_token'],
      base64Encode(utf8.encode('opencode:fresh-pw')),
      reason: 'verification must use the input-box password; the store copy '
          '(stale-pw) must never reach the wire here',
    );
  });
}
