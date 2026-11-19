import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/json_preview.dart';

JsonParseResult parse(String text, {bool jsonl = false}) =>
    parseJsonTreeOffIsolate((text, jsonl));

List<String> plainTexts(WidgetTester tester) => tester
    .widgetList<RichText>(find.byType(RichText))
    .map((r) => r.text.toPlainText())
    // Icon widgets render their glyph in an internal RichText — a single
    // private-use codepoint with no visible text. Drop those.
    .where((t) => t.runes.any((r) => r < 0xE000))
    .toList();

JsonTreeController controllerOf(String text, {bool jsonl = false, bool expandAll = true}) {
  final r = parse(text, jsonl: jsonl);
  expect(r.ok, isTrue);
  return JsonTreeController(roots: r.roots, expandAll: expandAll);
}

void main() {
  group('parseJsonTreeOffIsolate', () {
    test('parses an object document into one root with keyed children', () {
      final r = parse('{"a": 1, "b": "x", "c": null, "d": true}');
      expect(r.ok, isTrue);
      expect(r.roots, hasLength(1));
      final root = r.roots.single;
      expect(root.kind, JsonNodeKind.object);
      expect(root.key, isNull);
      expect(root.depth, 0);
      expect(root.children.map((c) => c.key), ['a', 'b', 'c', 'd']);
      expect(root.children[0].kind, JsonNodeKind.number);
      expect(root.children[1].kind, JsonNodeKind.string);
      expect(root.children[2].kind, JsonNodeKind.nullValue);
      expect(root.children[3].kind, JsonNodeKind.boolean);
      expect(root.children.map((c) => c.depth), everyElement(1));
      expect(r.nodeCount, 5);
    });

    test('parses nested arrays and objects with depths', () {
      final r = parse('{"list": [1, {"x": 2}], "empty": {}, "earray": []}');
      expect(r.ok, isTrue);
      final root = r.roots.single;
      final list = root.children[0];
      expect(list.kind, JsonNodeKind.array);
      expect(list.children[0].kind, JsonNodeKind.number);
      final inner = list.children[1];
      expect(inner.kind, JsonNodeKind.object);
      expect(inner.children.single.key, 'x');
      expect(inner.children.single.depth, 3);
      expect(root.children[1].isContainer, isTrue);
      expect(root.children[1].expandable, isFalse);
      expect(root.children[2].isContainer, isTrue);
      expect(root.children[2].expandable, isFalse);
    });

    test('parses scalar roots', () {
      expect(parse('"just a string"').roots.single.kind, JsonNodeKind.string);
      expect(parse('42').roots.single.kind, JsonNodeKind.number);
      expect(parse('true').roots.single.kind, JsonNodeKind.boolean);
      expect(parse('null').roots.single.kind, JsonNodeKind.nullValue);
    });

    test('invalid JSON fails', () {
      expect(parse('{nope').ok, isFalse);
      expect(parse('{"a": 1').ok, isFalse);
      // JSONC comments are not valid strict JSON.
      expect(parse('{/* c */ "a": 1}').ok, isFalse);
    });

    test('JSONL yields one root per line', () {
      final r = parse(
        '{"a": 1}\n\n{"b": "x"}\n[1, 2]\n',
        jsonl: true,
      );
      expect(r.ok, isTrue);
      expect(r.roots, hasLength(3));
      expect(r.roots[0].kind, JsonNodeKind.object);
      expect(r.roots[1].kind, JsonNodeKind.object);
      expect(r.roots[2].kind, JsonNodeKind.array);
      expect(r.nodeCount, 3 + 1 + 1 + 2);
    });

    test('JSONL with a single whole JSON document decodes as one root', () {
      final r = parse('{"a": {"b": 1}}', jsonl: true);
      expect(r.ok, isTrue);
      expect(r.roots, hasLength(1));
    });

    test('JSONL with any bad line fails', () {
      expect(parse('{"a": 1}\n{oops', jsonl: true).ok, isFalse);
      expect(parse('   \n\n  ', jsonl: true).ok, isFalse);
    });
  });

  group('JsonTreeController', () {
    test('expandAll default flattens every node plus closing rows', () {
      final c = controllerOf('{"a": {"b": 1}, "c": [true, null]}');
      // root {, a {, b 1, a }, c [, true, null, c ], root }
      expect(c.rows, hasLength(9));
      expect(c.rows.where((r) => r.isClose), hasLength(3));
      expect(c.rows[0].node.depth, 0);
      expect(c.rows[1].node.key, 'a');
      expect(c.rows[2].node.key, 'b');
      expect(c.rows[3].isClose, isTrue);
    });

    test('expandAll=false starts at the first level', () {
      final c = controllerOf(
        '{"a": {"b": 1}, "c": [true, null]}',
        expandAll: false,
      );
      // root {, a {…}, c […], root }
      expect(c.rows, hasLength(4));
      expect(c.rows[1].node.key, 'a');
      expect(c.rows[1].isClose, isFalse);
      expect(c.isExpanded(c.rows[1].node), isFalse);
    });

    test('toggle collapses and re-expands a subtree', () {
      final c = controllerOf('{"a": {"b": {"deep": 1}}}');
      expect(c.rows.length, 7);
      final a = c.rows[1].node;
      c.toggle(a);
      // root {, a {…}, root }
      expect(c.rows, hasLength(3));
      c.toggle(a);
      expect(c.rows.length, 7);
    });

    test('toggle on a leaf is a no-op', () {
      final c = controllerOf('{"a": 1}');
      final before = c.rows;
      c.toggle(c.rows[1].node);
      expect(c.rows, same(before));
    });

    test('collapseAll keeps exactly the first level', () {
      final c = controllerOf('{"a": {"b": 1}, "c": [true, null]}');
      c.expandAll();
      expect(c.rows.length, 9);
      c.collapseAll();
      final texts = c.rows.map((r) => r.node.key ?? '{root}').toList();
      // First level visible: root, a, c + root close row.
      expect(c.rows, hasLength(4));
      expect(texts[1], 'a');
      expect(texts[2], 'c');
      expect(c.rows.last.isClose, isTrue);
    });

    test('collapseAll on an array root keeps its elements visible', () {
      final c = controllerOf('[1, 2]', expandAll: true);
      c.collapseAll();
      // root [, 1, 2, root ]
      expect(c.rows, hasLength(4));
    });

    test('expandAll after collapseAll restores every level', () {
      final c = controllerOf('{"a": {"b": 1}}');
      c.collapseAll();
      // root {, a {…} ×1, root }
      expect(c.rows, hasLength(3));
      c.expandAll();
      // root {, a {, b 1, a }, root }
      expect(c.rows, hasLength(5));
    });
  });

  group('JsonTreeView', () {
    testWidgets('renders keys, values and closing brackets', (tester) async {
      final c = controllerOf('{"a": {"b": 1}, "s": "hi\\nthere"}');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: JsonTreeView(controller: c))),
      );
      await tester.pumpAndSettle();
      final texts = plainTexts(tester);
      expect(texts, contains('"a": {'));
      expect(texts, contains('"b": 1'));
      expect(texts, contains('"s": "hi\\nthere"'));
      expect(texts.where((t) => t == '}'), hasLength(2));
    });

    testWidgets('collapsed containers show an inline summary', (tester) async {
      final c = controllerOf('{"a": [1, 2, 3]}', expandAll: false);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: JsonTreeView(controller: c))),
      );
      await tester.pumpAndSettle();
      expect(plainTexts(tester), contains('"a": […] ×3'));
    });

    testWidgets('empty containers render inline and never expand', (
      tester,
    ) async {
      final c = controllerOf('{"e": {}}');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: JsonTreeView(controller: c))),
      );
      await tester.pumpAndSettle();
      expect(plainTexts(tester), contains('"e": {}'));
      final before = c.rows;
      c.toggle(c.rows[1].node);
      expect(c.rows, same(before));
    });

    testWidgets('tapping a row toggles its subtree', (tester) async {
      final c = controllerOf('{"a": {"b": 1}, "keep": 2}');
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: JsonTreeView(controller: c))),
      );
      await tester.pumpAndSettle();
      expect(plainTexts(tester), contains('"b": 1'));

      // Row 1 is "a": { — tap it to collapse the subtree.
      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();
      expect(plainTexts(tester), isNot(contains('"b": 1')));
      expect(plainTexts(tester), contains('"a": {…} ×1'));
      expect(plainTexts(tester), contains('"keep": 2'));

      await tester.tap(find.byType(InkWell).at(1));
      await tester.pumpAndSettle();
      expect(plainTexts(tester), contains('"b": 1'));
    });

    testWidgets('an array root renders open/close rows around elements', (
      tester,
    ) async {
      final c = controllerOf('[1, 2]', expandAll: true);
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: JsonTreeView(controller: c))),
      );
      await tester.pumpAndSettle();
      final texts = plainTexts(tester);
      expect(texts, hasLength(4));
      expect(texts[0], '[');
      expect(texts[1], '1');
      expect(texts[2], '2');
      expect(texts[3], ']');
    });
  });
}
