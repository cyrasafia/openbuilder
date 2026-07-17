import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mime/mime.dart';

const maxImageBase64Bytes = 4 * 1024 * 1024;
const maxFileBytes = 8 * 1024 * 1024;
const imageMaxWidth = 2048;
const imageMaxHeight = 2048;
const previewThumbEdge = 96;

@immutable
class AttachmentPreview {
  final String mime;
  final String filename;
  final String dataUrl;
  final Uint8List? previewThumb;

  const AttachmentPreview({
    required this.mime,
    required this.filename,
    required this.dataUrl,
    this.previewThumb,
  });

  bool get isImage => mime.startsWith('image/');
}

class AttachmentTooLargeException implements Exception {
  final String name;
  final int len;
  AttachmentTooLargeException(this.name, this.len);

  @override
  String toString() => 'AttachmentTooLargeException: $name ($len bytes)';
}

abstract class ImageCompressor {
  Future<Uint8List> compress(
    Uint8List src, {
    required int maxWidth,
    required int maxHeight,
    required int quality,
  });

  Future<Uint8List> thumbnail(Uint8List src, {required int edge});
}

class _FlutterImageCompressor implements ImageCompressor {
  const _FlutterImageCompressor();

  @override
  Future<Uint8List> compress(
    Uint8List src, {
    required int maxWidth,
    required int maxHeight,
    required int quality,
  }) async {
    return FlutterImageCompress.compressWithList(
      src,
      minWidth: maxWidth,
      minHeight: maxHeight,
      quality: quality,
    );
  }

  @override
  Future<Uint8List> thumbnail(Uint8List src, {required int edge}) {
    return compress(
      src,
      maxWidth: edge,
      maxHeight: edge,
      quality: 80,
    );
  }
}

class AttachmentPicker {
  static Future<List<XFile>> pick(BuildContext context) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_outlined),
              title: const Text('图片'),
              onTap: () => Navigator.pop(ctx, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('文件'),
              onTap: () => Navigator.pop(ctx, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(ctx, 'camera'),
            ),
          ],
        ),
      ),
    );
    switch (choice) {
      case 'image':
        return ImagePicker().pickMultiImage();
      case 'file':
        final r = await FilePicker.platform.pickFiles(allowMultiple: true);
        return r?.files.map((f) => f.xFile).whereType<XFile>().toList() ?? [];
      case 'camera':
        final x = await ImagePicker().pickImage(source: ImageSource.camera);
        return x == null ? [] : [x];
      default:
        return [];
    }
  }
}

class AttachmentPipeline {
  static Future<AttachmentPreview> resolve(
    XFile f, {
    ImageCompressor? compressor,
  }) async {
    final c = compressor ?? const _FlutterImageCompressor();
    final bytes = await f.readAsBytes();
    final mime =
        f.mimeType ?? lookupMimeType(f.path) ?? 'application/octet-stream';
    if (mime.startsWith('image/')) {
      var out = await c.compress(
        bytes,
        maxWidth: imageMaxWidth,
        maxHeight: imageMaxHeight,
        quality: 85,
      );
      out = await _shrinkToBase64Limit(out, mime, c);
      final thumb = await c.thumbnail(out, edge: previewThumbEdge);
      return AttachmentPreview(
        mime: mime,
        filename: f.name,
        dataUrl: _toDataUrl(mime, out),
        previewThumb: thumb,
      );
    }
    if (bytes.length > maxFileBytes) {
      throw AttachmentTooLargeException(f.name, bytes.length);
    }
    return AttachmentPreview(
      mime: mime,
      filename: f.name,
      dataUrl: _toDataUrl(mime, bytes),
    );
  }

  static Future<Uint8List> _shrinkToBase64Limit(
    Uint8List out,
    String mime,
    ImageCompressor c,
  ) async {
    if (base64Encode(out).length <= maxImageBase64Bytes) return out;
    for (final q in [60, 30]) {
      out = await c.compress(
        out,
        maxWidth: imageMaxWidth,
        maxHeight: imageMaxHeight,
        quality: q,
      );
      if (base64Encode(out).length <= maxImageBase64Bytes) return out;
    }
    out = await c.compress(
      out,
      maxWidth: 1024,
      maxHeight: 1024,
      quality: 30,
    );
    return out;
  }

  static String _toDataUrl(String mime, Uint8List bytes) =>
      'data:$mime;base64,${base64Encode(bytes)}';
}
