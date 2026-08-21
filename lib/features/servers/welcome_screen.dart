import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../ui/l10n_ext.dart';

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
                l(context).welcomeIntro,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
              ),
              const Spacer(),
              FilledButton.icon(
                onPressed: () => context.go('/servers/new'),
                icon: const Icon(Icons.add),
                label: Text(l(context).addServer),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
