import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/session/file_browsing_store.dart';
import 'package:open_builder/domain/models.dart';

OpenFileEntry entry(String path, {double offset = 0}) => OpenFileEntry(
  path: path,
  scrollOffset: offset,
  wrap: false,
  showSource: false,
);

void main() {
  group('collapse protocol', () {
    test('full chain seals snapshot with front-inserted openFiles order', () {
      final s = FileBrowsingStore();
      // stack: list -> f1 -> f2 -> f3 (f3 top); collapse tapped on f3.
      s.beginCollapse('s1', '/dir');
      s.collectFile('s1', '/dir', entry('f3', offset: 300));
      s.collectFile('s1', '/dir', entry('f2', offset: 200));
      s.collectFile('s1', '/dir', entry('f1', offset: 100));
      s.collectList(
        's1',
        '/dir',
        path: 'a/b',
        scrollOffset: 42,
        searchQuery: 'foo',
        searchExpanded: true,
      );
      expect(s.isCollapsing('s1', '/dir'), isFalse);

      final snap = s.snapshotFor('s1', '/dir')!;
      expect(snap.listPath, 'a/b');
      expect(snap.listScrollOffset, 42);
      expect(snap.searchQuery, 'foo');
      expect(snap.searchExpanded, isTrue);
      expect(snap.openFiles.map((e) => e.path).toList(), ['f1', 'f2', 'f3']);
      expect(snap.openFiles.last.scrollOffset, 300);
    });

    test(
      'openFiles capped at maxOpenFiles, dropping oldest (deepest) layer',
      () {
        final s = FileBrowsingStore();
        s.beginCollapse('s1', null);
        // top collects first: f9 ... f1
        for (var i = 9; i >= 1; i--) {
          s.collectFile('s1', null, entry('f$i'));
        }
        s.collectList(
          's1',
          null,
          path: '',
          scrollOffset: 0,
          searchQuery: '',
          searchExpanded: false,
        );
        final snap = s.snapshotFor('s1', null)!;
        expect(snap.openFiles.length, FileBrowsingStore.maxOpenFiles);
        expect(snap.openFiles.first.path, 'f2');
        expect(snap.openFiles.last.path, 'f9');
      },
    );

    test('collect without beginCollapse is a no-op', () {
      final s = FileBrowsingStore();
      s.collectFile('s1', null, entry('f1'));
      s.collectList(
        's1',
        null,
        path: 'x',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      expect(s.snapshotFor('s1', null), isNull);
    });

    test('resetCollapse preserves sealed snapshot', () {
      final s = FileBrowsingStore();
      s.beginCollapse('s1', null);
      s.collectList(
        's1',
        null,
        path: 'a',
        scrollOffset: 1,
        searchQuery: '',
        searchExpanded: false,
      );
      s.resetCollapse();
      expect(s.snapshotFor('s1', null), isNotNull);
    });

    test('resetCollapse discards unsealed staged state', () {
      final s = FileBrowsingStore();
      s.beginCollapse('s1', null);
      s.collectFile('s1', null, entry('f1'));
      s.resetCollapse();
      expect(s.isCollapsing('s1', null), isFalse);
      expect(s.snapshotFor('s1', null), isNull);
    });

    test('isCollapsing is key-scoped', () {
      final s = FileBrowsingStore();
      s.beginCollapse('s1', '/a');
      expect(s.isCollapsing('s1', '/a'), isTrue);
      expect(s.isCollapsing('s1', '/b'), isFalse);
      expect(s.isCollapsing('s2', '/a'), isFalse);
    });
  });

  group('snapshot store', () {
    test('clearSnapshot removes only the targeted key', () {
      final s = FileBrowsingStore();
      s.beginCollapse('s1', '/a');
      s.collectList(
        's1',
        '/a',
        path: '',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      s.beginCollapse('s1', '/b');
      s.collectList(
        's1',
        '/b',
        path: '',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      s.clearSnapshot('s1', '/a');
      expect(s.snapshotFor('s1', '/a'), isNull);
      expect(s.snapshotFor('s1', '/b'), isNotNull);
    });

    test('LRU: sealing beyond maxSnapshots evicts oldest', () {
      final s = FileBrowsingStore();
      for (var i = 0; i < FileBrowsingStore.maxSnapshots + 1; i++) {
        s.beginCollapse('sess-$i', null);
        s.collectList(
          'sess-$i',
          null,
          path: '',
          scrollOffset: 0,
          searchQuery: '',
          searchExpanded: false,
        );
      }
      expect(s.snapshotFor('sess-0', null), isNull);
      expect(
        s.snapshotFor('sess-${FileBrowsingStore.maxSnapshots}', null),
        isNotNull,
      );
    });

    test('LRU: snapshotFor promotes, evicting the next-oldest instead', () {
      final s = FileBrowsingStore();
      for (var i = 0; i < FileBrowsingStore.maxSnapshots; i++) {
        s.beginCollapse('sess-$i', null);
        s.collectList(
          'sess-$i',
          null,
          path: '',
          scrollOffset: 0,
          searchQuery: '',
          searchExpanded: false,
        );
      }
      expect(s.snapshotFor('sess-0', null), isNotNull); // promote
      s.beginCollapse('sess-new', null);
      s.collectList(
        'sess-new',
        null,
        path: '',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      expect(s.snapshotFor('sess-1', null), isNull);
      expect(s.snapshotFor('sess-0', null), isNotNull);
    });

    test('removeSessionData clears snapshots and content for the session', () {
      final s = FileBrowsingStore();
      s.beginCollapse('s1', null);
      s.collectList(
        's1',
        null,
        path: '',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      s.cacheContent(
        's1',
        null,
        'a.txt',
        const StreamedFile(type: 'text', text: 'hi'),
      );
      s.beginCollapse('s2', null);
      s.collectList(
        's2',
        null,
        path: '',
        scrollOffset: 0,
        searchQuery: '',
        searchExpanded: false,
      );
      s.cacheContent(
        's2',
        null,
        'b.txt',
        const StreamedFile(type: 'text', text: 'hi'),
      );
      s.removeSessionData('s1');
      expect(s.snapshotFor('s1', null), isNull);
      expect(s.cachedContent('s1', null, 'a.txt'), isNull);
      expect(s.snapshotFor('s2', null), isNotNull);
      expect(s.cachedContent('s2', null, 'b.txt'), isNotNull);
    });
  });

  group('list anchors', () {
    test('refcount register/unregister keyed by session+directory', () {
      final s = FileBrowsingStore();
      expect(s.hasListAnchor('s1', '/a'), isFalse);
      s.registerListAnchor('s1', '/a');
      s.registerListAnchor('s1', '/a');
      s.registerListAnchor('s1', '/b');
      expect(s.hasListAnchor('s1', '/a'), isTrue);
      s.unregisterListAnchor('s1', '/a');
      expect(s.hasListAnchor('s1', '/a'), isTrue);
      s.unregisterListAnchor('s1', '/a');
      expect(s.hasListAnchor('s1', '/a'), isFalse);
      expect(s.hasListAnchor('s1', '/b'), isTrue);
      s.unregisterListAnchor('s1', '/a'); // over-unregister is a safe no-op
      expect(s.hasListAnchor('s1', '/b'), isTrue);
    });
  });

  group('content cache', () {
    StreamedFile text(String s) => StreamedFile(type: 'text', text: s);
    StreamedFile bin(int n) =>
        StreamedFile(type: 'binary', bytes: Uint8List(n));

    test('hit returns cached file and promotes recency', () {
      final s = FileBrowsingStore();
      s.cacheContent('s1', null, 'a', text('aaa'));
      s.cacheContent('s1', null, 'b', text('bbb'));
      expect(s.cachedContent('s1', null, 'a')!.text, 'aaa');
    });

    test('TTL expiry returns null and frees bytes', () {
      final s = FileBrowsingStore();
      s.cacheContent('s1', null, 'a', text('aaa'));
      final later = DateTime.now().add(
        FileBrowsingStore.contentTtl + const Duration(seconds: 1),
      );
      expect(s.cachedContent('s1', null, 'a', now: later), isNull);
    });

    test('single file above maxSingleFileBytes is not cached', () {
      final s = FileBrowsingStore();
      s.cacheContent(
        's1',
        null,
        'big',
        bin(FileBrowsingStore.maxSingleFileBytes + 1),
      );
      expect(s.cachedContent('s1', null, 'big'), isNull);
    });

    test('byte LRU evicts oldest when exceeding maxContentBytes', () {
      final s = FileBrowsingStore();
      const half = FileBrowsingStore.maxContentBytes ~/ 2 - 100;
      s.cacheContent('s1', null, 'a', bin(half));
      s.cacheContent('s1', null, 'b', bin(half));
      s.cacheContent('s1', null, 'c', bin(half));
      expect(s.cachedContent('s1', null, 'a'), isNull);
      expect(s.cachedContent('s1', null, 'b'), isNotNull);
      expect(s.cachedContent('s1', null, 'c'), isNotNull);
    });

    test('re-caching same key replaces without double-counting bytes', () {
      final s = FileBrowsingStore();
      s.cacheContent('s1', null, 'a', bin(1000));
      s.cacheContent('s1', null, 'a', bin(2000));
      expect(s.debugContentBytes, 2000);
    });

    test('invalidateContentForSession clears only that session', () {
      final s = FileBrowsingStore();
      s.cacheContent('s1', '/a', 'f', text('1'));
      s.cacheContent('s1', '/b', 'f', text('2'));
      s.cacheContent('s2', '/a', 'f', text('3'));
      s.invalidateContentForSession('s1');
      expect(s.cachedContent('s1', '/a', 'f'), isNull);
      expect(s.cachedContent('s1', '/b', 'f'), isNull);
      expect(s.cachedContent('s2', '/a', 'f'), isNotNull);
    });
  });
}
