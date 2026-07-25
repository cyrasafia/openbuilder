import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../ui/l10n_ext.dart';

/// Lightweight local-notification service for foreground alerts when the
/// agent finishes a run or requests a permission (specs §5, plan item 18).
///
/// Notifications fire from store callbacks that have no [BuildContext], so the
/// active locale is resolved via [resolveActiveLocale] (shared with
/// MaterialApp) and the delegate is loaded fresh on each [show] — this keeps
/// the text in sync with the in-app language selection.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
    if (kIsWeb) return;
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings();
    await _plugin.initialize(
      const InitializationSettings(android: androidInit, iOS: iosInit),
    );
    // iOS 14.2+ requires an explicit permissions request to trigger the
    // system authorization prompt; the Info.plist key alone is not enough.
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      await ios.requestPermissions(alert: true, badge: true, sound: true);
    }
    _initialized = true;
  }

  static Future<AppLocalizations> _loc() =>
      AppLocalizations.delegate.load(resolveActiveLocale());

  // Android notification channels are created once with a fixed id; the system
  // ignores later name updates for the same id, so the channel name is NOT
  // localized. A neutral English word is used (only affects the channel label
  // in system settings, not the notification body).
  static const _agentChannel = AndroidNotificationDetails(
    'agent_complete',
    'Agent',
    importance: Importance.low,
    priority: Priority.low,
  );
  static const _permissionChannel = AndroidNotificationDetails(
    'permission',
    'Permission',
    importance: Importance.high,
    priority: Priority.high,
  );
  static const _questionChannel = AndroidNotificationDetails(
    'question',
    'Question',
    importance: Importance.high,
    priority: Priority.high,
  );

  /// Notify that an agent run completed (session went busy → idle).
  static Future<void> notifyRunComplete(String? sessionTitle) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    await _plugin.show(
      0,
      'Open Builder',
      loc.notifRunCompleteBody(title),
      const NotificationDetails(
        android: _agentChannel,
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// Notify that a permission request is awaiting the user's response.
  static Future<void> notifyPermission(
      String? sessionTitle, Permission p) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    await _plugin.show(
      1,
      loc.notifPermissionTitle,
      loc.notifPermissionBody(title, permissionTitle(loc, p)),
      const NotificationDetails(
        android: _permissionChannel,
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// Notify that a question is awaiting the user's answer.
  static Future<void> notifyQuestion(
      String? sessionTitle, String? header) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    final h = (header != null && header.isNotEmpty)
        ? header
        : loc.notifQuestionDefaultHeader;
    await _plugin.show(
      2,
      loc.notifQuestionTitle,
      loc.notifQuestionBody(title, h),
      const NotificationDetails(
        android: _questionChannel,
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}
