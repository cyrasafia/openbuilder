import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'core/connection/connection_store.dart';
import 'core/logging/app_logger.dart';
import 'core/models/default_agent_model_store.dart';
import 'core/models/model_hide_store.dart';
import 'core/session/server_store.dart';
import 'core/settings/sync_settings.dart';
import 'l10n/gen/app_localizations.dart';

final ConnectionStore connectionStore = ConnectionStore();
final ServerStore serverStore = ServerStore();
final ModelHideStore modelHideStore = ModelHideStore();
final DefaultAgentModelStore defaultAgentModelStore = DefaultAgentModelStore();
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);
final ValueNotifier<Locale?> localeMode = ValueNotifier(null);

Locale? _lastLoggedLocale;

/// Resolve the active app locale for MaterialApp's `localeResolutionCallback`
/// (single source of truth so explicit selection and system-mode resolution
/// stay consistent). The notification service will share this helper in P6.
/// Falls back to `en` for unsupported device locales — this effort adds
/// English, so an unknown-locale user should see English rather than Chinese.
Locale resolveActiveLocale() {
  final chosen = localeMode.value ??
      WidgetsBinding.instance.platformDispatcher.locale;
  Locale result = const Locale('en');
  for (final s in const [Locale('zh'), Locale('en')]) {
    if (s.languageCode == chosen.languageCode) {
      result = s;
      break;
    }
  }
  if (_lastLoggedLocale != result) {
    _lastLoggedLocale = result;
    final pd = WidgetsBinding.instance.platformDispatcher;
    AppLogger.I.i('Locale', 'localeMode=${localeMode.value} '
        'platformDispatcher.locale=${pd.locale} '
        'platformDispatcher.locales=${pd.locales} '
        'dart.io.Platform.localeName=${kIsWeb ? 'n/a(web)' : Platform.localeName} '
        'chosen=$chosen resolved=$result');
  }
  return result;
}
final ValueNotifier<bool> showThinking = ValueNotifier(false);

/// Resolve the persisted locale string. On native it reads from the durable
/// file store; on web from SharedPreferences. On the first launch after
/// upgrade a legacy SharedPreferences `locale` is migrated into the file
/// store, and a `localeMigrated` marker is written to the file store so the
/// decision never depends on the (unreliable) `SharedPreferences` clear —
/// otherwise re-selecting "System" could be resurrected by re-migration if
/// the legacy `prefs.remove('locale')` failed to persist.
Future<String?> resolvePersistedLocale(
    SharedPreferences prefs, bool useFile) async {
  if (!useFile) return prefs.getString('locale');
  final fileValue = SyncSettings.I.getString('locale');
  if (fileValue != null) return fileValue;
  if (SyncSettings.I.getString('localeMigrated') != null) return null;
  final legacy = prefs.getString('locale');
  if (legacy != null) {
    SyncSettings.I.setString('locale', legacy);
    SyncSettings.I.setString('localeMigrated', '1');
    await prefs.remove('locale');
    return legacy;
  }
  SyncSettings.I.setString('localeMigrated', '1');
  return null;
}

/// Load persisted theme/locale preferences and wire up change listeners to
/// auto-save. Call once after [connectionStore] is loaded, before [runApp].
Future<void> initSettings() async {
  final prefs = await SharedPreferences.getInstance();
  final useFile = !kIsWeb;
  if (useFile) {
    await SyncSettings.I.init(await getApplicationDocumentsDirectory());
  }
  final themeIdx = prefs.getInt('themeMode');
  if (themeIdx != null && themeIdx >= 0 && themeIdx < ThemeMode.values.length) {
    themeMode.value = ThemeMode.values[themeIdx];
  }
  final localeStr = await resolvePersistedLocale(prefs, useFile);
  if (localeStr != null) {
    localeMode.value = Locale(localeStr);
  }
  final showThinkingVal = prefs.getBool('showThinking');
  if (showThinkingVal != null) {
    showThinking.value = showThinkingVal;
  }
  serverStore.reasoningVisibleInPreview = showThinking.value;
  serverStore.activeLoc = lookupAppLocalizations(resolveActiveLocale());
  themeMode.addListener(() => prefs.setInt('themeMode', themeMode.value.index));
  localeMode.addListener(() {
    final l = localeMode.value;
    if (l != null) {
      if (useFile) {
        SyncSettings.I.setString('locale', l.languageCode);
      } else {
        prefs.setString('locale', l.languageCode);
      }
    } else {
      if (useFile) {
        SyncSettings.I.remove('locale');
      } else {
        prefs.remove('locale');
      }
    }
    // Push the new locale's strings down so cached session-list previews
    // ("You: " prefix, attachment fallback) and worktree labels recompute
    // instead of showing stale-language text.
    serverStore.activeLoc = lookupAppLocalizations(resolveActiveLocale());
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
