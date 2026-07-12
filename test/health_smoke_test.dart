import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/core/connection/connection_profile.dart';
import 'package:opencode_mobile/core/net/dio_factory.dart';
import 'package:opencode_mobile/data/api/opencode_client.dart';

/// Hits the real local opencode server (plan.md §8). Skips if unreachable.
void main() {
  test('health() reaches localhost:15120 (opencode / empty password)', () async {
    final profile = ConnectionProfile(
      id: 't',
      name: 'test',
      address: 'http://localhost:15120',
      username: 'opencode',
      password: '',
    );
    final HealthInfo h;
    try {
      h = await OpencodeClient(dioFor(profile)).health();
    } catch (e) {
      // CI / non-dev machines won't have the local server; skip gracefully.
      printOnFailure('server not reachable: $e');
      return;
    }
    expect(h.healthy, true);
    expect(h.version, isNotEmpty);
    printOnFailure('opencode ${h.version}');
  });
}
