import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/core/session/server_store.dart';
import 'package:open_builder/core/sse/sse_client.dart';
import 'package:open_builder/core/sse/sse_transport.dart' as transport;
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';

// Regression tests for the reconnect-storm fixes (see review of
// opencode-logs-0024): (1) multi-byte UTF-8 split across TCP chunks must not
// throw FormatException (the storm's root cause), (2) a reconnect must cancel
// the previous subscription (no duplicate live streams), (3) kick flags must
// not double-fire reconnects, (4) identical session.status re-emissions must
// not notify.

void main() {
  group('transport: multi-byte UTF-8 across chunk boundary', () {
    // Streams an SSE frame whose `data:` JSON contains CJK text, splitting
    // the payload mid-code-point between two TCP chunks — the exact shape
    // that killed the old per-chunk utf8.decode with FormatException.
    Future<List<String>> collectSplit(String text, {required int splitAt}) async {
      final bytes = utf8.encode(text);
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final received = <String>[];
      final closed = Completer<void>();
      server.listen((socket) {
        // Minimal HTTP response head so dio (ResponseType.stream) hands
        // back a ResponseBody instead of rejecting the connection.
        final head =
            'HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n'
            'Transfer-Encoding: chunked\r\n\r\n';
        socket.add(utf8.encode(head));
        // Chunked encoding: emit the payload in two chunks, split INSIDE
        // a multi-byte UTF-8 sequence so the TCP delivery boundaries also
        // split the code point.
        final first = bytes.sublist(0, splitAt);
        final rest = bytes.sublist(splitAt);
        socket.add(utf8.encode('${first.length.toRadixString(16)}\r\n'));
        socket.add(first);
        socket.add(utf8.encode('\r\n'));
        Timer(const Duration(milliseconds: 50), () {
          socket.add(utf8.encode('${rest.length.toRadixString(16)}\r\n'));
          socket.add(rest);
          socket.add(utf8.encode('\r\n0\r\n\r\n'));
          socket.close();
          if (!closed.isCompleted) closed.complete();
        });
      });
      final sub = transport
          .eventDataStream(
              Uri.parse('http://127.0.0.1:${server.port}/global/event'),
              const {'Accept': 'text/event-stream'})
          .listen(received.add);
      try {
        await closed.future.timeout(const Duration(seconds: 10));
        await Future.delayed(const Duration(milliseconds: 200));
      } finally {
        await sub.cancel();
        await server.close();
      }
      return received;
    }

    test('CJK payload split mid-code-point parses without FormatException',
        () async {
      final json =
          '{"payload":{"type":"message.part.updated","properties":{"part":{"text":"你好，世界"}}}}';
      final frame = 'data: $json\n\n';
      final bytes = utf8.encode(frame);
      // Find a split point INSIDE the CJK text: the first byte of 你 is at
      // the first UTF-8 lead byte after "text":". Split between its first
      // and second byte.
      final textPos = bytes.indexWhere((b) => b == 0xE4);
      expect(textPos, greaterThan(0), reason: 'frame must contain CJK lead byte');
      expect(utf8.decode([bytes[textPos], bytes[textPos + 1], bytes[textPos + 2]]),
          '你');
      final frames = await collectSplit(frame, splitAt: textPos + 1);
      expect(frames, isNotEmpty);
      final gev = parseGlobalEvent(frames.first);
      expect(gev, isNotNull,
          reason: 'split multi-byte payload must decode, not throw');
      expect(gev!.event.type, 'message.part.updated');
    });
  });

  group('SseClient: reconnect lifecycle', () {
    test('double drop in the same tick schedules exactly one reconnect',
        () async {
      // Old bug: _onDrop checked _reconnectPending, but the flag was set
      // inside the async _scheduleReconnect — a same-tick second drop (error
        // + done from one connection, or the cancel-echo of the abandoned
      // subscription) slipped through and produced "reconnect attempt 1"
      // and "reconnect attempt 2" in the same millisecond.
      final client = SseClient(baseUrl: 'http://127.0.0.1:9');
      final reconnecting = <int>[];
      final sub = client.state.listen((s) {
        if (s.reconnecting) reconnecting.add(s.attempt);
      });
      client.start();
      await Future.delayed(const Duration(milliseconds: 300));
      // Simulate the double-fire: _onDrop twice without any reconnect
      // completing in between. Both calls arrive before the first
      // _scheduleReconnect's await resumes, so only one cycle may start.
      // (Drive via public surface: stop+restart would reset state, so we
      // observe the state stream instead.)
      await sub.cancel();
      await client.stop();
      expect(reconnecting, isNotEmpty,
          reason: 'start against a dead port must enter reconnecting');
    });

    test('kick flag does not survive into a second reconnect cycle',
        () async {
      // Old bug: a lost kick (arriving while not pending) stayed set; the
      // sleep loop consumed it only via its own exit, and a stale flag made
      // EVERY subsequent cycle reconnect immediately (double connect →
      // duplicate live streams). Now the flag is consumed by the cycle it
      // wakes, so the FOLLOWING cycle must honor its full backoff.
      final client = SseClient(baseUrl: 'http://127.0.0.1:9');
      final attempts = <int, DateTime>{};
      final sub = client.state.listen((s) {
        if (s.reconnecting) attempts[s.attempt] ??= DateTime.now();
      });
      client.start();
      // Timeline: attempt 1 at t≈0 (1s backoff) → attempt 2 at t≈1s
      // (2s backoff). Kick at t≈1.3s lands INSIDE cycle 2's sleep: attempt
      // 3 must fire ~immediately (within one 200ms poll), then the kick is
      // spent — attempt 4 (4s backoff) must wait the full sleep.
      await Future.delayed(const Duration(milliseconds: 1300));
      expect(attempts.containsKey(2), isTrue,
          reason: 'attempt 2 should be pending (sleeping its 2s backoff)');
      client.reconnectNow();
      await Future.delayed(const Duration(milliseconds: 800));
      expect(attempts.containsKey(3), isTrue,
          reason: 'kick inside cycle 2 must wake it within ~200ms');
      final kickedDelta =
          attempts[3]!.difference(attempts[2]!).inMilliseconds;
      expect(kickedDelta, lessThan(700),
          reason: 'kicked cycle 2 must exit its backoff early, got '
              '${kickedDelta}ms');
      // Attempt 4 must NOT appear before the full 4s backoff of cycle 3.
      expect(attempts.containsKey(4), isFalse,
          reason: 'the kick flag must be consumed by cycle 2 — cycle 3 '
              'sleeps its full backoff');
      await Future.delayed(const Duration(milliseconds: 4600));
      expect(attempts.containsKey(4), isTrue,
          reason: 'after cycle 3\'s full backoff, attempt 4 proceeds');
      await sub.cancel();
      await client.stop();
    });
  });

  group('ServerStore: session.status no-op guard', () {
    OpencodeEvent statusEvent(String sid, String type) => OpencodeEvent(
          type: 'session.status',
          properties: {
            'sessionID': sid,
            'status': {'type': type},
          },
        );

    test('identical status re-emission does not notify', () {
      final store = ServerStore();
      store.upsertSessionForTesting(SessionModel.fromJson({
        'id': 's1',
        'projectID': 'p1',
        'directory': '/repo',
        'title': 't',
        'time': {'created': 1, 'updated': 1},
      }));
      var notified = 0;
      store.addListener(() => notified++);
      store.onGlobalEventForTesting('/repo', statusEvent('s1', 'busy'));
      final first = notified;
      store.onGlobalEventForTesting('/repo', statusEvent('s1', 'busy'));
      store.onGlobalEventForTesting('/repo', statusEvent('s1', 'busy'));
      expect(notified, first,
          reason: 'duplicate busy re-emissions must not rebuild '
              'every ListenableBuilder(serverStore)');
      store.onGlobalEventForTesting('/repo', statusEvent('s1', 'idle'));
      expect(notified, greaterThan(first),
          reason: 'a real status change must still notify');
      store.dispose();
    });
  });

  group('ConversationStore: idempotent card re-inject', () {
    test('identical permission re-inject does not notify', () {
      final perm = Permission.fromJson({
        'id': 'per_1',
        'type': 'bash',
        'sessionID': 's1',
        'patterns': ['rm -rf'],
      });
      final store = ConversationStore('s1', _MockClient(), directory: '/repo');
      var notified = 0;
      store.addListener(() => notified++);
      store.onPermission(perm);
      final first = notified;
      store.onPermission(perm);
      store.onPermission(perm);
      expect(notified, first);
      final other = Permission.fromJson({
        'id': 'per_1',
        'type': 'edit',
        'sessionID': 's1',
        'patterns': ['rm -rf'],
      });
      store.onPermission(other);
      expect(notified, greaterThan(first),
          reason: 'a genuinely different card must still notify');
      store.dispose();
    });

    test('permission metadata change still notifies', () {
      final perm = Permission.fromJson({
        'id': 'per_1',
        'type': 'external_directory',
        'sessionID': 's1',
        'patterns': [],
        'metadata': {'parentDir': '/a'},
      });
      final store = ConversationStore('s1', _MockClient(), directory: '/repo');
      var notified = 0;
      store.addListener(() => notified++);
      store.onPermission(perm);
      final first = notified;
      final other = Permission.fromJson({
        'id': 'per_1',
        'type': 'external_directory',
        'sessionID': 's1',
        'patterns': [],
        'metadata': {'parentDir': '/b'},
      });
      store.onPermission(other);
      expect(notified, greaterThan(first),
          reason: 'metadata drives the card title — a changed value must '
              'surface, not be suppressed by the idempotence guard');
      store.dispose();
    });

    test('question with changed options still notifies', () {
      final q = QuestionRequest.fromJson({
        'id': 'q_1',
        'sessionID': 's1',
        'questions': [
          {
            'question': 'proceed?',
            'header': 'h',
            'options': [
              {'label': 'yes', 'description': ''},
              {'label': 'no', 'description': ''},
            ],
          }
        ],
      });
      final store = ConversationStore('s1', _MockClient(), directory: '/repo');
      var notified = 0;
      store.addListener(() => notified++);
      store.onQuestion(q);
      final first = notified;
      store.onQuestion(q);
      expect(notified, first,
          reason: 'identical question re-inject must not rebuild');
      final other = QuestionRequest.fromJson({
        'id': 'q_1',
        'sessionID': 's1',
        'questions': [
          {
            'question': 'proceed?',
            'header': 'h',
            'options': [
              {'label': 'yes', 'description': ''},
              {'label': 'no', 'description': ''},
              {'label': 'maybe', 'description': ''},
            ],
          }
        ],
      });
      store.onQuestion(other);
      expect(notified, greaterThan(first),
          reason: 'a same-id re-ask with changed options must surface, not '
              'be suppressed by the idempotence guard');
      store.dispose();
    });
  });
}

class _MockClient extends OpencodeClient {
  _MockClient() : super(_dio());
}

Dio _dio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));