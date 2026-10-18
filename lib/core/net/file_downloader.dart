import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';

import '../logging/app_logger.dart';
import 'raw_download.dart' as raw_download;

const String _spoolDirName = 'ob_download';
const Duration _spoolMaxAge = Duration(hours: 24);
const Duration _sweepInterval = Duration(hours: 1);
const String _tag = 'FileDL';

class FileDownloadIncompleteException implements Exception {
  final int size;
  final int total;

  const FileDownloadIncompleteException({required this.size, required this.total});

  @override
  String toString() => 'download incomplete: got $size of $total bytes';
}

class FileDownloadResult {
  final File file;
  final String? mimeType;
  final int total;
  final bool resumed;

  const FileDownloadResult({
    required this.file,
    required this.mimeType,
    required this.total,
    required this.resumed,
  });

  Future<Uint8List> readBytes() => file.readAsBytes();
}

class ContentRange {
  final int? start;
  final int? end;
  final int total;

  const ContentRange({this.start, this.end, required this.total});
}

final RegExp _contentRangeRe =
    RegExp(r'^bytes (?:\*|(\d+)-(\d+))/(\d+)$', caseSensitive: false);

ContentRange? parseContentRange(String? value) {
  if (value == null) return null;
  final m = _contentRangeRe.firstMatch(value.trim());
  if (m == null) return null;
  final total = int.tryParse(m.group(3)!);
  if (total == null || total < 0) return null;
  final s = m.group(1);
  final e = m.group(2);
  if (s == null || e == null) return ContentRange(total: total);
  final start = int.parse(s);
  final end = int.parse(e);
  if (end < start || start < 0) return null;
  return ContentRange(start: start, end: end, total: total);
}

class _SpoolMeta {
  int total;
  String? etag;
  String? lastModified;
  String? mimeType;
  bool completed;
  int updatedAt;

  _SpoolMeta({
    required this.total,
    this.etag,
    this.lastModified,
    this.mimeType,
    required this.completed,
    required this.updatedAt,
  });

  String? get ifRangeValidator {
    final e = etag;
    if (e != null && e.isNotEmpty && !e.startsWith('W/')) return e;
    final lm = lastModified;
    if (lm != null && lm.isNotEmpty) return lm;
    return null;
  }

  static _SpoolMeta? fromJson(Map<String, dynamic> j) {
    final total = j['total'];
    if (total is! int) return null;
    return _SpoolMeta(
      total: total,
      etag: j['etag']?.toString(),
      lastModified: j['lastModified']?.toString(),
      mimeType: j['mimeType']?.toString(),
      completed: j['completed'] == true,
      updatedAt: j['updatedAt'] is int ? j['updatedAt'] as int : 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'total': total,
        if (etag != null) 'etag': etag,
        if (lastModified != null) 'lastModified': lastModified,
        if (mimeType != null) 'mimeType': mimeType,
        'completed': completed,
        'updatedAt': updatedAt,
      };
}

class _Vote {
  final CancelToken? token;
  final void Function(int resumedFrom, int received, int total)? onProgress;

  _Vote(this.token, this.onProgress);
}

class _Task {
  final FileDownloader owner;
  final Dio dio;
  final String key;
  final String directory;
  final String path;
  final CancelToken token = CancelToken();
  final List<_Vote> _votes = [];
  final Completer<FileDownloadResult> _completer =
      Completer<FileDownloadResult>();
  final Completer<void> _settled = Completer<void>();
  bool _cancelling = false;

  _Task({
    required this.owner,
    required this.dio,
    required this.key,
    required this.directory,
    required this.path,
  });

  bool get cancelling => _cancelling;
  Future<FileDownloadResult> get future => _completer.future;
  Future<void> get settled => _settled.future;

  Future<FileDownloadResult> join(
    CancelToken? callerToken,
    void Function(int resumedFrom, int received, int total)? onProgress,
  ) {
    final vote = _Vote(callerToken, onProgress);
    _votes.add(vote);
    final f = future;
    if (callerToken == null) return f;
    callerToken.whenCancel.then((_) => _removeVote(vote));
    final wrapper = Completer<FileDownloadResult>();
    f.then((v) {
      if (!wrapper.isCompleted) wrapper.complete(v);
    }, onError: (Object e, StackTrace s) {
      if (!wrapper.isCompleted) wrapper.completeError(e, s);
    });
    callerToken.whenCancel.then((_) {
      if (!wrapper.isCompleted) {
        wrapper.completeError(DioException(
          requestOptions: RequestOptions(
            path: '/api/fs/read/$path',
            baseUrl: dio.options.baseUrl,
          ),
          type: DioExceptionType.cancel,
        ));
      }
    });
    return wrapper.future..ignore();
  }

  void _removeVote(_Vote vote) {
    if (_settled.isCompleted) return;
    _votes.remove(vote);
    if (_votes.isEmpty && !_cancelling) {
      _cancelling = true;
      token.cancel();
    }
  }

