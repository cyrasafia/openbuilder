import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../app_state.dart';
import '../logging/app_logger.dart';
import '../notifications/notification_service.dart';
import '../session/server_store.dart';
import 'android_keepalive.dart';

class KeepaliveBackend {
  Future<void> start(int count) => AndroidKeepalive.start(count);

  Future<void> updateCount(int count) => AndroidKeepalive.updateCount(count);

  Future<void> stop() => AndroidKeepalive.stop();

  Future<bool?> requestPermission() =>
      NotificationService.requestAndroidPermissionIfNeeded();

  Future<bool> notificationsEnabled() =>
      NotificationService.notificationsEnabled();
}

class KeepaliveController with WidgetsBindingObserver {
  KeepaliveController._();

  static final KeepaliveController I = KeepaliveController._();
  static const _tag = 'Keepalive';

  @visibleForTesting
  static Duration armTimeout = const Duration(seconds: 15);

  bool _initialized = false;
  ServerStore? _store;
  KeepaliveBackend? _backend;
  int _streaming = 0;
  bool _fgsOn = false;
  bool _startInFlight = false;
  bool _permGranted = false;
  Timer? _armTimer;

  ServerStore get _activeStore => _store ?? serverStore;

  bool get observationActive => _backend != null && _permGranted && _fgsOn;

  void init({ServerStore? store, KeepaliveBackend? backend}) {
    if (_initialized) return;
    _initialized = true;
    final supported = backend != null || (!kIsWeb && Platform.isAndroid);
    if (!supported) return;
    _store = store;
    _backend = backend ?? KeepaliveBackend();
    WidgetsBinding.instance.addObserver(this);
    _activeStore.addListener(_onStoreChanged);
    _streaming = _activeStore.streamingSessionCount;
  }

  Future<void> onUserPromptSent() async {
    final backend = _backend;
    if (backend == null) return;
    final granted = await backend.requestPermission();
    if (granted == true) {
      _permGranted = true;
      _arm();
      unawaited(_tryStart());
    }
  }

  void _arm() {
    _armTimer?.cancel();
    _armTimer = Timer(armTimeout, () {
      if (_fgsOn && _streaming <= 0) {
        AppLogger.I.i(_tag, 'armed watch expired without a run');
        unawaited(_stop());
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _onForeground();
  }

  void _onForeground() {
    if (_fgsOn || _streaming <= 0) return;
    unawaited(_tryStart());
  }

  void _onStoreChanged() {
    final backend = _backend;
    if (backend == null) return;
    final store = _activeStore;
    final n = store.streamingSessionCount;
    if (!store.connected) {
      unawaited(_stop());
      _streaming = n;
      return;
    }
    if (n == _streaming) return;
    final wasZero = _streaming == 0;
    _streaming = n;
    if (n > 0) {
      if (wasZero && !_fgsOn) {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == null ||
            state == AppLifecycleState.resumed ||
            state == AppLifecycleState.inactive) {
          unawaited(_tryStart());
        }
      } else if (_fgsOn) {
        unawaited(backend.updateCount(n));
      }
    } else if (_fgsOn) {
      unawaited(_stop());
    }
  }

  Future<void> _tryStart() async {
    final backend = _backend;
    if (backend == null || _fgsOn || _startInFlight) return;
    _startInFlight = true;
    try {
      final enabled = await backend.notificationsEnabled();
      _permGranted = enabled;
      if (!enabled) {
        AppLogger.I.w(_tag, 'notifications not granted, no keepalive');
        return;
      }
      if (_streaming <= 0 && !(_armTimer?.isActive ?? false)) return;
      final count = _streaming > 0 ? _streaming : 1;
      try {
        await backend.start(count);
      } on PlatformException {
        return;
      } on MissingPluginException {
        return;
      }
      _fgsOn = true;
      AppLogger.I.i(_tag, 'watching streaming=$_streaming');
      if (_streaming <= 0 && !(_armTimer?.isActive ?? false)) {
        unawaited(_stop());
      }
    } finally {
      _startInFlight = false;
    }
  }

  Future<void> _stop() async {
    final backend = _backend;
    if (backend == null || !_fgsOn) return;
    _fgsOn = false;
    await backend.stop();
    final store = _activeStore;
    if (!store.appForeground && store.connected) {
      unawaited(store.pause());
    }
  }

  @visibleForTesting
  bool get fgsOnForTesting => _fgsOn;

  @visibleForTesting
  void disposeForTesting() {
    _activeStore.removeListener(_onStoreChanged);
    WidgetsBinding.instance.removeObserver(this);
    _armTimer?.cancel();
    _armTimer = null;
    _store = null;
    _backend = null;
    _fgsOn = false;
    _startInFlight = false;
    _permGranted = false;
    _initialized = false;
  }
}
