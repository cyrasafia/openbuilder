import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/file_browsing_container.dart';
import 'package:open_builder/l10n/gen/app_localizations.dart';

Widget _wrap(Widget child, {Widget? secondAction}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      appBar: AppBar(
        title: const Text('Files'),
        actions: [
          ?secondAction,
          child,
        ],
      ),
      body: const SizedBox.shrink(),
    ),
  );
}

void _dumpRects(WidgetTester tester, String label) {
  final actionRect = tester.getRect(find.byType(FileCollapseAction).last);
  final iconRect = tester.getRect(find.byIcon(Icons.unfold_less).last);
  final dividerRect = tester.getRect(find.byType(VerticalDivider).last);
  final screenRight = tester.view.physicalSize.width;
  debugPrint('''
[$label]
  CollapseAction    = $actionRect
  CollapseIcon      = $iconRect  center=${iconRect.center}
  Divider(right)    = ${dividerRect.right}
  screenRight       = $screenRight
  icon->divider     = ${iconRect.center.dx - dividerRect.right}
  icon->screen      = $screenRight - iconRect.center.dx
''');
}

void _dumpPlain(WidgetTester tester) {
  final plainRect = tester.getRect(find.byIcon(Icons.more_vert));
  final screenRight = tester.view.physicalSize.width;
  debugPrint('''
[plain IconButton action]
  moreVert           = $plainRect  center=${plainRect.center}
  screenRight        = $screenRight
  icon->screen(right)= $screenRight - plainRect.center.dx
''');
}

void main() {
  testWidgets('FileCollapseAction golden', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(_wrap(const FileCollapseAction()));
    await tester.pumpAndSettle();
    _dumpRects(tester, 'alone');

    await expectLater(
      find.byType(FileCollapseAction),
      matchesGoldenFile('goldens/file_collapse_action.png'),
    );
  });

  testWidgets('compare with plain IconButton action + both together', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final plainAction = IconButton(
      icon: const Icon(Icons.more_vert),
      onPressed: () {},
    );

    await tester.pumpWidget(_wrap(plainAction));
    await tester.pumpAndSettle();
    _dumpPlain(tester);

    await tester.pumpWidget(_wrap(const FileCollapseAction(), secondAction: plainAction));
    await tester.pumpAndSettle();
    _dumpPlain(tester);
    _dumpRects(tester, 'with plain action on left');

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/file_collapse_with_plain.png'),
    );
  });

  testWidgets('compare with PopupMenuButton (real conversation overflow)', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final popup = PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      itemBuilder: (_) => const [PopupMenuItem(value: 'x', child: Text('x'))],
      onSelected: (_) {},
    );

    await tester.pumpWidget(_wrap(popup));
    await tester.pumpAndSettle();
    _dumpPlain(tester);
    final moreVertCenter = tester.getRect(find.byIcon(Icons.more_vert).last).center.dx;

    await tester.pumpWidget(_wrap(const FileCollapseAction()));
    await tester.pumpAndSettle();
    _dumpRects(tester, 'collapse alone');

    final collapseIcon = tester.getRect(find.byIcon(Icons.unfold_less).last);
    debugPrint('''
[delta]
  moreVert center   = $moreVertCenter
  collapse center   = ${collapseIcon.center.dx}
  diff (collapse - more) = ${collapseIcon.center.dx - moreVertCenter}
''');

    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/file_collapse_vs_popup.png'),
    );
  });

  testWidgets('leading back button vs trailing action symmetry', (tester) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);

    final popup = PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      itemBuilder: (_) => const [PopupMenuItem(value: 'x', child: Text('x'))],
      onSelected: (_) {},
    );

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {},
          ),
          title: const Text('X'),
          actions: [popup, const SizedBox(width: 4)],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final back = tester.getRect(find.byIcon(Icons.arrow_back));
    final more = tester.getRect(find.byIcon(Icons.more_vert));
    final screenRight = tester.view.physicalSize.width;
    debugPrint('''
[leading vs trailing]
  back icon     = $back   center=${back.center}
  more icon     = $more   center=${more.center}
  back->left     = ${back.center.dx}
  more->right    = ${screenRight - more.center.dx}
  diff (right - left) = ${(screenRight - more.center.dx) - back.center.dx}
''');
  });
}