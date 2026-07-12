import 'package:flutter/material.dart';

import 'app_router.dart';
import 'app_state.dart';
import 'ui/theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await connectionStore.load();
  runApp(const OpencodeMobileApp());
}

class OpencodeMobileApp extends StatelessWidget {
  const OpencodeMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => MaterialApp.router(
        title: 'opencode',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: mode,
        routerConfig: buildRouter(connectionStore),
      ),
    );
  }
}
