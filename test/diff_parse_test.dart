import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/domain/models.dart';

const _sample = '''
diff --git a/main.dart b/main.dart
index 1234567..abcdefg 100644
--- a/main.dart
+++ b/main.dart
@@ -10,3 +10,4 @@
 context line
-removed line
+added line
+another added
@@ -20,2 +21,0 @@
-removed in second hunk
-removed again
''';

void main() {
  test('parseDiffHunks drops file-header metadata and splits on @@', () {
    final hunks = parseDiffHunks(_sample);
    expect(hunks.length, 2);

    final h1 = hunks[0];
    expect(h1.oldStart, 10);
    expect(h1.newStart, 10);
    expect(h1.additions, 2);
    expect(h1.deletions, 1);
    expect(h1.lines.map((l) => l.kind).toList(), [' ', '-', '+', '+']);
    // file header lines (diff --git / index / --- / +++) must be dropped
    expect(h1.lines.every((l) => !l.text.contains('diff --git')), isTrue);
    expect(h1.lines.every((l) => !l.text.startsWith('b/')), isTrue);
  });

  test('added/removed line numbers advance independently', () {
    final hunks = parseDiffHunks(_sample);
    final ctx = hunks[0].lines[0];
    expect(ctx.kind, ' ');
    expect(ctx.oldNo, 10);
    expect(ctx.newNo, 10);
    final removed = hunks[0].lines[1];
    expect(removed.kind, '-');
    expect(removed.oldNo, 11);
    expect(removed.newNo, isNull);
    final added1 = hunks[0].lines[2];
    expect(added1.kind, '+');
    expect(added1.oldNo, isNull);
    expect(added1.newNo, 11);
    final added2 = hunks[0].lines[3];
    expect(added2.newNo, 12);
  });

  test('content lines starting with ++ / -- are kept (regression guard)', () {
    // added "++i;" -> raw "+++i;" must NOT be treated as file header.
    // removed "--i;" -> raw "---i;" must NOT be treated as file header.
    final patch = '''
--- a/x
+++ b/x
@@ -1,2 +1,3 @@
 keep
+++i;
---i;
''';
    final hunks = parseDiffHunks(patch);
    expect(hunks.length, 1);
    final h = hunks[0];
    final kinds = h.lines.map((l) => l.kind).toList();
    expect(kinds, [' ', '+', '-']);
    expect(h.lines[1].text, '++i;');
    expect(h.lines[2].text, '--i;');
    expect(h.additions, 1);
    expect(h.deletions, 1);
  });

  test('empty / binary patch yields no hunks', () {
    expect(parseDiffHunks(''), []);
    expect(parseDiffHunks('Binary files differ\n'), []);
    expect(parseDiffHunks('diff --git a/x b/x\nindex 1..2\n'), []);
  });

  test('\\ No newline at end of file marker is dropped', () {
    final patch = '''
--- a/x
+++ b/x
@@ -1,1 +1,1 @@
-old
\\ No newline at end of file
+new
''';
    final hunks = parseDiffHunks(patch);
    expect(hunks.length, 1);
    final h = hunks[0];
    expect(h.lines.map((l) => l.kind).toList(), ['-', '+']);
    expect(h.deletions, 1);
    expect(h.additions, 1);
  });

  test('multi-file patch stops at second diff --git', () {
    final patch = '''
diff --git a/x b/x
--- a/x
+++ b/x
@@ -1,1 +1,1 @@
 a
+b
diff --git a/y b/y
--- a/y
+++ b/y
@@ -1,1 +1,1 @@
 c
+d
''';
    final hunks = parseDiffHunks(patch);
    expect(hunks.length, 1);
    expect(hunks[0].additions, 1);
  });
}