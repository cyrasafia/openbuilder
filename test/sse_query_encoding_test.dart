import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/sse/sse_client.dart';

// The opencode credential rides `?auth_token=<base64>` on the SSE stream
// while REST (dio) percent-encodes the same value with
// `Uri.encodeQueryComponent`. The server decodes the query in form style —
// literal `+` means space — so a `+` inside the base64 must go out as %2B
// on BOTH transports or the stream 401s forever (live-verified against
// v2.0.23: literal `+` → 401, `%2B` → 200; third review round).
void main() {
  test('auth_token with + is percent-encoded like the REST path', () {
    final cred = base64Encode(utf8.encode('opencode:密码>测试'));
    expect(cred.contains('+'), isTrue,
        reason: 'precondition: the sample credential must exercise +');

    final u = sseRequestUri(
      Uri.parse('http://x/api/event'),
      {'auth_token': cred},
    );

    expect(u.toString(),
        'http://x/api/event?auth_token=${Uri.encodeQueryComponent(cred)}',
        reason: 'byte-identical to what dio emits for the same value');
    expect(u.toString(), contains('%2B'));
  });

  test('empty query keeps the URI untouched; existing query is preserved',
      () {
    const base = 'http://x/api/event';
    expect(sseRequestUri(Uri.parse(base), const {}).toString(), base);
    expect(
      sseRequestUri(
        Uri.parse('$base?src=tail'),
        const {'auth_token': 'a%2Bb'},
      ).toString(),
      '$base?src=tail&auth_token=a%252Bb',
      reason: 'appended after any existing query; the value re-encodes as '
          'one component (never re-split on +)',
    );
  });
}
