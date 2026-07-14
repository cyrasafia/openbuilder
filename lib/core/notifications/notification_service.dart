import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Lightweight local-notification service for foreground alerts when the
/// agent finishes a run or requests a permission (specs §5, plan item 18).
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> init() async {
    if (_initialized) return;
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

  /// Notify that an agent run completed (session went busy → idle).
  static Future<void> notifyRunComplete(String sessionTitle) async {
    if (!_initialized) await init();
    await _plugin.show(
      0,
      'opencode',
      '「$sessionTitle」已完成',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'agent_complete',
          'Agent 完成',
          importance: Importance.low,
          priority: Priority.low,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// Notify that a permission request is awaiting the user's response.
  static Future<void> notifyPermission(
      String sessionTitle, String permTitle) async {
    if (!_initialized) await init();
    await _plugin.show(
      1,
      '需要授权',
      '「$sessionTitle」: $permTitle',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'permission',
          '权限请求',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }

  /// Notify that a question is awaiting the user's answer.
  static Future<void> notifyQuestion(
      String sessionTitle, String header) async {
    if (!_initialized) await init();
    await _plugin.show(
      2,
      '需要回答',
      '「$sessionTitle」: $header',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'question',
          '问题请求',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
    );
  }
}