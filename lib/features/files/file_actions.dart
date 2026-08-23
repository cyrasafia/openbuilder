import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

const filesMethodChannel = MethodChannel('com.openbuilder.app/files');

const _exportDirPrefix = 'ob_export';
const _exportDirMaxAge = Duration(hours: 1);

Future<Directory> _exportDir() async {
  final tmp = await getTemporaryDirectory();
  _sweepStaleExportDirs(tmp);
  return tmp.createTemp(_exportDirPrefix);
}

void _sweepStaleExportDirs(Directory tmp) {
  () async {
    final cutoff = DateTime.now().subtract(_exportDirMaxAge);
    try {
      await for (final entry in tmp.list(followLinks: false)) {
        if (entry is! Directory) continue;
        if (!entry.path.split('/').last.startsWith(_exportDirPrefix)) continue;
        final stat = await entry.stat();
        if (stat.modified.isBefore(cutoff)) {
          await entry.delete(recursive: true);
        }
      }
    } catch (_) {
      // Best-effort sweep; stale dirs simply wait for the next export.
    }
  }();
}

Future<File> materializeExportFile(String filename, List<int> bytes) async {
  final dir = await _exportDir();
  final file = File('${dir.path}/$filename');
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

Future<File> materializeTextExportFile(String filename, String text) async {
  final dir = await _exportDir();
  return compute(_encodeAndWriteText, (dir.path, filename, text));
}

Future<File> _encodeAndWriteText((String, String, String) msg) async {
  final (dirPath, filename, text) = msg;
  final file = File('$dirPath/$filename');
  await file.writeAsBytes(utf8.encode(text), flush: true);
  return file;
}

Future<String?> saveExportToDownloads({
  required String srcPath,
  required String displayName,
  String? mimeType,
}) {
  return filesMethodChannel.invokeMethod<String>('saveToDownloads', {
    'srcPath': srcPath,
    'displayName': displayName,
    'mimeType': mimeType,
  });
}

Future<void> shareExportFile(File file) {
  return SharePlus.instance.share(
    ShareParams(files: [XFile(file.path)]),
  );
}
