import 'package:flutter/material.dart';

import 'core/connection/connection_store.dart';
import 'core/session/server_store.dart';

final ConnectionStore connectionStore = ConnectionStore();
final ServerStore serverStore = ServerStore();
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.system);

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
