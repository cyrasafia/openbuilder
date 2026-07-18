import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(Icons.hub, size: 80, color: scheme.primary),
              const SizedBox(height: 20),
              const Text('Open Builder',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w300)),
              const SizedBox(height: 10),
              Text(
                '连接到你的 opencode 服务器\n查看任务进度、下指令、看 diff 与文档。',
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => context.go('/servers/new'),
                icon: const Icon(Icons.add),
                label: const Text('添加服务器'),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => context.go('/sessions'),
                child: const Text('稍后'),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
