import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb, kDebugMode, kProfileMode;
import 'package:flutter_displaymode/flutter_displaymode.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'app_router.dart';
import 'app_state.dart';
import 'core/cache/cache_store.dart';
import 'core/logging/app_logger.dart';
import 'core/logging/perf_probe.dart';
import 'core/notifications/notification_service.dart';
import 'core/net/system_font_weight.dart';
import 'core/platform/keepalive_controller.dart';
import 'l10n/gen/app_localizations.dart';
import 'ui/theme.dart';

final appRouter = buildRouter(connectionStore);
bool _appStarted = false;

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (details) {
      AppLogger.I.e('Flutter', '${details.exceptionAsString()}\n${details.stack}');
    };
    ErrorWidget.builder = (details) {
      AppLogger.I.e('Render', '${details.exceptionAsString()}\n${details.stack}');
      return ErrorWidget(details.exception);
    };
    await AppLogger.I.init();
    if (Platform.isAndroid) {
      try {
        await FlutterDisplayMode.setHighRefreshRate();
      } catch (e) {
        AppLogger.I.e('DisplayMode', 'setHighRefreshRate failed: $e');
      }
    }
    await connectionStore.load();
    // One-time migration of legacy SharedPreferences blobs into the file
    // cache. MUST run before wireServerStore() (which triggers connect() →
    // _loadCache) and after connectionStore.load() (profile ids enumerable).
    if (!kIsWeb) {
      await FileCacheStore.migrateFromPrefs(
        profileIds: connectionStore.servers.map((s) => s.id).toList(),
      );
    }
    await modelHideStore.load();
    await defaultAgentModelStore.load();
    wireServerStore();
    NotificationService.onSessionNotificationTap = _openSessionFromNotification;
    await NotificationService.init();
    await SystemFontWeight.init();
    await initSettings();
    KeepaliveController.I.init();
    if (kDebugMode || kProfileMode) PerfProbe.I.start();
    runApp(const OpenBuilderApp());
    _appStarted = true;
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_handleLaunchNotification()));
  }, (error, stack) {
    AppLogger.I.e('Zone', 'unhandled: $error\n$stack');
    if (!_appStarted) {
      final loc = resolveActiveLocale();
      runApp(MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, size: 48),
                  const SizedBox(height: 16),
                  Text(loc.languageCode == 'zh' ? '应用启动失败' : 'App failed to start',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text('$error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ],
              ),
            ),
          ),
        ),
      ));
    }
  });
}

void _openSessionFromNotification(String sid) {
  final host = serverStore.cardHostSessionIdOf(sid);
  if (serverStore.sessionById(host) == null) {
    AppLogger.I.i('Notif', 'tap dropped, unknown session: $sid');
    return;
  }
  if (!_appStarted) {
    WidgetsBinding.instance.addPostFrameCallback(
        (_) => openSessionFromNotification(appRouter, host));
    return;
  }
  openSessionFromNotification(appRouter, host);
}

/// Cold-launch path: a notification tap started the process. The conversation
/// page strands on its unavailable branch when the store has no client, so
/// wait for the active connection (bounded — a slow/failed connect drops the
/// deep-link and leaves the user on the session list instead of surprising
/// them with a late push minutes later).
Future<void> _handleLaunchNotification() async {
  final sid = await NotificationService.consumeLaunchNotification();
  if (sid == null) return;
  if (!serverStore.connected) {
    final ready = Completer<void>();
    void listener() {
      if (serverStore.connected && !ready.isCompleted) ready.complete();
    }
    serverStore.addListener(listener);
    try {
      await ready.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      AppLogger.I.i('Notif', 'launch tap dropped (connect timeout): $sid');
      return;
    } finally {
      serverStore.removeListener(listener);
    }
  }
  _openSessionFromNotification(sid);
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
  void didChangeLocales(List<Locale>? locales) {
    if (localeMode.value == null) {
      serverStore.activeLoc = lookupAppLocalizations(resolveActiveLocale());
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeMode,
      builder: (_, mode, _) => ValueListenableBuilder<Locale?>(
        valueListenable: localeMode,
        builder: (_, _, _) => MaterialApp.router(
          title: 'Open Builder',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: mode,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          supportedLocales: const [Locale('zh'), Locale('en')],
          locale: resolveActiveLocale(),
          routerConfig: appRouter,
        ),
      ),
    );
  }
}
