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

  Future<bool> requestPermission() =>
      NotificationService.requestAndroidPermissionIfNeeded();
}

class KeepaliveController with WidgetsBindingObserver {
  KeepaliveController._();

  static final KeepaliveController I = KeepaliveController._();
  static const _tag = 'Keepalive';
  static Duration lingerWindow = const Duration(minutes: 3);
  static Duration lingerTickInterval = const Duration(seconds: 15);

  bool _initialized = false;
  ServerStore? _store;
  KeepaliveBackend? _backend;
  int _streaming = 0;
  bool _fgsOn = false;
  bool _permDenied = false;
  DateTime? _lingerStartedAt;
  Timer? _lingerTimer;

  ServerStore get _activeStore => _store ?? serverStore;

  bool get lingering => _lingerStartedAt != null;

  bool get observationActive =>
      _backend != null && !_permDenied && (_fgsOn || lingering);

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
      _teardownLinger();
      unawaited(_stop());
      _streaming = n;
      return;
    }
    if (n == _streaming) return;
    final wasZero = _streaming == 0;
    _streaming = n;
    if (n > 0) {
      _teardownLinger();
      if (wasZero && !_fgsOn) {
        final state = WidgetsBinding.instance.lifecycleState;
        if (state == null || state == AppLifecycleState.resumed) {
          unawaited(_tryStart());
        }
      } else if (_fgsOn) {
        unawaited(backend.updateCount(n));
      }
    } else if (_fgsOn) {
      _enterLinger();
    }
  }

  Future<void> _tryStart() async {
    final backend = _backend;
    if (backend == null || _fgsOn) return;
    final granted = await backend.requestPermission();
    if (!granted) {
      _permDenied = true;
      AppLogger.I.w(_tag, 'notification permission denied, no keepalive');
      return;
    }
    if (_streaming <= 0) return;
    try {
      await backend.start(_streaming);
    } on PlatformException {
      return;
    } on MissingPluginException {
      return;
    }
    _fgsOn = true;
    AppLogger.I.i(_tag, 'watching streaming=$_streaming');
    if (_streaming <= 0) _enterLinger();
  }

  void _enterLinger() {
    if (!_fgsOn) return;
    _lingerStartedAt ??= DateTime.now();
    _lingerTimer?.cancel();
    _lingerTimer =
        Timer.periodic(lingerTickInterval, (_) => _lingerTickFn());
    _lingerTickFn();
    AppLogger.I.i(_tag, 'linger start (streaming=0, cards may be pending)');
  }

  void _lingerTickFn() {
    final startedAt = _lingerStartedAt;
    if (startedAt == null) return;
    final elapsed = DateTime.now().difference(startedAt);
    final slotsEmpty = !NotificationService.hasPendingSlots;
    if (slotsEmpty || elapsed >= lingerWindow) {
      AppLogger.I.i(
          _tag, 'linger end (${slotsEmpty ? 'slots empty' : 'expired'})');
      _teardownLinger();
      unawaited(_stop());
    }
  }

  void _teardownLinger() {
    _lingerTimer?.cancel();
    _lingerTimer = null;
    _lingerStartedAt = null;
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
    _teardownLinger();
    _activeStore.removeListener(_onStoreChanged);
    WidgetsBinding.instance.removeObserver(this);
    _store = null;
    _backend = null;
    _fgsOn = false;
    _permDenied = false;
    _initialized = false;
  }
}
