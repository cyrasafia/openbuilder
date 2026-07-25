import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../app_state.dart';
import '../../core/logging/app_logger.dart';
import '../../core/net/dio_factory.dart';
import '../../core/net/net_error.dart';
import '../../data/api/opencode_client.dart';
import '../../ui/l10n_ext.dart';
import '../../ui/theme.dart';

/// Phase 0: server status card (health/version) + server management entry +
/// minimal client settings (theme) + about.
class SettingsTab extends StatefulWidget {
  const SettingsTab({super.key});

  @override
  State<SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<SettingsTab> {
  static const _filesChannel = MethodChannel('com.openbuilder.app/files');

  bool _checking = false;
  HealthInfo? _health;
  Object? _error;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _checkHealth();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() {
        _appVersion = info.version;
      });
    }
  }

  Future<void> _checkHealth() async {
    final server = connectionStore.active;
    if (server == null) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final h = await OpencodeClient(dioFor(server)).health();
      setState(() => _health = h);
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final loc = l(context);
    return Scaffold(
      appBar: AppBar(title: Text(loc.settingsTitle)),
      body: ListenableBuilder(
        listenable: connectionStore,
        builder: (context, _) {
          final server = connectionStore.active;
          return ListView(
            children: [
              // Server status card
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(_health != null
                            ? Icons.check_circle
                            : Icons.error_outline,
                            color: _health != null
                                ? Colors.green
                                : (_error != null ? Colors.red : scheme.outline)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            server?.name ?? loc.settingsNotConfigured,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _checking ? null : _checkHealth,
                          icon: _checking
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.refresh, size: 18),
                          label: Text(loc.settingsCheck),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _kv(loc.settingsAddress, server?.hostDisplay ?? '-'),
                    _kv(
                        loc.settingsOpencodeVersion,
                        _health?.version ??
                            (_error != null
                                ? loc.settingsConnectionFailed
                                : '—')),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(friendlyMessage(loc, _error!),
                            style: AppTheme.mono.copyWith(
                                fontSize: 11, color: scheme.outline),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
              _section(loc.settingsServerSection, [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: Text(loc.settingsServerManagement),
                  subtitle: Text(loc.settingsConfiguredCount(
                      connectionStore.servers.length)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/servers'),
                ),
                ListTile(
                  leading: const Icon(Icons.memory),
                  title: Text(loc.settingsModelsManage),
                  subtitle: Text(loc.settingsModelsHint),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/models'),
                ),
              ]),
              _section(loc.settingsClientSection, [
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: Text(loc.settingsTheme),
                  trailing: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    selected: {themeMode.value},
                    onSelectionChanged: (s) =>
                        setState(() => themeMode.value = s.first),
                    segments: [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: const Icon(Icons.brightness_auto, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: const Icon(Icons.light_mode, size: 18),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: const Icon(Icons.dark_mode, size: 18),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: Text(loc.settingsLanguage),
                  trailing: SegmentedButton<Locale?>(
                    showSelectedIcon: false,
                    selected: {localeMode.value},
                    onSelectionChanged: (s) =>
                        setState(() => localeMode.value = s.first),
                    segments: [
                      ButtonSegment(
                        value: null,
                        label: Text(loc.systemLanguage),
                      ),
                      const ButtonSegment(
                        value: Locale('zh'),
                        label: Text('中'),
                      ),
                      const ButtonSegment(
                        value: Locale('en'),
                        label: Text('En'),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: Text(loc.settingsShowThinking),
                  subtitle: Text(loc.settingsShowThinkingHint),
                  trailing: Switch(
                    value: showThinking.value,
                    onChanged: (v) => setState(() => showThinking.value = v),
                  ),
                ),
              ]),
              _section(loc.settingsLogsSection, [
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: Text(loc.settingsExportLogs),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showExportRangeSheet,
                ),
              ]),
              _section(loc.settingsAboutSection, [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text(loc.settingsClientVersion),
                  trailing: Text(_appVersion.isEmpty
                      ? '…'
                      : _appVersion),
                ),
              ]),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  void _showExportRangeSheet() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: Text(l(ctx).logsLast5Min),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I
                    .exportFileRecent(const Duration(minutes: 5)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: Text(l(ctx).logsLastHour),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I
                    .exportFileRecent(const Duration(hours: 1)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: Text(l(ctx).logsToday),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I.exportFileDisk(todayOnly: true));
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: Text(l(ctx).logsAll),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(
                    () => AppLogger.I.exportFileDisk(todayOnly: false));
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _doExport(Future<File> Function() build) async {
    File file;
    try {
      file = await build();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l(context).logsExportFailed(e.toString()))));
      return;
    }
    if (!mounted) return;
    if (!kIsWeb && Platform.isAndroid) {
      await _showShareSheet(file);
    } else {
      await _share(file);
    }
  }

  Future<void> _showShareSheet(File file) async {
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(l(ctx).logsSaveToLocal),
              onTap: () {
                Navigator.pop(ctx);
                _saveToLocal(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: Text(l(ctx).logsShare),
              onTap: () {
                Navigator.pop(ctx);
                _share(file);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _share(File file) async {
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'opencode logs'),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l(context).logsShareFailed(e.toString()))));
    }
  }

  Future<void> _saveToLocal(File file) async {
    final name = file.uri.pathSegments.last;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        try {
          await _filesChannel.invokeMethod<String>('saveToDownloads', {
            'srcPath': file.path,
            'displayName': name,
          });
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l(context).logsSavedToDownload(name))));
          return;
        } catch (e) {
          AppLogger.I.w('Settings', 'saveToDownloads failed: $e');
        }
      }
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l(context).logsLocalStorageUnavailable)));
        return;
      }
      final dest = Directory('${dir.path}/logs');
      if (!await dest.exists()) await dest.create(recursive: true);
      final saved = await file.copy('${dest.path}/$name');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(l(context).logsSavedToAppDir(saved.path))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l(context).logsSaveFailed(e.toString()))));
    }
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
              width: 96,
              child: Text(k,
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.outline,
                      fontSize: 12))),
          Expanded(child: Text(v, style: AppTheme.mono.copyWith(fontSize: 12))),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(title,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ),
        ...children,
        const Divider(height: 16),
      ],
    );
  }
}
