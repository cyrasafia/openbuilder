import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_router.dart';
import 'app_state.dart';
import 'core/logging/app_logger.dart';
import 'core/notifications/notification_service.dart';
import 'core/net/system_font_weight.dart';
import 'ui/theme.dart';

final _router = buildRouter(connectionStore);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLogger.I.init();
  await connectionStore.load();
  wireServerStore();
  await NotificationService.init();
  await SystemFontWeight.init();
  await initSettings();
  runApp(const OpenBuilderApp());
}

class OpenBuilderApp extends StatefulWidget {
  const OpenBuilderApp({super.key});

  @override
  State<OpenBuilderApp> createState() => _OpenBuilderAppState();
}

class _OpenBuilderAppState extends State<OpenBuilderApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      AppLogger.I.flush();
    } else if (state == AppLifecycleState.detached) {
      AppLogger.I.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => ValueListenableBuilder<Locale?>(
        valueListenable: localeMode,
        builder: (_, locale, _) => MaterialApp.router(
          title: 'Open Builder',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh'), Locale('en')],
          locale: locale,
          routerConfig: _router,
        ),
      ),
    );
  }
}
