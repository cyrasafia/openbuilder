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
import '../../data/api/opencode_client.dart';
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
  String? _error;
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
    } catch (_) {
      setState(() => _error = '无法连接到服务器');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
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
                            server?.name ?? '未配置',
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
                          label: const Text('检测'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _kv('地址', server?.hostDisplay ?? '-'),
                    _kv('opencode 版本',
                        _health?.version ?? (_error != null ? '连接失败' : '—')),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(_error!,
                            style: AppTheme.mono.copyWith(
                                fontSize: 11, color: scheme.outline),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis),
                      ),
                  ],
                ),
              ),
              _section('服务器', [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器管理'),
                  subtitle: Text('${connectionStore.servers.length} 个已配置'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/servers'),
                ),
                ListTile(
                  leading: const Icon(Icons.memory),
                  title: const Text('模型管理'),
                  subtitle: const Text('显示 / 隐藏模型'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/models'),
                ),
              ]),
              _section('客户端', [
                ListTile(
                  leading: const Icon(Icons.palette_outlined),
                  title: const Text('主题'),
                  trailing: SegmentedButton<ThemeMode>(
                    showSelectedIcon: false,
                    selected: {themeMode.value},
                    onSelectionChanged: (s) =>
                        setState(() => themeMode.value = s.first),
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto, size: 18),
                        label: Text('系统'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode, size: 18),
                        label: Text('浅色'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode, size: 18),
                        label: Text('深色'),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.language),
                  title: const Text('语言'),
                  trailing: SegmentedButton<Locale?>(
                    showSelectedIcon: false,
                    selected: {localeMode.value},
                    onSelectionChanged: (s) =>
                        setState(() => localeMode.value = s.first),
                    segments: const [
                      ButtonSegment(
                        value: null,
                        label: Text('系统'),
                      ),
                      ButtonSegment(
                        value: Locale('zh'),
                        label: Text('中文'),
                      ),
                      ButtonSegment(
                        value: Locale('en'),
                        label: Text('English'),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.psychology_outlined),
                  title: const Text('展示思考过程'),
                  subtitle: const Text('在会话详情页显示推理内容'),
                  trailing: Switch(
                    value: showThinking.value,
                    onChanged: (v) => setState(() => showThinking.value = v),
                  ),
                ),
              ]),
              _section('日志', [
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('导出日志'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _showExportRangeSheet,
                ),
              ]),
              _section('关于', [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('客户端版本'),
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
              title: const Text('最近 5 分钟'),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I
                    .exportFileRecent(const Duration(minutes: 5)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('最近 1 小时'),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I
                    .exportFileRecent(const Duration(hours: 1)));
              },
            ),
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: const Text('今天'),
              onTap: () {
                Navigator.pop(ctx);
                _doExport(() => AppLogger.I.exportFileDisk(todayOnly: true));
              },
            ),
            ListTile(
              leading: const Icon(Icons.file_download_outlined),
              title: const Text('全部'),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败: $e')));
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
              title: const Text('保存到本地'),
              onTap: () {
                Navigator.pop(ctx);
                _saveToLocal(file);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const Text('分享…'),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('分享失败: $e')));
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
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('已保存到 Download：$name')));
          return;
        } catch (e) {
          AppLogger.I.w('Settings', 'saveToDownloads failed: $e');
        }
      }
      final dir = await getExternalStorageDirectory();
      if (dir == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法访问本地存储')));
        return;
      }
      final dest = Directory('${dir.path}/logs');
      if (!await dest.exists()) await dest.create(recursive: true);
      final saved = await file.copy('${dest.path}/$name');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Download 不可用，已保存到应用目录：${saved.path}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('保存失败: $e')));
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
