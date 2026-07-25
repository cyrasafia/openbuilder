import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/connection/connection_store.dart';
import 'core/models/default_agent_model_store.dart';
import 'core/models/model_hide_store.dart';
import 'core/session/server_store.dart';

final ConnectionStore connectionStore = ConnectionStore();
final ServerStore serverStore = ServerStore();
final ModelHideStore modelHideStore = ModelHideStore();
final DefaultAgentModelStore defaultAgentModelStore = DefaultAgentModelStore();
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);
final ValueNotifier<Locale?> localeMode = ValueNotifier(null);

/// Resolve the active app locale for MaterialApp's `localeResolutionCallback`
/// (single source of truth so explicit selection and system-mode resolution
/// stay consistent). The notification service will share this helper in P6.
/// Falls back to `en` for unsupported device locales — this effort adds
/// English, so an unknown-locale user should see English rather than Chinese.
Locale resolveActiveLocale() {
  final chosen = localeMode.value ??
      WidgetsBinding.instance.platformDispatcher.locale;
  for (final s in const [Locale('zh'), Locale('en')]) {
    if (s.languageCode == chosen.languageCode) return s;
  }
  return const Locale('en');
}
final ValueNotifier<bool> showThinking = ValueNotifier(false);

/// Load persisted theme/locale preferences and wire up change listeners to
/// auto-save. Call once after [connectionStore] is loaded, before [runApp].
Future<void> initSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final themeIdx = prefs.getInt('themeMode');
  if (themeIdx != null && themeIdx >= 0 && themeIdx < ThemeMode.values.length) {
    themeMode.value = ThemeMode.values[themeIdx];
  }
  final localeStr = prefs.getString('locale');
  if (localeStr != null) {
    localeMode.value = Locale(localeStr);
  }
  final showThinkingVal = prefs.getBool('showThinking');
  if (showThinkingVal != null) {
    showThinking.value = showThinkingVal;
  }
  serverStore.reasoningVisibleInPreview = showThinking.value;
  themeMode.addListener(() => prefs.setInt('themeMode', themeMode.value.index));
  localeMode.addListener(() {
    final l = localeMode.value;
    if (l != null) {
      prefs.setString('locale', l.languageCode);
    } else {
      prefs.remove('locale');
    }
  });
  showThinking.addListener(() => prefs.setBool('showThinking', showThinking.value));
  showThinking.addListener(
      () => serverStore.reasoningVisibleInPreview = showThinking.value);
}

/// Bind the active server in [connectionStore] to [serverStore] (connect on
/// change / disconnect when none). Idempotent; call once after [connectionStore]
/// is loaded.
void wireServerStore() {
  void sync() {
    final active = connectionStore.active;
    if (active != null) {
      serverStore.connect(active);
    } else {
      serverStore.disconnect();
    }
  }

  connectionStore.addListener(sync);
  sync();
}
