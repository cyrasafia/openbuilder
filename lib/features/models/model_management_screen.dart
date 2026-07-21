import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_hide_store.dart';
import '../../domain/models.dart';
import '../../ui/theme.dart';

/// Lists every enabled provider's models grouped by provider, with a
/// show/hide toggle per model. The hide set is the client-local
/// [ModelHideStore] (opencode's serve API has no model-level enable signal).
class ModelManagementScreen extends StatefulWidget {
  const ModelManagementScreen({super.key});

  @override
  State<ModelManagementScreen> createState() => _ModelManagementScreenState();
}

class _ModelManagementScreenState extends State<ModelManagementScreen> {
  List<ModelInfo> _models = const [];
  bool _loading = true;
  String? _error;
  String? _loadedServerId;
  VoidCallback? _serverListener;

  @override
  void initState() {
    super.initState();
    _serverListener = () {
      // Reload when the active server profile changes. Listen to serverStore
      // (not connectionStore): connectionStore fires before serverStore has
      // finished swapping `client`, so reading serverStore.client at that
      // moment would use the stale client. serverStore notifies after
      // connect() completes (client is fresh). Guard against the frequent
      // routine serverStore notifications by only reloading when the active
      // server id differs from what we last loaded.
      if (connectionStore.activeId != _loadedServerId) _load();
    };
    serverStore.addListener(_serverListener!);
    _load();
  }

  @override
  void dispose() {
    if (_serverListener != null) {
      serverStore.removeListener(_serverListener!);
    }
    super.dispose();
  }

  Future<void> _load() async {
    final client = serverStore.client;
    final targetSid = connectionStore.activeId;
    if (client == null) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '未连接到服务器';
          // Stamp so the serverStore listener guard (activeId !=
          // _loadedServerId) doesn't re-trigger _load() on every unrelated
          // streaming notify while disconnected.
          _loadedServerId = targetSid;
        });
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final models = await client.listConfigProviders();
      // Ignore the result if the active server changed during the fetch —
      // a later _load() is in flight and would otherwise overwrite with a
      // stale list.
      if (!mounted || connectionStore.activeId != targetSid) return;
      setState(() {
        _models = models;
        _loadedServerId = targetSid;
      });
    } catch (_) {
      // Don't surface raw exception text: /config/providers responses may
      // contain plaintext API keys, and dio errors can echo request/response
      // bodies.
      if (mounted && connectionStore.activeId == targetSid) {
        setState(() {
          _error = '加载失败，请检查服务器连接';
          // Stamp on failure too, so a persistent error doesn't cause the
          // serverStore listener to retry on every streaming notify.
          _loadedServerId = targetSid;
        });
      }
    } finally {
      if (mounted && connectionStore.activeId == targetSid) {
        setState(() => _loading = false);
      }
    }
  }

  String? get _serverId => connectionStore.activeId;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('模型管理')),
      body: ListenableBuilder(
        listenable: modelHideStore,
        builder: (context, _) {
          if (_loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (_error != null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_off, size: 40, color: scheme.outline),
                  const SizedBox(height: 8),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: scheme.outline)),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('重试')),
                ],
              ),
            );
          }
          if (_models.isEmpty) {
            return Center(
              child: Text('无可用模型',
                  style: TextStyle(fontSize: 13, color: scheme.outline)),
            );
          }
          // Group by providerID in server order.
          final groups = <String, List<ModelInfo>>{};
          for (final m in _models) {
            (groups[m.providerID] ??= []).add(m);
          }
          final sid = _serverId;
          final hiddenCount = _models
              .where((m) => modelHideStore.isHidden(sid, m.providerID, m.id))
              .length;
          return ListView(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: scheme.outline),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '隐藏的模型不会出现在对话页的模型列表中，仍可正常使用。'
                        '已隐藏 $hiddenCount / ${_models.length} 个。',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ],
                ),
              ),
              ...groups.entries.map((e) => _providerSection(e.key, e.value)),
              const SizedBox(height: 24),
            ],
          );
        },
      ),
    );
  }

  Widget _providerSection(String providerID, List<ModelInfo> items) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
          child: Row(
            children: [
              Icon(Icons.dns_outlined, size: 14, color: scheme.outline),
              const SizedBox(width: 6),
              Text(
                providerID,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: scheme.outline,
                ),
              ),
              const SizedBox(width: 6),
              Text('${items.length}',
                  style: TextStyle(fontSize: 11, color: scheme.outline)),
            ],
          ),
        ),
        ...items.map((m) => _modelRow(m)),
        const Divider(height: 1),
      ],
    );
  }

  Widget _modelRow(ModelInfo m) {
    final sid = _serverId;
    final key = ModelHideStore.makeKey(m.providerID, m.id);
    final isHidden = modelHideStore.isHidden(sid, m.providerID, m.id);
    return ListTile(
      dense: true,
      leading: const Icon(Icons.memory, size: 20),
      title: Text(m.name, style: const TextStyle(fontSize: 14)),
      subtitle:
          Text(key, style: AppTheme.mono.copyWith(fontSize: 11)),
      trailing: Switch(
        value: !isHidden,
        onChanged: sid == null
            ? null
            : (visible) async {
                if (visible) {
                  await modelHideStore.unhide(sid, m.providerID, m.id);
                } else {
                  await modelHideStore.hide(sid, m.providerID, m.id);
                }
              },
      ),
    );
  }
}