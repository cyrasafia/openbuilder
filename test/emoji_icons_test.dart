import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/features/projects/emoji_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pickRandomEmojiAssets', () {
    test('returns requested count of distinct pool entries', () {
      final picked = pickRandomEmojiAssets(5);
      expect(picked.length, 5);
      expect(picked.toSet().length, 5);
      for (final p in picked) {
        expect(kEmojiIconAssets, contains(p));
      }
    });

    test('zero returns empty list', () {
      expect(pickRandomEmojiAssets(0), isEmpty);
    });

    test('count larger than pool is clamped to pool size', () {
      final picked = pickRandomEmojiAssets(kEmojiIconAssets.length + 50);
      expect(picked.length, kEmojiIconAssets.length);
      expect(picked.toSet().length, kEmojiIconAssets.length);
    });

    test('is deterministic when seeded', () {
      final a = pickRandomEmojiAssets(5, random: Random(42));
      final b = pickRandomEmojiAssets(5, random: Random(42));
      expect(a, equals(b));
    });

    test('different seeds usually yield different picks', () {
      final a = pickRandomEmojiAssets(5, random: Random(1));
      final b = pickRandomEmojiAssets(5, random: Random(2));
      expect(a, isNot(equals(b)));
    });
  });

  test('kEmojiIconAssets has 20 bundled emojis, all under assets/emoji/', () {
    expect(kEmojiIconAssets.length, 20);
    for (final path in kEmojiIconAssets) {
      expect(path, startsWith('assets/emoji/'));
      expect(path, endsWith('.png'));
    }
  });

  group('emojiAssetToDataUrl', () {
    const prefix = 'data:image/png;base64,';
    const pngMagic = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

    test('returns a valid PNG data URL', () async {
      final url = await emojiAssetToDataUrl(kEmojiIconAssets.first);
      expect(url, startsWith(prefix));
      final bytes = base64Decode(url.substring(prefix.length));
      expect(bytes.sublist(0, pngMagic.length), pngMagic);
    });

    test('caches: second call returns the same string instance', () async {
      final a = await emojiAssetToDataUrl(kEmojiIconAssets.first);
      final b = await emojiAssetToDataUrl(kEmojiIconAssets.first);
      expect(identical(a, b), isTrue);
    });

    test('every bundled emoji loads and decodes', () async {
      for (final asset in kEmojiIconAssets) {
        final url = await emojiAssetToDataUrl(asset);
        expect(url, startsWith(prefix));
        final bytes = base64Decode(url.substring(prefix.length));
        expect(bytes.sublist(0, pngMagic.length), pngMagic);
      }
    });
  });
}

