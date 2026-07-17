import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
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
    } catch (e) {
      setState(() => _error = '$e');
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
              ]),
              _section('日志', [
                ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('导出最近 5 分钟'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportRecent(const Duration(minutes: 5)),
                ),
                ListTile(
                  leading: const Icon(Icons.schedule_outlined),
                  title: const Text('导出最近 1 小时'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportRecent(const Duration(hours: 1)),
                ),
                ListTile(
                  leading: const Icon(Icons.today_outlined),
                  title: const Text('导出今天'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportDisk(todayOnly: true),
                ),
                ListTile(
                  leading: const Icon(Icons.file_download_outlined),
                  title: const Text('导出全部'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _exportDisk(todayOnly: false),
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

  Future<void> _exportRecent(Duration since) async {
    final file = await AppLogger.I.exportFileRecent(since);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: 'opencode logs'),
    );
  }

  Future<void> _exportDisk({required bool todayOnly}) async {
    final file = await AppLogger.I.exportFileDisk(todayOnly: todayOnly);
    await SharePlus.instance.share(
      ShareParams(
          files: [XFile(file.path)],
          text: todayOnly ? 'opencode logs today' : 'opencode logs all'),
    );
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
