import 'package:flutter/material.dart';

import '../../app_state.dart';

/// Phase 0 placeholder. Phase 1 wires `GET /session` + SSE.
class SessionsTab extends StatelessWidget {
  const SessionsTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('会话')),
      body: ListenableBuilder(
        listenable: connectionStore,
        builder: (context, _) {
          final server = connectionStore.active;
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text('会话列表（Phase 1 接入）',
                    style: Theme.of(context).textTheme.titleMedium),
                if (server != null) ...[
                  const SizedBox(height: 4),
                  Text('当前服务器：${server.name}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
