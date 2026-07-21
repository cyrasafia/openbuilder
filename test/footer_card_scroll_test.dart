import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the footer card scroll layout.
///
/// Background: commit 28e5715 wrapped each card's scrollable content in
/// `Flexible(SingleChildScrollView)` placed inside a `Column` that is itself a
/// NON-flex child of the footer `Column`. In Flutter a vertical `Column` hands
/// its non-flex children an *unbounded* main-axis constraint (see
/// `RenderFlex._constraintsForNonFlexChild` — it only forwards `maxWidth`),
/// so the inner `Flexible` receives `maxHeight: infinity`, stops being able to
/// flex (`canFlex == false`), and `SingleChildScrollView` sizes itself to the
/// full content height — so `maxScrollExtent` is 0 and the content cannot be
/// scrolled.
///
/// Fix: wrap the scroll view in an explicit `ConstrainedBox(maxHeight)` so the
/// viewport is bounded independently of the parent flex allocation. The footer
/// no longer imposes its own `maxHeight` (which previously clipped overflowed
/// content); each card bounds its own scroll region.
///
/// These tests reproduce both the broken pattern and the fixed pattern to guard
/// against a regression back to `Flexible`.

Widget _cardInFooter({required Widget scrollArea}) {
  return MaterialApp(
    home: Scaffold(
      appBar: AppBar(title: const Text('t')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              reverse: true,
              children:
                  List.generate(40, (i) => ListTile(title: Text('msg $i'))),
            ),
          ),
          Container(
            decoration: const BoxDecoration(
                color: Colors.white, border: Border(top: BorderSide())),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),
                        scrollArea,
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _tallContent(Key key) {
  return SingleChildScrollView(
    key: key,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 10; i++)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.all(12),
            color: Colors.grey.shade300,
            child: Text('item $i'),
          ),
      ],
    ),
  );
}

double _scrollOffset(WidgetTester tester, Finder sv) {
  final finder =
      find.descendant(of: sv, matching: find.byType(Scrollable));
  return tester.state<ScrollableState>(finder).position.pixels;
}

void main() {
  testWidgets('FIXED: ConstrainedBox bounds the nested scroll viewport',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);

    final key = GlobalKey();
    await tester.pumpWidget(_cardInFooter(
      scrollArea: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 200),
        child: _tallContent(key),
      ),
    ));
    await tester.pumpAndSettle();

    final viewport = tester.getRect(find.byKey(key)).height;
    // No layout overflow.
    expect(tester.takeException(), isNull);
    // Viewport is bounded well below the tall content.
    expect(viewport, lessThan(300));

    await tester.drag(find.byKey(key), const Offset(0, -300));
    await tester.pumpAndSettle();
    // Content actually scrolled.
    expect(_scrollOffset(tester, find.byKey(key)), greaterThan(0));
  });

  testWidgets('BROKEN pattern guard: Flexible in a non-flex child cannot scroll',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);

    final key = GlobalKey();
    await tester.pumpWidget(_cardInFooter(
      scrollArea: Flexible(child: _tallContent(key)),
    ));
    await tester.pumpAndSettle();

    // The broken pattern sizes the scroll view to its full content height, so
    // dragging does not move it (maxScrollExtent == 0).
    await tester.drag(find.byKey(key), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(_scrollOffset(tester, find.byKey(key)), equals(0.0));
  });
}
