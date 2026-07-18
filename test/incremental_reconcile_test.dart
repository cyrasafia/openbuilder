import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/conversation_store.dart';
import 'package:open_builder/data/api/opencode_client.dart';
import 'package:open_builder/domain/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tests for the incremental reconcile + segmented lazy-load design
/// (design-incremental-reconcile.md).
///
/// Covers: windowed reconcile, segment creation, gap bridging on scroll-up,
/// multi-gap scenarios, SSE extends segment, window-range deletion, cache
/// preheat (session.updated match/mismatch), and cursor exhaustion.

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('incremental reconcile', () {
    test('first reconcile creates single segment, hasMore from cursor', () async {
      final entries = _entries(1, 5); // m1..m5
      final client = _PageMockClient([
        _PageSpec(entries, 'cursor_after_m1'),
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      expect(conv.loaded, isTrue);
      expect(conv.messages.length, 5);
      expect(conv.renderableMessages.length, 5);
      expect(conv.hasMore, isTrue); // cursor present
    });

    test('second reconcile overlaps → merges, no gap', () async {
      final first = _entries(1, 5); // m1..m5
      final second = _entries(3, 7); // m3..m7 (overlaps m3..m5)
      final client = _PageMockClient([
        _PageSpec(first, 'c1'),
        _PageSpec(second, 'c3'),
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      await conv.reconcile();
      expect(conv.messages.length, 7); // m1..m7
      expect(conv.renderableMessages.length, 7); // single segment, all reachable
      expect(conv.hasMore, isTrue);
    });

    test('second reconcile no overlap → gap forms, old content unreachable',
        () async {
      final first = _entries(1, 5); // m1..m5
      final second = _entries(11, 15); // m11..m15 (no overlap)
      final client = _PageMockClient([
        _PageSpec(first, null), // m1..m5 complete initially
        _PageSpec(second, 'c11'), // m11..m15, more older exists
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      await conv.reconcile();
      expect(conv.messages.length, 10); // m1..m5 + m11..m15
      // Only the bottom segment (m11..m15) is reachable:
      expect(conv.renderableMessages.length, 5);
      expect(conv.renderableMessages.first.info.id, 'm15');
      expect(conv.renderableMessages.last.info.id, 'm11');
    });

    test('loadOnePage bridges gap to older segment', () async {
      final first = _entries(1, 5); // m1..m5
      final second = _entries(11, 15); // m11..m15 (gap)
      // loadOnePage pages backward from c11: m6..m10, then m1..m5 (overlap)
      final bridge = _entries(6, 10); // m6..m10
      final client = _PageMockClient([
        _PageSpec(first, null), // m1..m5 complete initially
        _PageSpec(second, 'c11'), // m11..m15, more older
        _PageSpec(bridge, 'c6'), // first backward page: m6..m10
        _PageSpec(first, null), // second backward page: m1..m5, overlaps, no more
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      await conv.reconcile();
      expect(conv.renderableMessages.length, 5); // only m11..m15
      // First backward page: m6..m10, no overlap yet
      await conv.loadOnePage();
      expect(conv.renderableMessages.length, 10); // m6..m15
      expect(conv.hasMore, isTrue); // c6 cursor still present
      // Second backward page: m1..m5, overlaps older segment → bridge
      await conv.loadOnePage();
      expect(conv.renderableMessages.length, 15); // m1..m15 all reachable
      expect(conv.hasMore, isFalse); // cursor exhausted
    });

    test('multiple gaps (T0→T1→T2) bridge sequentially', () async {
      final seg0 = _entries(1, 5); // m1..m5
      final seg1 = _entries(11, 15); // m11..m15
      final seg2 = _entries(21, 25); // m21..m25
      final client = _PageMockClient([
        _PageSpec(seg0, null), // m1..m5 complete initially
        _PageSpec(seg1, 'c11'), // m11..m15, more older
        _PageSpec(seg2, 'c21'), // m21..m25, more older
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile(); // m1..m5
      await conv.reconcile(); // m11..m15 (gap1)
      await conv.reconcile(); // m21..m25 (gap2)
      expect(conv.messages.length, 15);
      expect(conv.renderableMessages.length, 5); // only m21..m25
      // Bridge gap2: need pages m16..m20, then m11..m15 (overlap)
      client.addPages([
        _PageSpec(_entries(16, 20), 'c16'),
        _PageSpec(seg1, 'c11'),
      ]);
      await conv.loadOnePage(); // m16..m20
      expect(conv.renderableMessages.length, 10);
      await conv.loadOnePage(); // m11..m15 overlap → bridge gap2
      expect(conv.renderableMessages.length, 15); // m11..m25
      // Bridge gap1: need pages m6..m10, then m1..m5 (overlap)
      client.addPages([
        _PageSpec(_entries(6, 10), 'c6'),
        _PageSpec(seg0, null),
      ]);
      await conv.loadOnePage(); // m6..m10
      await conv.loadOnePage(); // m1..m5 overlap → bridge gap1
      expect(conv.renderableMessages.length, 25); // m1..m25
      expect(conv.hasMore, isFalse);
    });

    test('SSE message extends bottom segment (renderable)', () async {
      final entries = _entries(1, 3);
      final client = _PageMockClient([_PageSpec(entries, 'c1')]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      // SSE delivers a new message
      conv.onMessageUpdated(MessageInfo(id: 'm_new', role: 'assistant', created: 400));
      conv.onPartUpdated(
        <String, dynamic>{'messageID': 'm_new', 'id': 'p_new', 'type': 'text'},
        'streamed',
      );
      expect(conv.renderableMessages.length, 4);
      expect(conv.renderableMessages.first.info.id, 'm_new');
    });

    test('window-range deletion removes reverted message', () async {
      // Local has m1..m5. Server reverted m3 (deleted).
      // Reconcile window returns m1,m2,m4,m5 (m3 missing).
      final client = _PageMockClient([
        _PageSpec(_entries(1, 5), null), // initial: m1..m5 complete
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      expect(conv.messages.any((m) => m.info.id == 'm3'), isTrue);
      // Second reconcile: window has m1,m2,m4,m5 (m3 deleted server-side)
      client.addPages([
        _PageSpec([
          ..._entries(1, 2),
          ..._entries(4, 5),
        ], null),
      ]);
      await conv.reconcile();
      expect(conv.messages.any((m) => m.info.id == 'm3'), isFalse);
      expect(conv.messages.length, 4);
    });

    test('cache preheat when session.updated matches', () async {
      final entries = _entries(1, 3);
      final client = _PageMockClient([_PageSpec(entries, null)]);
      final conv = ConversationStore('s1', client);
      conv.sessionUpdated = 42;
      // Save cache
      await conv.reconcile();
      expect(conv.loaded, isTrue);
      // Simulate restart: new conv, same sessionUpdated
      final conv2 = ConversationStore('s1', client);
      conv2.sessionUpdated = 42;
      client.addPages([_PageSpec(entries, null)]); // reconcile re-fetches
      await conv2.load();
      // Preheat should have restored messages instantly
      expect(conv2.loaded, isTrue);
      expect(conv2.messages.length, 3);
    });

    test('cache preheat skipped when session.updated differs', () async {
      final entries = _entries(1, 3);
      final client = _PageMockClient([_PageSpec(entries, null)]);
      final conv = ConversationStore('s1', client);
      conv.sessionUpdated = 42;
      await conv.reconcile();
      // Restart with different sessionUpdated (new messages arrived)
      final conv2 = ConversationStore('s1', client);
      conv2.sessionUpdated = 99; // mismatch
      client.addPages([_PageSpec(entries, null)]);
      await conv2.load();
      // Preheat skipped; reconcile still loads
      expect(conv2.loaded, isTrue);
      expect(conv2.messages.length, 3);
    });

    test('loadOnePage is reentrant-safe (no double fetch)', () async {
      final entries = _entries(1, 5);
      final client = _PageMockClient([
        _PageSpec(entries, 'c1'),
        _PageSpec(_entries(6, 10), null),
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      // Fire two loadOnePage concurrently — only one should execute
      final f1 = conv.loadOnePage();
      final f2 = conv.loadOnePage();
      await Future.wait([f1, f2]);
      expect(conv.loadingEarlier, isFalse);
    });

    // IR-5(1): old server degradation — full list + null cursor → single
    // segment, hasMore=false, all messages reachable.
    test('old server degradation: full list + no cursor → single segment', () async {
      final entries = _entries(1, 10);
      final client = _DegradationMockClient(entries);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      expect(conv.loaded, isTrue);
      expect(conv.hasMore, isFalse);
      expect(conv.messages.length, 10);
      expect(conv.renderableMessages.length, 10);
    });

    // IR-5(3) + IR-1: loadOnePage returns false on failure — caller can
    // detect and stop the chain (no request storm).
    test('loadOnePage returns false on failure (IR-1 storm prevention)', () async {
      final entries = _entries(1, 5);
      final client = _PageMockClient([
        _PageSpec(entries, 'c1'),
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      // Make messagesPage throw on next call
      client.failNext = true;
      final ok = await conv.loadOnePage();
      expect(ok, isFalse); // failure reported
      expect(conv.hasMore, isTrue); // cursor unchanged
      expect(conv.loadingEarlier, isFalse);
    });

    // IR-7: preheat makes content visible even when reconcile then fails —
    // proves preheat ran BEFORE reconcile.
    test('cache preheat content visible even when reconcile fails (IR-7)', () async {
      final entries = _entries(1, 3);
      final client = _PageMockClient([_PageSpec(entries, null)]);
      final conv = ConversationStore('s1', client);
      conv.sessionUpdated = 42;
      await conv.reconcile(); // save cache
      // IR-R3: explicitly drain the unawaited _saveCache microtask so the
      // test doesn't depend on implicit microtask scheduling order.
      await Future.delayed(Duration.zero);
      // New conv: sessionUpdated matches → preheat, then reconcile fails
      final failClient = _AlwaysFailMockClient();
      final conv2 = ConversationStore('s1', failClient);
      conv2.sessionUpdated = 42; // match → preheat
      await conv2.load();
      expect(conv2.loaded, isTrue);
      expect(conv2.messages.length, 3); // preheated content visible
      expect(conv2.error, isNotNull); // reconcile failed
    });

    // IR-5(4): old cache schema (no segments/cachedSessionUpdated) reads OK.
    test('old cache schema (no segments field) degrades gracefully', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      // Write a legacy cache (no 'segments' / 'cachedSessionUpdated')
      await prefs.setString('conv_s1', jsonEncode({
        'messages': [
          {
            'info': MessageInfo(id: 'old1', role: 'user', created: 100).toJson(),
            'parts': [],
          },
        ],
        'todos': [],
      }));
      final client = _PageMockClient([_PageSpec(_entries(1, 3), null)]);
      final conv = ConversationStore('s1', client);
      // Don't set sessionUpdated → preheat skipped (null != null)
      await conv.load();
      // Reconcile loaded fresh data; old cache didn't crash
      expect(conv.loaded, isTrue);
      expect(conv.messages.length, 3);
    });

    // IR-R1: multi-gap cross-page regression. Three segments with small
    // gaps; a single backward page spanning two gaps should merge all
    // three into one (IR-R2 orphan cleanup).
    test('backward page spanning two gaps merges all segments (IR-R1/R2)',
        () async {
      // Create 3 segments via 3 reconciles with no overlap.
      // seg2: m21..m25, seg1: m11..m15, seg0: m1..m5
      // Gaps: m6..m10, m16..m20
      final client = _PageMockClient([
        _PageSpec(_entries(1, 5), null), // reconcile #1
        _PageSpec(_entries(11, 15), 'c11'), // reconcile #2
        _PageSpec(_entries(21, 25), 'c21'), // reconcile #3
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile(); // m1..m5
      await conv.reconcile(); // m11..m15 (gap1: m6..m10)
      await conv.reconcile(); // m21..m25 (gap2: m16..m20)
      expect(conv.renderableMessages.length, 5); // only m21..m25 reachable
      // Backward page from c21 returns m1..m20 (everything below m21),
      // spanning both gaps AND both older segments.
      client.addPages([
        _PageSpec(
            [..._entries(1, 20)], // m1..m20: fills gap2 + seg1 + gap1
            'c1'),
      ]);
      final ok = await conv.loadOnePage();
      expect(ok, isTrue);
      // All messages now reachable in one segment.
      expect(conv.renderableMessages.length, 25);
      expect(conv.hasMore, isTrue); // c1 cursor from the page
    });

    // IR-R4: loadOnePage failure sets loadEarlierError.
    test('loadOnePage failure sets loadEarlierError flag (IR-R4)', () async {
      final client = _PageMockClient([
        _PageSpec(_entries(1, 5), 'c1'),
      ]);
      final conv = ConversationStore('s1', client);
      await conv.reconcile();
      expect(conv.loadEarlierError, isFalse);
      client.failNext = true;
      await conv.loadOnePage();
      expect(conv.loadEarlierError, isTrue);
      // Next successful load clears the error.
      client.addPages([_PageSpec(_entries(6, 10), null)]);
      await conv.loadOnePage();
      expect(conv.loadEarlierError, isFalse);
    });
  });
}

/// Build a list of MessageEntry with ids m{from}..m{to}, created = from*100..to*100.
List<MessageEntry> _entries(int from, int to) {
  final result = <MessageEntry>[];
  for (var i = from; i <= to; i++) {
    result.add(MessageEntry(
      info: MessageInfo(
        id: 'm$i',
        role: i % 2 == 0 ? 'assistant' : 'user',
        created: i * 100,
        finish: i % 2 == 0 ? 'stop' : null,
      ),
      parts: [MessagePart({'type': 'text', 'id': 'p$i', 'text': 'msg $i'})],
    ));
  }
  return result;
}

/// A single page's mock response.
class _PageSpec {
  final List<MessageEntry> entries;
  final String? nextCursor;
  _PageSpec(this.entries, this.nextCursor);
}

/// Mock client that returns queued [_PageSpec]s for successive `messagesPage`
/// calls. Each call dequeues the next spec. Use [addPages] to append more.
/// Set [failNext] to make the next `messagesPage` throw (for IR-1 test).
class _PageMockClient extends OpencodeClient {
  final List<_PageSpec> _pages = [];
  bool failNext = false;

  _PageMockClient(List<_PageSpec> initial) : super(_noopDio()) {
    _pages.addAll(initial);
  }

  void addPages(List<_PageSpec> pages) => _pages.addAll(pages);

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? before}) async {
    if (failNext) {
      failNext = false;
      throw Exception('simulated network failure');
    }
    if (_pages.isEmpty) return MessagesPage(const [], null);
    final spec = _pages.removeAt(0);
    return MessagesPage(spec.entries, spec.nextCursor);
  }

  @override
  Future<List<MessageEntry>> messages(String sessionId, {int? limit}) async {
    if (_pages.isEmpty) return const [];
    return _pages.first.entries;
  }

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

/// Simulates an old server that ignores `limit` and returns the full list
/// with no cursor (degradation path).
class _DegradationMockClient extends OpencodeClient {
  final List<MessageEntry> all;
  _DegradationMockClient(this.all) : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? before}) async {
    return MessagesPage(all, null); // full list, no cursor
  }

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

/// Always throws on messagesPage — used to test preheat-then-fail (IR-7).
class _AlwaysFailMockClient extends OpencodeClient {
  _AlwaysFailMockClient() : super(_noopDio());

  @override
  Future<MessagesPage> messagesPage(String sessionId,
      {required int limit, String? before}) async {
    throw Exception('network error');
  }

  @override
  Future<List<Todo>> todos(String sessionId) async => [];
}

Dio _noopDio() => Dio(BaseOptions(
      connectTimeout: const Duration(milliseconds: 1),
      receiveTimeout: const Duration(milliseconds: 1),
    ));
