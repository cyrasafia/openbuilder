import 'package:flutter/foundation.dart';

import '../../domain/models.dart';

@immutable
class FileRef {
  final String path;
  final String absolute;
  final String filename;
  final bool isDir;

  const FileRef({
    required this.path,
    required this.absolute,
    required this.filename,
    required this.isDir,
  });

  factory FileRef.fromNode(FileNode n, {String? directory}) {
    var abs = n.absolute;
    var displayPath = n.path;
    if (abs.isEmpty) {
      if (n.path.startsWith('/')) {
        abs = n.path;
      } else if (directory != null) {
        abs = n.path.isEmpty
            ? directory
            : (directory.endsWith('/')
                ? '$directory${n.path}'
                : '$directory/${n.path}');
      }
    }
    return FileRef(
      path: displayPath,
      absolute: abs,
      filename: n.name,
      isDir: n.isDir,
    );
  }

  Map<String, dynamic> toFilePart() => {
        'type': 'file',
        'mime': 'text/plain',
        'url': 'file://$absolute',
        'filename': filename,
        'source': {
          'type': 'file',
          'path': path,
          'text': {'value': '', 'start': 0, 'end': 0},
        },
      };
}