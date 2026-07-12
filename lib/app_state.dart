import 'package:flutter/material.dart';

import 'core/connection/connection_store.dart';

final ConnectionStore connectionStore = ConnectionStore();
final ValueNotifier<ThemeMode> themeMode = ValueNotifier(ThemeMode.dark);
