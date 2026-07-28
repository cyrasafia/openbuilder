import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/domain/models.dart';
import 'package:open_builder/features/files/highlight_theme.dart';

void main() {
  group('languageForPath', () {
    test('maps known extensions', () {
      expect(languageForPath('lib/main.dart'), 'dart');
      expect(languageForPath('config.jsonc'), 'json');
      expect(languageForPath('app/Component.tsx'), 'typescript');
      expect(languageForPath('index.html'), 'html');
      expect(languageForPath('style.css'), 'css');
    });

    test('returns null for unknown / no extension', () {
      expect(languageForPath('README.xyz'), isNull);
      expect(languageForPath('Makefile'), isNull);
    });
  });

  group('FileContent', () {
    test('fromJson maps encoding + derives accessors', () {
      final f = FileContent.fromJson({
        'type': 'binary',
        'content': 'AAA',
        'encoding': 'base64',
        'mimeType': 'image/jpeg',
      });
      expect(f.isBinary, isTrue);
      expect(f.isBase64, isTrue);
      expect(f.mimeType, 'image/jpeg');
    });

    test('defaults: text file is neither binary nor base64', () {
      final f = FileContent.fromJson({'type': 'text', 'content': 'hi'});
      expect(f.isBinary, isFalse);
      expect(f.isBase64, isFalse);
      expect(f.encoding, isNull);
    });
  });

  group('HighlightPainter.highlight', () {
    const base = TextStyle(fontFamily: 'monospace');

    test('one TextSpan per source line', () {
      const code = 'int a = 1;\nint b = 2;\nint c = 3;';
      final lines =
          HighlightPainter.highlight(code, 'dart', base, Brightness.light);
      expect(lines.length, 3);
    });

    test('block comment spanning lines is comment-colored on every line', () {
      const code = '/* line one\nline two */';
      final lines =
          HighlightPainter.highlight(code, 'dart', base, Brightness.light);
      expect(lines.length, 2);
      const commentColor = Color(0xff6a737d);
      expect(leafColors(lines[0]), contains(commentColor));
      expect(leafColors(lines[1]), contains(commentColor));
    });

    test('non-comment code is not colored as comment', () {
      const code = "var s = 'x';";
      final lines =
          HighlightPainter.highlight(code, 'dart', base, Brightness.light);
      expect(lines.length, 1);
      const commentColor = Color(0xff6a737d);
      expect(leafColors(lines[0]), isNot(contains(commentColor)));
    });

    test('vendored bold tokens normalize to w600 (DESIGN.md three-weight)', () {
      const code = '**bold**';
      final lines =
          HighlightPainter.highlight(code, 'markdown', base, Brightness.light);
      final weights = leafWeights(lines.first);
      expect(weights, contains(FontWeight.w600));
      expect(weights, isNot(contains(FontWeight.bold)));
    });
  });
}

List<Color> leafColors(TextSpan span) {
  final colors = <Color>[];
  for (final w in _walkStyle(span)) {
    if (w.color != null) colors.add(w.color!);
  }
  return colors;
}

List<FontWeight> leafWeights(TextSpan span) {
  final weights = <FontWeight>[];
  for (final s in _walkStyle(span)) {
    if (s.fontWeight != null) weights.add(s.fontWeight!);
  }
  return weights;
}

Iterable<TextStyle> _walkStyle(InlineSpan span) sync* {
  if (span is TextSpan) {
    if (span.style != null) yield span.style!;
    for (final c in span.children ?? const <InlineSpan>[]) {
      yield* _walkStyle(c);
    }
  }
}
