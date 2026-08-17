import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/files/code_view.dart';

void main() {
  group('estimateLineWidthUnits', () {
    test('empty line is zero', () {
      expect(estimateLineWidthUnits(''), 0);
    });

    test('ascii counts one unit per char', () {
      expect(estimateLineWidthUnits('void main() {}'), 14);
    });

    test('wide CJK runes count two units', () {
      expect(estimateLineWidthUnits('中文'), 4);
      expect(estimateLineWidthUnits('a中b'), 4);
    });

    test('fullwidth forms count two units', () {
      expect(estimateLineWidthUnits('Ａ'), 2);
    });

    test('hangul syllables count two units', () {
      expect(estimateLineWidthUnits('한글'), 4);
    });

    test('emoji-class runes count two units', () {
      expect(estimateLineWidthUnits('🚀'), 2);
      // Misc symbols / dingbats / arrows-and-stars blocks.
      expect(estimateLineWidthUnits('☀'), 2);
      expect(estimateLineWidthUnits('⚠'), 2);
      expect(estimateLineWidthUnits('⭐'), 2);
    });

    test('tab counts eight units', () {
      expect(estimateLineWidthUnits('\t'), 8);
      expect(estimateLineWidthUnits('a\tb'), 10);
    });

    test('accented latin stays one unit', () {
      expect(estimateLineWidthUnits('éüñ'), 3);
    });
  });
}
