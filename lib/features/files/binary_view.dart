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
  final String? mimeType;
  final Uint8List? downloadedBytes;

  const BinaryView({
    super.key,
    required this.filename,
    this.mimeType,
    this.downloadedBytes,
  });

  @override
  State<BinaryView> createState() => _BinaryViewState();
}

class _BinaryViewState extends State<BinaryView> {
  static const _filesChannel = MethodChannel('com.openbuilder.app/files');
  _Action? _busy;
  String? _downloadedUri;

  @override
  void didUpdateWidget(covariant BinaryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.filename != widget.filename ||
        oldWidget.downloadedBytes != widget.downloadedBytes) {
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
            if (widget.downloadedBytes == null)
              Text(
                l(context).loadFailed,
                style: const TextStyle(fontSize: 12),
              )
            else
              _actions(),
          ],
        ),
      ),
    );
  }

  Widget _actions() {
    final loc = l(context);
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final saved = _downloadedUri != null;
    final primaryAction = saved ? _Action.open : _Action.save;
    final spinner = const SizedBox(
      width: 16,
      height: 16,
      child: CircularProgressIndicator(strokeWidth: 2),
    );

    if (isAndroid) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: _busy == null ? (saved ? _openFile : _onSave) : null,
            icon: _busy == primaryAction
                ? spinner
                : Icon(saved ? Icons.open_in_new : Icons.save_alt),
            label: Text(saved ? loc.fileOpen : loc.save),
          ),
          const SizedBox(width: 12),
          TextButton.icon(
            onPressed: _busy == null ? _onShare : null,
            icon: _busy == _Action.share
                ? spinner
                : const Icon(Icons.share_outlined),
            label: Text(loc.fileShare),
          ),
        ],
      );
    }
    return FilledButton.icon(
      onPressed: _busy == null ? _onShare : null,
      icon: _busy == _Action.share ? spinner : const Icon(Icons.share_outlined),
      label: Text(loc.fileShare),
    );
  }

  Future<File> _materializeFile() async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/${widget.filename}');
    await file.writeAsBytes(widget.downloadedBytes!, flush: true);
    return file;
  }

  Future<void> _onSave() async {
    setState(() => _busy = _Action.save);
    try {
      final file = await _materializeFile();
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
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _openFile() async {
    setState(() => _busy = _Action.open);
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
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _onShare() async {
    setState(() => _busy = _Action.share);
    try {
      final file = await _materializeFile();
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)]),
      );
    } catch (e) {
      AppLogger.I.w('BinaryView', 'share failed: $e');
      if (!mounted) return;
      _snack(l(context).fileShareFailed(e.toString()));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

enum _Action { save, open, share }
