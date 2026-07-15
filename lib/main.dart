import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_router.dart';
import 'app_state.dart';
import 'core/notifications/notification_service.dart';
import 'core/net/system_font_weight.dart';
import 'ui/theme.dart';

final _router = buildRouter(connectionStore);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await connectionStore.load();
  wireServerStore();
  await NotificationService.init();
  await SystemFontWeight.init();
  await initSettings();
  runApp(const OpencodeMobileApp());
}

class OpencodeMobileApp extends StatelessWidget {
  const OpencodeMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => ValueListenableBuilder<Locale?>(
        valueListenable: localeMode,
        builder: (_, locale, _) => MaterialApp.router(
          title: 'opencode',
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