  void _notify(int resumedFrom, int received, int total) {
    for (final v in _votes.toList()) {
      v.onProgress?.call(resumedFrom, received, total);
    }
  }

  Future<void> run() async {
    FileDownloadResult? result;
    Object? error;
    StackTrace? stack;
    try {
      var fresh = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        result = await _attempt(fresh: fresh);
        if (result != null) break;
        fresh = true;
      }
      if (result == null) {
        throw StateError('resume restart loop exhausted');
      }
    } catch (e, s) {
      error = e;
      stack = s;
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      if (!cancelled) AppLogger.I.w(_tag, 'fail key=$key: $e');
    }
    _votes.clear();
    owner._tasks.remove(key);
    if (!_settled.isCompleted) _settled.complete();
    if (error != null) {
      _completer.completeError(error, stack);
    } else {
      _completer.complete(result);
    }
  }

  Future<FileDownloadResult?> _attempt({required bool fresh}) async {
    final dir = await owner._spoolDir();
    final partFile = File('${dir.path}/$key.part');
    final metaFile = File('${dir.path}/$key.meta.json');
    var meta = await owner._readMeta(metaFile);
    var size = 0;
    if (await partFile.exists()) {
      size = await partFile.length();
      if (meta == null && size > 0) {
        await partFile.delete();
        size = 0;
      }
    }
    final validator = fresh ? null : meta?.ifRangeValidator;
    final canResume = !fresh &&
        meta != null &&
        meta.total > 0 &&
        size > 0 &&
        size <= meta.total &&
        validator != null;

    final raw = owner._dioBuilder(dio);
    RandomAccessFile? raf;
    var resumedFrom = 0;
    var received = 0;
    var total = 0;
    var resumed = false;
    try {
      final encoded = path.split('/').map(Uri.encodeComponent).join('/');
      final r = await raw.get<ResponseBody>(
        '/api/fs/read/$encoded',
        queryParameters: owner._locationQuery(directory),
        options: Options(
          responseType: ResponseType.stream,
          validateStatus: (s) => s != null && (s < 300 || s == 416),
          headers: {
            'Accept-Encoding': 'identity',
            if (canResume) 'Range': 'bytes=$size-',
            if (canResume) 'If-Range': validator,
          },
        ),
        cancelToken: token,
      );
      final status = r.statusCode ?? 0;
      final mime = _contentType(r.headers.value('content-type'));
      final etag = r.headers.value('etag');
      final lastModified = r.headers.value('last-modified');
      final encoding =
          (r.headers.value('content-encoding') ?? '').toLowerCase();
      AppLogger.I.i(
          _tag, 'key=$key status=$status resume=${canResume ? size : 0}');

      if (status == 416) {
        try {
          await r.data?.stream.drain();
        } catch (_) {}
        final cr = parseContentRange(r.headers.value('content-range'));
        if (cr != null && size > 0 && size == cr.total && meta != null) {
          meta.total = cr.total;
          meta.completed = true;
          if (meta.mimeType == null && mime != null) meta.mimeType = mime;
          meta.updatedAt = DateTime.now().millisecondsSinceEpoch;
          await owner._writeMeta(metaFile, meta);
          AppLogger.I.i(_tag, 'reuse key=$key bytes=$size total=${cr.total}');
          return FileDownloadResult(
            file: partFile,
            mimeType: meta.mimeType,
            total: cr.total,
            resumed: true,
          );
        }
        await owner._deleteSpool(partFile, metaFile);
        return null;
      }

      if (status != 200 && status != 206) {
        throw DioException(
          requestOptions: r.requestOptions,
          response: r,
          type: DioExceptionType.badResponse,
        );
      }

      if (encoding.isNotEmpty && encoding != 'identity') {
        await owner._deleteSpool(partFile, metaFile);
        throw StateError(
            'unexpected content-encoding "$encoding" on /api/fs/read');
      }

      if (status == 206) {
        final cr = parseContentRange(r.headers.value('content-range'));
        if (cr == null || cr.start == null || cr.end == null) {
          throw StateError(
              'malformed content-range "${r.headers.value('content-range')}"');
        }
        final start = cr.start!;
        if (start > size) {
          try {
            await r.data?.stream.drain();
          } catch (_) {}
          return null;
        }
        raf = await partFile.open(mode: FileMode.append);
        await raf.truncate(start);
        await raf.setPosition(start);
        resumedFrom = start;
        total = cr.total;
        resumed = start > 0;
        meta ??= _SpoolMeta(
          total: total,
          etag: etag,
          lastModified: lastModified,
          mimeType: mime,
          completed: false,
          updatedAt: 0,
        );
      } else {
        await partFile.create(recursive: true);
        raf = await partFile.open(mode: FileMode.write);
        await raf.truncate(0);
        total = int.tryParse(r.headers.value('content-length') ?? '') ?? 0;
        resumedFrom = 0;
        resumed = false;
        meta = _SpoolMeta(
          total: total,
          etag: etag,
          lastModified: lastModified,
          mimeType: mime,
          completed: false,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
        );
      }
      meta.total = total;
      if (etag != null) meta.etag = etag;
      if (lastModified != null) meta.lastModified = lastModified;
      if (mime != null) meta.mimeType = mime;
      meta.updatedAt = DateTime.now().millisecondsSinceEpoch;
      await owner._writeMeta(metaFile, meta);

      final stream = r.data?.stream;
      if (stream != null) {
        try {
          await for (final chunk in stream) {
            received += chunk.length;
            await raf.writeFrom(chunk);
            _notify(resumedFrom, received, total);
          }
        } on Object catch (e) {
          if (_cancelling) {
            throw DioException(
              requestOptions: r.requestOptions,
              type: DioExceptionType.cancel,
              error: e,
            );
          }
          if (e is DioException) rethrow;
          throw DioException(
            requestOptions: r.requestOptions,
            type: DioExceptionType.connectionError,
            error: e,
          );
        }
      }
      await raf.flush();
      await raf.close();
      raf = null;

      final finalSize = await partFile.length();
      if (total > 0 && finalSize != total) {
        throw FileDownloadIncompleteException(size: finalSize, total: total);
      }
      if (total > 0) {
        meta.completed = true;
        meta.updatedAt = DateTime.now().millisecondsSinceEpoch;
        await owner._writeMeta(metaFile, meta);
      }
      AppLogger.I.i(_tag,
          'done key=$key bytes=$finalSize total=$total resumed=$resumed');
      return FileDownloadResult(
        file: partFile,
        mimeType: mime ?? meta.mimeType,
        total: total,
        resumed: resumed,
      );
    } finally {
      await raf?.close();
      raw.close(force: true);
    }
  }
}

