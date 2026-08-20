import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/app_logger.dart';

/// Turns on WebAuthn (passkeys) for the OAuth login WebView.
///
/// Android only: the system WebView keeps WebAuthn disabled unless the host
/// app opts in per-WebView (androidx.webkit `WEB_AUTHENTICATION_SUPPORT_FOR_APP`).
/// webview_flutter doesn't expose that switch, so it is applied natively by
/// walking the activity's view tree — see `MainActivity.enableWebAuthnForAttachedWebViews`.
/// Call after the login WebView mounts; retries while the platform view is
/// still attaching. Every failure degrades to today's behaviour (the page's
/// passkey button just stays inert) — see design-passkey-login.md.
class WebviewPasskey {
  static const _channel = MethodChannel('com.openbuilder.app/passkey');
  static const _attempts = 15;
  static const _delay = Duration(milliseconds: 200);

  static Future<void> enableForLoginWebView() async {
    if (kIsWeb || !Platform.isAndroid) return;
    for (var i = 0; i < _attempts; i++) {
      final status = await _invoke();
      switch (status) {
        case 'ok':
          AppLogger.I.i('WebviewPasskey', 'webauthn enabled for login webview');
          return;
        case 'unsupported':
          AppLogger.I.w('WebviewPasskey', 'webview lacks WEB_AUTHENTICATION');
          return;
        case 'no_view':
          break;
        case null:
          return;
      }
      await Future<void>.delayed(_delay);
    }
    AppLogger.I.w('WebviewPasskey', 'no attached webview found; giving up');
  }

  static Future<String?> _invoke() {
    return _channel
        .invokeMethod<String>('enableForAttachedWebViews')
        .catchError((Object e) {
      AppLogger.I.w('WebviewPasskey', 'invoke failed: $e');
      return null;
    });
  }
}
