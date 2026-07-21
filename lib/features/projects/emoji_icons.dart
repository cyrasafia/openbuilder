import 'dart:math';
import 'dart:convert';

import 'package:flutter/services.dart';

const List<String> kEmojiIconAssets = <String>[
  'assets/emoji/1f600.png',
  'assets/emoji/1f604.png',
  'assets/emoji/1f602.png',
  'assets/emoji/1f970.png',
  'assets/emoji/1f60e.png',
  'assets/emoji/1f914.png',
  'assets/emoji/1f44d.png',
  'assets/emoji/1f44f.png',
  'assets/emoji/1f64f.png',
  'assets/emoji/2764.png',
  'assets/emoji/1f525.png',
  'assets/emoji/2b50.png',
  'assets/emoji/2728.png',
  'assets/emoji/1f389.png',
  'assets/emoji/1f680.png',
  'assets/emoji/1f4a1.png',
  'assets/emoji/1f3c6.png',
  'assets/emoji/1f4aa.png',
  'assets/emoji/1f31f.png',
  'assets/emoji/1f3af.png',
];

List<String> pickRandomEmojiAssets(int count, {Random? random}) {
  final rng = random ?? Random();
  final pool = List<String>.of(kEmojiIconAssets);
  pool.shuffle(rng);
  final n = count.clamp(0, pool.length);
  return pool.take(n).toList(growable: false);
}

final Map<String, String> _dataUrlCache = <String, String>{};

Future<String> emojiAssetToDataUrl(String assetPath) async {
  final cached = _dataUrlCache[assetPath];
  if (cached != null) return cached;
  final bytes = await rootBundle.load(assetPath);
  final dataUrl =
      'data:image/png;base64,${base64Encode(bytes.buffer.asUint8List())}';
  _dataUrlCache[assetPath] = dataUrl;
  return dataUrl;
}
