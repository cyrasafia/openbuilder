import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_state.dart';
import '../../core/net/net_error.dart';
import '../../ui/l10n_ext.dart';

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

enum FileExportAction { saveToDevice, share }

enum _ExportPhase { downloading, acting, failed }

/// Downloads [path] from the server with a progress dialog, then runs the
/// save/share action on the materialized file. Cancellation is offered while
/// the download is in flight; a cancelled download closes the dialog silently.
/// Save success surfaces a snackbar; share completion is silent.
Future<void> showFileExportDialog({
  required BuildContext context,
  required String sessionId,
  required String? directory,
  required String path,
  required String filename,
  required FileExportAction action,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _FileExportDialog(
      sessionId: sessionId,
      directory: directory,
      path: path,
      filename: filename,
      action: action,
    ),
  );
}

class _FileExportDialog extends StatefulWidget {
  final String sessionId;
  final String? directory;
  final String path;
  final String filename;
  final FileExportAction action;

  const _FileExportDialog({
    required this.sessionId,
    required this.directory,
    required this.path,
    required this.filename,
    required this.action,
  });

  @override
  State<_FileExportDialog> createState() => _FileExportDialogState();
}

class _FileExportDialogState extends State<_FileExportDialog> {
  _ExportPhase _phase = _ExportPhase.downloading;
  double? _progress;
  String? _errorMsg;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  void _cancel() {
    _cancelToken?.cancel();
  }

  Future<void> _run() async {
    final c = serverStore.client;
    if (c == null) {
      setState(() {
        _phase = _ExportPhase.failed;
        _errorMsg = friendlyMessage(
          l(context),
          const KnownError(FriendlyErrorKind.notConnected),
        );
      });
      return;
    }
    setState(() {
      _phase = _ExportPhase.downloading;
      _progress = null;
      _errorMsg = null;
    });
    var f = serverStore.fileBrowsing.cachedContent(
      widget.sessionId,
      widget.directory,
      widget.path,
    );
    if (f == null) {
      final token = CancelToken();
      _cancelToken = token;
      try {
        f = await c.readFileStream(
          directory: widget.directory ?? '',
          path: widget.path,
          onProgress: (received, total) {
            if (!mounted || _cancelToken != token || total <= 0) return;
            final p = (received / total).clamp(0.0, 1.0);
            if (p != _progress) setState(() => _progress = p);
          },
          cancelToken: token,
        );
        serverStore.fileBrowsing.cacheContent(
          widget.sessionId,
          widget.directory,
          widget.path,
          f,
        );
      } on DioException catch (e) {
        _cancelToken = null;
        if (e.type == DioExceptionType.cancel) {
          if (mounted) Navigator.of(context).pop();
          return;
        }
        if (mounted) {
          setState(() {
            _phase = _ExportPhase.failed;
            _errorMsg = friendlyMessage(l(context), e);
          });
        }
        return;
      } catch (e) {
        _cancelToken = null;
        if (mounted) {
          setState(() {
            _phase = _ExportPhase.failed;
            _errorMsg = friendlyMessage(l(context), e);
          });
        }
        return;
      }
      _cancelToken = null;
    }
    if (!mounted) return;
    setState(() => _phase = _ExportPhase.acting);
    try {
      final file = f.isBinary
          ? await materializeExportFile(widget.filename, f.bytes ?? Uint8List(0))
          : await materializeTextExportFile(widget.filename, f.text ?? '');
      if (widget.action == FileExportAction.saveToDevice) {
        await saveExportToDownloads(
          srcPath: file.path,
          displayName: widget.filename,
          mimeType: f.mimeType,
        );
        if (!mounted) return;
        final msg = l(context).fileDownloadSuccess;
        final messenger = ScaffoldMessenger.of(context);
        Navigator.of(context).pop();
        messenger.showSnackBar(SnackBar(content: Text(msg)));
      } else {
        await shareExportFile(file);
        if (!mounted) return;
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _ExportPhase.failed;
        _errorMsg = widget.action == FileExportAction.saveToDevice
            ? l(context).fileDownloadFailed(e.toString())
            : l(context).fileShareFailed(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = l(context);
    final canDismiss = _phase != _ExportPhase.downloading;
    return PopScope(
      canPop: canDismiss,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _cancel();
      },
      child: AlertDialog(
        title: Text(
          widget.action == FileExportAction.saveToDevice
              ? loc.fileSaveToDevice
              : loc.fileShare,
          style: const TextStyle(fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.filename,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (_phase == _ExportPhase.downloading)
              if (_progress != null)
                LinearProgressIndicator(value: _progress)
              else
                const Center(child: CircularProgressIndicator())
            else if (_phase == _ExportPhase.acting)
              const Center(child: CircularProgressIndicator())
            else
              Text(
                _errorMsg ?? '',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            if (_phase == _ExportPhase.downloading && _progress != null) ...[
              const SizedBox(height: 8),
              Text('${(_progress! * 100).round()}%'),
            ],
          ],
        ),
        actions: [
          if (_phase == _ExportPhase.failed)
            TextButton(
              onPressed: _run,
              child: Text(loc.retry),
            ),
          if (_phase == _ExportPhase.downloading)
            TextButton(
              onPressed: _cancel,
              child: Text(loc.fileLoadCancel),
            ),
          if (canDismiss)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(loc.cancel),
            ),
        ],
      ),
    );
  }
}
