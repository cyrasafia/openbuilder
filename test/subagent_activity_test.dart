import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/connection/connection_profile.dart';
import 'package:open_builder/core/net/dio_factory.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

/// design-subagent-background：主会话运行状态是**家族聚合**——
/// 子会话（含更深后代）进行中时，父会话 `sessionActivity` 为 busy/retry。
OpencodeClient _fakeClient() => OpencodeClient(dioFor(const ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://127.0.0.1:9',
      username: 'opencode',
      password: '',
    )));

SessionModel _session(String id, {String? parentID}) => SessionModel(
      id: id,
      projectID: 'p',
      directory: '/repo',
      title: id,
      created: 1,
      updated: 1,
      parentID: parentID,
    );

OpencodeEvent _exec(String type, String sessionID) => OpencodeEvent(
      type: type,
      properties: {'sessionID': sessionID},
    );

void main() {
  test('child running bubbles up to the parent; settle returns to idle', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('par'));
    store.upsertSessionForTesting(_session('kid', parentID: 'par'));

    expect(store.sessionActivity('par').type, 'idle');
    expect(store.statusOf('par').type, 'idle',
        reason: 'the parent itself is idle; aggregation only affects sessionActivity');

    store.onEventForTesting(_exec('session.execution.started', 'kid'));
    expect(store.sessionActivity('par').type, 'busy',
        reason: 'child running ⇒ parent shows running');
    expect(store.sessionActivity('kid').type, 'busy');

    store.onEventForTesting(_exec('session.execution.succeeded', 'kid'));
    expect(store.sessionActivity('par').type, 'idle');
  });

  test('deeper descendant (depth > 1) bubbles up to the root', () {
    final store = ServerStore()..client = _fakeClient();
    store.upsertSessionForTesting(_session('root'));
    store.upsertSessionForTesting(_session('kid', parentID: 'root'));
    store.upsertSessionForTesting(_session('grand', parentID: 'kid'));

    store.onEventForTesting(_exec('session.execution.started', 'grand'));
    expect(store.sessionActivity('root').type, 'busy');
    expect(store.sessionActivity('kid').type, 'busy');
    expect(store.sessionActivity('grand').type, 'busy');
  });
}
