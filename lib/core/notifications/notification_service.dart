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

  static void Function(String sessionId)? onSessionNotificationTap;

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
      onDidReceiveNotificationResponse: (response) {
        final sid = response.payload;
        if (sid != null && sid.isNotEmpty) {
          onSessionNotificationTap?.call(sid);
        }
      },
    );
    // iOS 14.2+ requires an explicit permissions request to trigger the
    // system authorization prompt; the Info.plist key alone is not enough.
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      await ios.requestPermissions(alert: true, badge: true, sound: true);
    }
    // Migration: legacy channels merged into 'tasks' (design-notification-
    // channels); deleting also drops their unread tray notifications.
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      for (final id in const ['agent_complete', 'permission', 'question']) {
        try {
          await android.deleteNotificationChannel(id);
        } catch (_) {}
      }
    }
    _initialized = true;
  }

  static Future<AppLocalizations> _loc() =>
      AppLocalizations.delegate.load(resolveActiveLocale());

  // The system freezes behavioral settings (importance/sound) at channel
  // creation but applies name/description updates on re-submit; the plugin
  // re-submits on every show(), so the localized name/description follow the
  // active locale from one notification to the next.
  static Future<AndroidNotificationDetails> _taskChannel() async {
    final loc = await _loc();
    return AndroidNotificationDetails(
      'tasks',
      loc.notifChannelTasksName,
      importance: Importance.high,
      priority: Priority.high,
      channelDescription: loc.notifChannelTasksDesc,
    );
  }

  static Future<void> _show(
    int id,
    String title,
    String body,
    AndroidNotificationDetails channel,
    String payload,
  ) async {
    if (debugFakeShow) return;
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
    try {
      await _show(
        _runNotifId(sid),
        'Open Builder',
        loc.notifRunCompleteBody(title),
        await _taskChannel(),
        sid,
      );
    } catch (_) {
      _pendingRun.remove(sid);
      rethrow;
    }
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
    try {
      await _show(
        _cardNotifId(cardSid),
        loc.notifPermissionTitle,
        loc.notifPermissionBody(title, permissionTitle(loc, p)),
        await _taskChannel(),
        cardSid,
      );
    } catch (_) {
      _pendingCards.remove(cardSid);
      rethrow;
    }
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
    try {
      await _show(
        _cardNotifId(cardSid),
        loc.notifQuestionTitle,
        loc.notifQuestionBody(title, h),
        await _taskChannel(),
        cardSid,
      );
    } catch (_) {
      _pendingCards.remove(cardSid);
      rethrow;
    }
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
  /// 并发调用共享同一个在途请求：弹窗期间的后来者等待同一次用户答复，
  /// 不会读到「已问过 ∧ 未授权」的中间态。
  static Future<bool?> requestAndroidPermissionIfNeeded() {
    final inFlight = _permRequestInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRequestAndroidPermissionIfNeeded();
    _permRequestInFlight = future;
    future.whenComplete(() => _permRequestInFlight = null).ignore();
    return future;
  }

  static Future<bool?>? _permRequestInFlight;

  static Future<bool?> _doRequestAndroidPermissionIfNeeded() async {
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

  /// Read-only check: never shows the permission dialog (design-notification-
  /// channels CH-5 — the dialog is only tied to the send action).
  static Future<bool> notificationsEnabled() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    if (!_initialized) await init();
    if (!_initialized) return false;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return false;
    return await android.areNotificationsEnabled() ?? false;
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
  static bool debugFakeShow = false;

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

  static Future<String?> consumeLaunchNotification() async {
    if (kIsWeb || !_initialized) return null;
    final NotificationAppLaunchDetails? details;
    try {
      details = await _plugin.getNotificationAppLaunchDetails();
    } catch (_) {
      return null;
    }
    if (details == null || !details.didNotificationLaunchApp) return null;
    final sid = details.notificationResponse?.payload;
    if (sid == null || sid.isEmpty) return null;
    return sid;
  }
}
