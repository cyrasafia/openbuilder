import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/logging/app_logger.dart';
import '../../ui/l10n_ext.dart';

class BinaryView extends StatefulWidget {
  final String filename;
  final String base64Content;
  final String? mimeType;

  const BinaryView({
    super.key,
    required this.filename,
    required this.base64Content,
    this.mimeType,
  });

  @override
  State<BinaryView> createState() => _BinaryViewState();
}

class _BinaryViewState extends State<BinaryView> {
  static const _filesChannel = MethodChannel('com.openbuilder.app/files');
  bool _busy = false;
  String? _downloadedUri;

  @override
  void didUpdateWidget(covariant BinaryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filename != widget.filename ||
        oldWidget.base64Content != widget.base64Content) {
      _downloadedUri = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 64,
              color: scheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              widget.filename,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : (_downloadedUri != null ? _openFile : _onDownload),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(_downloadedUri != null ? Icons.open_in_new : Icons.download),
              label: Text(_downloadedUri != null ? l(context).fileOpen : l(context).fileDownload),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onDownload() async {
    setState(() => _busy = true);
    try {
      final file = await _materializeFile();
      if (!mounted) return;
      if (!kIsWeb && Platform.isAndroid) {
        final choice = await _showDownloadSheet();
        if (!mounted || choice == null) return;
        switch (choice) {
          case _DownloadChoice.save:
            await _saveToDownloads(file);
          case _DownloadChoice.share:
            await _share(file);
        }
      } else {
        await _share(file);
      }
    } catch (e) {
      AppLogger.I.w('BinaryView', 'download failed: $e');
      if (!mounted) return;
      _snack(l(context).fileDownloadFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<File> _materializeFile() async {
    final bytes = await compute(_decodeBase64, widget.base64Content);
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${widget.filename}');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<_DownloadChoice?> _showDownloadSheet() {
    return showModalBottomSheet<_DownloadChoice>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(l(ctx).fileSaveToDownloads),
              onTap: () => Navigator.pop(ctx, _DownloadChoice.save),
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l(ctx).fileShare),
              onTap: () => Navigator.pop(ctx, _DownloadChoice.share),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveToDownloads(File file) async {
    try {
      final uri = await _filesChannel.invokeMethod<String>('saveToDownloads', {
        'srcPath': file.path,
        'displayName': widget.filename,
        'mimeType': widget.mimeType,
      });
      if (!mounted) return;
      setState(() => _downloadedUri = uri);
      _snack(l(context).fileDownloadSuccess);
    } catch (e) {
      AppLogger.I.w('BinaryView', 'saveToDownloads failed: $e');
      if (!mounted) return;
      _snack(l(context).fileDownloadFailed(e.toString()));
    }
  }

  Future<void> _openFile() async {
    setState(() => _busy = true);
    try {
      await _filesChannel.invokeMethod<void>('openFile', {
        'uri': _downloadedUri,
        'displayName': widget.filename,
        'mimeType': widget.mimeType,
      });
    } catch (e) {
      AppLogger.I.w('BinaryView', 'openFile failed: $e');
      if (!mounted) return;
      _snack(l(context).fileOpenFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _share(File file) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)]),
      );
    } catch (e) {
      if (!mounted) return;
      _snack(l(context).fileShareFailed(e.toString()));
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

Uint8List _decodeBase64(String raw) => base64Decode(raw);

enum _DownloadChoice { save, share }
