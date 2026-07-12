import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../ui/theme.dart';

/// List of configured servers; reached from Settings → 服务器管理.
class ServersScreen extends StatelessWidget {
  const ServersScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: connectionStore,
      builder: (context, _) {
        final servers = connectionStore.servers;
        final activeId = connectionStore.activeId;
        return Scaffold(
          appBar: AppBar(title: const Text('服务器管理')),
          body: ListView.separated(
            itemCount: servers.length,
            separatorBuilder: (_, _) => const Divider(height: 1, indent: 16),
            itemBuilder: (context, i) {
              final s = servers[i];
              final active = s.id == activeId;
              return ListTile(
                leading: Icon(
                  Icons.dns_outlined,
                  color: active ? Theme.of(context).colorScheme.primary : null,
                ),
                title: Row(
                  children: [
                    Flexible(
                      child: Text(s.name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis),
                    ),
                    if (active)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .primaryContainer,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text('当前',
                            style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context)
                                    .colorScheme
                                    .onPrimaryContainer)),
                      ),
                  ],
                ),
                subtitle: Text(s.hostDisplay,
                    style: AppTheme.mono.copyWith(fontSize: 12)),
                trailing: IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  onPressed: () =>
                      context.push('/servers/${s.id}/edit'),
                ),
                onTap: () => connectionStore.setActive(s.id),
              );
            },
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => context.push('/servers/new'),
            icon: const Icon(Icons.add),
            label: const Text('添加'),
          ),
        );
      },
    );
  }
}
