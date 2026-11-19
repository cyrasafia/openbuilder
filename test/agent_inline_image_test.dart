import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/local_image_cache.dart';
import 'package:open_builder/features/conversation/agent_inline_image.dart';

final Uint8List pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==',
);

final Uint8List svgBytes = utf8.encode(
  '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">'
  '<rect width="10" height="10"/></svg>',
);

void main() {
  group('textMayContainLocalImage', () {
    test('gates on the image marker', () {
      expect(textMayContainLocalImage('![x](a.png)'), isTrue);
      expect(textMayContainLocalImage('plain text'), isFalse);
      expect(textMayContainLocalImage('') , isFalse);
    });
  });

  group('localImagePattern', () {
    test('hits relative / absolute / nested paths', () {
      expect(localImagePattern.firstMatch('![QR](auth.png)'), isNotNull);
      expect(localImagePattern.firstMatch('![QR](a/b/c.png)'), isNotNull);
      expect(localImagePattern.firstMatch('![ ](/abs/x.PNG)'), isNotNull);
    });

    test('trailing paren keeps the clean src', () {
      final m = localImagePattern.firstMatch('![x](a.png))')!;
      expect(m.group(2), 'a.png');
    });

    test('adjacent images match separately', () {
      final text = '![a](b.png)![c](d.png)';
      final all = localImagePattern.allMatches(text).toList();
      expect(all.length, 2);
      expect(all[0].group(2), 'b.png');
      expect(all[1].group(2), 'd.png');
    });

    test('paren inside src truncates at first close paren (documented)', () {
      final m = localImagePattern.firstMatch('![x](a(b).png)')!;
      expect(m.group(2), 'a(b');
    });

    test('misses schemed srcs (S5/S6/S7)', () {
      expect(
        localImagePattern.firstMatch('![x](http://e.com/a.png)'),
        isNull,
      );
      expect(
        localImagePattern.firstMatch('![x](https://e.com/a.png)'),
        isNull,
      );
      expect(
        localImagePattern.firstMatch('![x](data:image/png;base64,AAAA)'),
        isNull,
      );
      expect(localImagePattern.firstMatch('![x](file:///tmp/a.png)'), isNull);
      expect(localImagePattern.firstMatch('![x](ftp://e.com/a.png)'), isNull);
      expect(
        localImagePattern.firstMatch('![x](ob-file:///a/b.png)'),
        isNull,
      );
    });

    test('misses spaced paths (S15) and empty src', () {
      expect(localImagePattern.firstMatch('![x](my file.png)'), isNull);
      expect(localImagePattern.firstMatch('![x]()'), isNull);
    });
  });

  group('resolveLocalImage', () {
    test('relative resolves against the session directory', () {
      final s = resolveLocalImage('a/b.png', '/proj')!;
      expect(s.path, 'a/b.png');
      expect(s.directory, '/proj');
      expect(s.kind, InlineImageKind.bitmap);
    });

    test('absolute splits into dirname + basename (D2)', () {
      final s = resolveLocalImage('/a/b/c.png', '/proj')!;
      expect(s.path, 'c.png');
      expect(s.directory, '/a/b');
    });

    test('root-level absolute keeps directory "/"', () {
      final s = resolveLocalImage('/x.png', '/proj')!;
      expect(s.path, 'x.png');
      expect(s.directory, '/');
    });

    test('extension whitelist (D3)', () {
      expect(resolveLocalImage('a.PNG', '/p')!.kind, InlineImageKind.bitmap);
      expect(resolveLocalImage('a.webp', '/p')!.kind, InlineImageKind.bitmap);
      expect(resolveLocalImage('a.svg', '/p')!.kind, InlineImageKind.svg);
      expect(resolveLocalImage('a.pdf', '/p')!.kind, InlineImageKind.chip);
      expect(resolveLocalImage('a.avif', '/p')!.kind, InlineImageKind.chip);
      expect(resolveLocalImage('a.ico', '/p')!.kind, InlineImageKind.chip);
      expect(resolveLocalImage('Makefile', '/p')!.kind, InlineImageKind.chip);
    });

    test('unfetchable srcs return null', () {
      expect(resolveLocalImage('', '/proj'), isNull);
      expect(resolveLocalImage('\u0007a.png', '/proj'), isNull);
      expect(resolveLocalImage('//host/a.png', '/proj'), isNull);
      expect(resolveLocalImage('a.png', ''), isNull);
    });
  });

  group('LocalImageCache', () {
    test('concurrent same-key fetches share one loader call', () async {
      final cache = LocalImageCache();
      var calls = 0;
      Future<Uint8List?> load() async {
        calls++;
        return pngBytes;
      }

      final f1 = cache.fetch('d\x1fa.png', load);
      final f2 = cache.fetch('d\x1fa.png', load);
      expect(identical(f1, f2), isTrue);
      await f1;
      expect(calls, 1);
    });

    test('FIFO evicts the oldest entry past maxEntries', () async {
      final cache = LocalImageCache(maxEntries: 2);
      var calls = 0;
      Future<Uint8List?> load() async {
        calls++;
        return pngBytes;
      }

      await cache.fetch('k1', load);
      await cache.fetch('k2', load);
      await cache.fetch('k3', load);
      expect(calls, 3);
      await cache.fetch('k1', load);
      expect(calls, 4);
    });

    test('failed fetches stay negative until eviction', () async {
      final cache = LocalImageCache(maxEntries: 2);
      var calls = 0;
      Future<Uint8List?> load() async {
        calls++;
        return null;
      }

      await cache.fetch('dead', load);
      await cache.fetch('dead', load);
      expect(calls, 1);
    });
  });

  group('buildInlineImageSpan', () {
    RegExpMatch matchOf(String text) =>
        localImagePattern.firstMatch(text)!;

    Future<Widget> spanHost(
      WidgetTester tester,
      RegExpMatch match, {
      required String directory,
      required void Function(String href) onOpenFile,
      Future<Uint8List?> Function(InlineImageSpec spec)? loader,
    }) async {
      late Widget spanned;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                spanned = Text.rich(
                  TextSpan(
                    children: [
                      buildInlineImageSpan(
                        context,
                        match,
                        const TextStyle(),
                        directory,
                        onOpenFile: onOpenFile,
                        loader: loader,
                      ),
                    ],
                  ),
                );
                return spanned;
              },
            ),
          ),
        ),
      );
      return spanned;
    }

    testWidgets('bitmap renders an Image after fetch', (tester) async {
      await spanHost(
        tester,
        matchOf('![QR](auth.png)'),
        directory: '/proj',
        onOpenFile: (_) {},
        loader: (_) async => pngBytes,
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
    });

    testWidgets('svg renders through SvgPicture (S9)', (tester) async {
      await spanHost(
        tester,
        matchOf('![logo](logo.svg)'),
        directory: '/proj',
        onOpenFile: (_) {},
        loader: (_) async => svgBytes,
      );
      await tester.pumpAndSettle();
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('fetch failure renders the failure row (S4)', (tester) async {
      await spanHost(
        tester,
        matchOf('![QR](gone.png)'),
        directory: '/proj',
        onOpenFile: (_) {},
        loader: (_) async => null,
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('QR'), findsOneWidget);
    });

    testWidgets('loader error renders the failure row', (tester) async {
      await spanHost(
        tester,
        matchOf('![QR](boom.png)'),
        directory: '/proj',
        onOpenFile: (_) {},
        loader: (_) async => throw Exception('404'),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
      expect(find.text('QR'), findsOneWidget);
    });

    testWidgets(
      'unresolvable spec still produces a widget (S12)',
      (tester) async {
        var loaded = false;
        await spanHost(
          tester,
          matchOf('![QR](a.png)'),
          directory: '',
          onOpenFile: (_) {},
          loader: (_) async {
            loaded = true;
            return pngBytes;
          },
        );
        await tester.pump();
        expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
        expect(loaded, isFalse);
      },
    );

    testWidgets('whitelist miss renders a file chip (S8)', (tester) async {
      final hrefs = <String>[];
      await spanHost(
        tester,
        matchOf('![doc](a/b.pdf)'),
        directory: '/proj',
        onOpenFile: hrefs.add,
        loader: (_) async => pngBytes,
      );
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('a/b.pdf'), findsOneWidget);
      await tester.tap(find.text('a/b.pdf'));
      expect(hrefs, ['ob-file:///a/b.pdf']);
    });

    testWidgets(
      'chip tap keeps the absolute path (NB-1)',
      (tester) async {
        final hrefs = <String>[];
        await spanHost(
          tester,
          matchOf('![doc](/outside/x/a.pdf)'),
          directory: '/proj',
          onOpenFile: hrefs.add,
          loader: (_) async => pngBytes,
        );
        await tester.pump();
        await tester.tap(find.text('/outside/x/a.pdf'));
        expect(hrefs, ['ob-file:////outside/x/a.pdf']);
      },
    );
  });
}