String? _contentType(String? raw) => raw?.split(';').first.trim();

class FileDownloader {
  FileDownloader({
    Dio Function(Dio base)? dioBuilder,
    Future<Directory> Function()? tempDir,
  })  : _dioBuilder = dioBuilder ?? raw_download.rawDownloadDio,
        _tempDir = tempDir ?? getTemporaryDirectory;

  final Dio Function(Dio base) _dioBuilder;
  final Future<Directory> Function() _tempDir;
  final _tasks = <String, _Task>{};
  DateTime? _lastSweepAt;

  Future<FileDownloadResult> download({
    required Dio dio,
    required String directory,
    required String path,
    void Function(int resumedFrom, int received, int total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final key = _spoolKey(dio.options.baseUrl, directory, path);
    _maybeSweep();
    while (true) {
      final task = _tasks[key];
      if (task == null) break;
      if (!task.cancelling) {
        return task.join(cancelToken, onProgress);
      }
      await task.settled;
    }
    final task = _Task(
      owner: this,
      dio: dio,
      key: key,
      directory: directory,
      path: path,
    );
    _tasks[key] = task;
    final future = task.join(cancelToken, onProgress);
    unawaited(task.run());
    return future;
  }

  String _spoolKey(String baseUrl, String directory, String path) {
    final digest =
        sha256.convert(utf8.encode('$baseUrl\u0000$directory\u0000$path'));
    return digest.toString().substring(0, 32);
  }

  Map<String, dynamic> _locationQuery(String directory) =>
      directory.isEmpty ? const {} : {'location[directory]': directory};

  Future<Directory> _spoolDir() async {
    final tmp = await _tempDir();
    final dir = Directory('${tmp.path}/$_spoolDirName');
    await dir.create(recursive: true);
    return dir;
  }

  Future<_SpoolMeta?> _readMeta(File f) async {
    try {
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString());
      if (j is! Map) return null;
      return _SpoolMeta.fromJson(j.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeMeta(File f, _SpoolMeta meta) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(meta.toJson()), flush: true);
    await tmp.rename(f.path);
  }

  Future<void> _deleteSpool(File part, File metaFile) async {
    try {
      if (await part.exists()) await part.delete();
      if (await metaFile.exists()) await metaFile.delete();
      final tmp = File('${metaFile.path}.tmp');
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
  }

  void _maybeSweep() {
    final now = DateTime.now();
    final last = _lastSweepAt;
    if (last != null && now.difference(last) < _sweepInterval) return;
    _lastSweepAt = now;
    unawaited(() async {
      try {
        final tmp = await _tempDir();
        final dir = Directory('${tmp.path}/$_spoolDirName');
        if (!await dir.exists()) return;
        final cutoff = now.subtract(_spoolMaxAge);
        await for (final entry in dir.list(followLinks: false)) {
          if (entry is! File) continue;
          final stat = await entry.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entry.delete();
          }
        }
      } catch (_) {}
    }());
  }
}

final fileDownloader = FileDownloader();
