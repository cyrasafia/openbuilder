import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_state.dart';
import '../../domain/models.dart';
import '../../l10n/gen/app_localizations.dart';
import '../logging/app_logger.dart';
import '../../ui/l10n_ext.dart';

/// Lightweight local-notification service for alerts when the agent finishes
/// a run or requests a permission (specs §5, plan item 18).
///
/// Notifications fire from store callbacks that have no [BuildContext], so the
/// active locale is resolved via [resolveActiveLocale] (shared with
/// MaterialApp) and the delegate is loaded fresh on each `show` — this keeps
/// the text in sync with the in-app language selection.
class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static const _tag = 'Notif';
  static const _permAskedKey = 'notifPermAsked';

  static final Set<String> _pendingRun = {};
  static final Set<String> _pendingCards = {};

  static bool get hasPendingSlots =>
      _pendingRun.isNotEmpty || _pendingCards.isNotEmpty;

  static int _runNotifId(String sid) => ((sid.hashCode & 0x7fffffff) | 4) ^ 1;

  static int _cardNotifId(String sid) => (sid.hashCode & 0x7fffffff) | 4;

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
    importance: Importance.high,
    priority: Priority.high,
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

  static Future<void> _show(
    int id,
    String title,
    String body,
    AndroidNotificationDetails channel,
    String payload,
  ) async {
    try {
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: channel,
          iOS: DarwinNotificationDetails(),
        ),
        payload: payload,
      );
      AppLogger.I.d(_tag, 'posted id=$id channel=${channel.channelId}');
    } catch (e) {
      AppLogger.I.e(
          _tag, 'post failed id=$id channel=${channel.channelId}: $e');
      rethrow;
    }
  }

  /// Notify that an agent run completed (session went busy → idle).
  static Future<void> notifyRunComplete(
      String sid, String? sessionTitle) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    _pendingRun.add(sid);
    await _show(
      _runNotifId(sid),
      'Open Builder',
      loc.notifRunCompleteBody(title),
      _agentChannel,
      sid,
    );
  }

  /// Notify that a permission request is awaiting the user's response.
  static Future<void> notifyPermission(
      String cardSid, String? sessionTitle, Permission p) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    _pendingCards.add(cardSid);
    await _show(
      _cardNotifId(cardSid),
      loc.notifPermissionTitle,
      loc.notifPermissionBody(title, permissionTitle(loc, p)),
      _permissionChannel,
      cardSid,
    );
  }

  /// Notify that a question is awaiting the user's answer.
  static Future<void> notifyQuestion(
      String cardSid, String? sessionTitle, String? header) async {
    if (!_initialized) await init();
    if (!_initialized) return;
    final loc = await _loc();
    final title = (sessionTitle != null && sessionTitle.isNotEmpty)
        ? sessionTitle
        : loc.convDefaultTitle;
    final h = (header != null && header.isNotEmpty)
        ? header
        : loc.notifQuestionDefaultHeader;
    _pendingCards.add(cardSid);
    await _show(
      _cardNotifId(cardSid),
      loc.notifQuestionTitle,
      loc.notifQuestionBody(title, h),
      _questionChannel,
      cardSid,
    );
  }

  static Future<void> cancelSessionRun(String sid) async {
    _pendingRun.remove(sid);
    await _cancel(_runNotifId(sid));
  }

  static Future<void> cancelCard(String cardSid) async {
    _pendingCards.remove(cardSid);
    await _cancel(_cardNotifId(cardSid));
  }

  static Future<void> cancelSessionAll(String sid) async {
    await cancelSessionRun(sid);
    await cancelCard(sid);
  }

  static Future<void> _cancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {
      return;
    }
  }

  /// null = 未知（初始化失败，不粘死、可重试）；false = 已拒绝；true = 已授权。
  static Future<bool?> requestAndroidPermissionIfNeeded() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    if (!_initialized) await init();
    if (!_initialized) return null;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return null;
    final enabled = await android.areNotificationsEnabled();
    if (enabled == true) return true;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_permAskedKey) ?? false) return false;
    await prefs.setBool(_permAskedKey, true);
    final granted = await android.requestNotificationsPermission();
    return granted ?? false;
  }

  @visibleForTesting
  static void debugSeedSlot({String? run, String? card}) {
    if (run != null) _pendingRun.add(run);
    if (card != null) _pendingCards.add(card);
  }

  @visibleForTesting
  static void debugMarkInitialized() {
    _initialized = true;
  }

  @visibleForTesting
  static void debugResetSlots() {
    _pendingRun.clear();
    _pendingCards.clear();
  }

  static Future<void> reconcileStale() async {
    if (!_initialized || kIsWeb) return;
    final List<ActiveNotification> active;
    try {
      active = await _plugin.getActiveNotifications();
    } catch (_) {
      return;
    }
    for (final n in active) {
      final sid = n.payload;
      final id = n.id;
      if (sid == null || sid.isEmpty || id == null) continue;
      if (id == _runNotifId(sid)) {
        final s = serverStore.sessionById(sid);
        if (s == null || !serverStore.isSessionUnread(sid)) {
          await cancelSessionRun(sid);
        }
      } else if (id == _cardNotifId(sid)) {
        if (!serverStore.hasPendingCard(sid)) {
          await cancelCard(sid);
        }
      }
    }
  }
}
