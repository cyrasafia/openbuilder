import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:open_builder/core/attachments/attachment_pipeline.dart';

class _MockCompressor implements ImageCompressor {
  final List<Uint8List> _compressReturns;
  int compressCalls = 0;
  _MockCompressor(this._compressReturns);

  @override
  Future<Uint8List> compress(Uint8List src,
      {required int maxWidth,
      required int maxHeight,
      required int quality}) async {
    final i = compressCalls.clamp(0, _compressReturns.length - 1);
    compressCalls++;
    return _compressReturns[i];
  }

  @override
  Future<Uint8List> thumbnail(Uint8List src, {required int edge}) async {
    return Uint8List.fromList([9, 9, 9]);
  }
}

XFile _xfile(String name, Uint8List bytes) {
  final dir = Directory.systemTemp.createTempSync('att_test');
  final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
  addTearDown(() => dir.deleteSync(recursive: true));
  return XFile(f.path);
}

void main() {
  group('AttachmentPipeline.resolve — non-image', () {
    test('<= maxFileBytes produces AttachmentPreview with dataUrl', () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final a = await AttachmentPipeline.resolve(_xfile('a.bin', bytes));
      expect(a.mime, 'application/octet-stream');
      expect(a.filename, 'a.bin');
      expect(a.dataUrl,
          'data:application/octet-stream;base64,${base64Encode(bytes)}');
      expect(a.previewThumb, isNull);
      expect(a.isImage, isFalse);
    });

    test('> maxFileBytes throws AttachmentTooLargeException', () async {
      final big = Uint8List(maxFileBytes + 1);
      await expectLater(
        AttachmentPipeline.resolve(_xfile('big.bin', big)),
        throwsA(isA<AttachmentTooLargeException>()
            .having((e) => e.name, 'name', 'big.bin')
            .having((e) => e.len, 'len', maxFileBytes + 1)),
      );
    });
  });

  group('AttachmentPipeline.resolve — image', () {
    test('small enough: single compress, no shrink loop', () async {
      final small = Uint8List.fromList([1, 2, 3]);
      final c = _MockCompressor([small]);
      final a = await AttachmentPipeline.resolve(
          _xfile('a.png', small),
          compressor: c);
      expect(c.compressCalls, 1);
      expect(a.isImage, isTrue);
      expect(a.dataUrl, 'data:image/png;base64,${base64Encode(small)}');
      expect(a.previewThumb, isNotNull);
    });

    test('exceeds base64 limit: triggers shrink loop (AT-3 + AT-7 seam)',
        () async {
      // 4MB 解码字节 → ~5.3MB base64 > maxImageBase64Bytes(4MB) → 触发 shrink
      final overRaw = Uint8List(maxImageBase64Bytes);
      final small = Uint8List.fromList([1, 2, 3]);
      final c = _MockCompressor([overRaw, small, small]);
      final a = await AttachmentPipeline.resolve(
          _xfile('a.png', Uint8List.fromList([0])),
          compressor: c);
      expect(c.compressCalls >= 2, isTrue);
      expect(a.isImage, isTrue);
      expect(a.dataUrl.startsWith('data:image/png;base64,'), isTrue);
      expect(a.previewThumb, isNotNull);
      final b64 = a.dataUrl.substring(a.dataUrl.indexOf(',') + 1);
      expect(b64.length <= maxImageBase64Bytes, isTrue);
    });
  });

  group('AttachmentTooLargeException', () {
    test('carries name and len', () {
      final e = AttachmentTooLargeException('x.pdf', 999);
      expect(e.name, 'x.pdf');
      expect(e.len, 999);
      expect(e.toString(), contains('x.pdf'));
    });
  });
}
