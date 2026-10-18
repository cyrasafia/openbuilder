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
  bool _toggleOn = false;
  Timer? _armTimer;

  ServerStore get _activeStore => _store ?? serverStore;

  bool get observationActive =>
      _backend != null && _permGranted && _fgsOn;

  void init({ServerStore? store, KeepaliveBackend? backend}) {
    if (_initialized) return;
    _initialized = true;
    final supported = backend != null || (!kIsWeb && Platform.isAndroid);
    if (!supported) return;
    _store = store;
    _backend = backend ?? KeepaliveBackend();
    WidgetsBinding.instance.addObserver(this);
    _activeStore.addListener(_onStoreChanged);
    _toggleOn = taskCompleteNotify.value;
    taskCompleteNotify.addListener(_onToggleChanged);
    _streaming = _activeStore.streamingSessionCount;
  }

  /// Send-action hook: arm the watch so the FGS starts at send time instead
  /// of racing the busy event (D26 arm-at-send, S37). Pure arming — the
  /// permission request lives on the settings toggle (D29); no-op when the
  /// toggle is off (D27) or the backend is unsupported.
  void armOnUserPromptSent() {
    final backend = _backend;
    if (backend == null || !_toggleOn) return;
    _arm();
    unawaited(_tryStart());
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

  void _onToggleChanged() {
    final on = taskCompleteNotify.value;
    if (on == _toggleOn) return;
    _toggleOn = on;
    if (!on) {
      unawaited(_stop());
      return;
    }
    _streaming = _activeStore.streamingSessionCount;
    if (_streaming <= 0) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state == null || state == AppLifecycleState.resumed) {
      unawaited(_tryStart());
    }
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
    if (!_toggleOn) return;
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
    if (backend == null || !_toggleOn || _fgsOn || _startInFlight) return;
    _startInFlight = true;
    try {
      final enabled = await backend.notificationsEnabled();
      _permGranted = enabled;
      if (!enabled) {
        AppLogger.I.w(_tag, 'notifications not granted, no keepalive');
        return;
      }
      if (!_toggleOn ||
          (_streaming <= 0 && !(_armTimer?.isActive ?? false))) {
        return;
      }
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
    taskCompleteNotify.removeListener(_onToggleChanged);
    WidgetsBinding.instance.removeObserver(this);
    _armTimer?.cancel();
    _armTimer = null;
    _store = null;
    _backend = null;
    _fgsOn = false;
    _startInFlight = false;
    _permGranted = false;
    _toggleOn = false;
    _initialized = false;
  }
}
