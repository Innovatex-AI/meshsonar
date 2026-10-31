// flutter_local_notifications behind [LocalNotifications].
//
// Why this plugin: BSD-3-Clause, maintained (22.x, MaikuB), it is what the official MeshCore app and MeshCore Open ship
// (design doc 4.1), iOS permissions can be requested later and separately from init, `threadIdentifier` gives per-
// conversation threads and the system's own grouped summary on iOS, and the same plugin starts the Android foreground
// service, so one dependency covers both OSes. Alternatives rejected: awesome_notifications (heavier, push-oriented, more
// permissions), plain `UNUserNotificationCenter` channels (no Android, we would write both sides).
//
// Not covered by any test on this machine (no device): the unit tests use a fake LocalNotifications. See
// docs/BACKGROUND_BLE_SPIKE.md for what was and was not verified on a device.
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

import 'local_notifications.dart';

class PluginLocalNotifications implements LocalNotifications {
  final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  static const _badgeChannel = MethodChannel('app.meshsonar/alerts');
  static const _androidChannelId = 'messages';
  bool _ready = false;

  @override
  Future<void> init({required void Function(String payload) onTap}) async {
    if (_ready) return;
    const darwin = DarwinInitializationSettings(
      // Never prompt from init: the person is asked later, at a moment they chose, after our own explanation.
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _p.initialize(
      settings: const InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: (r) {
        final p = r.payload;
        if (p != null && p.isNotEmpty) onTap(p);
      },
    );
    _ready = true;
  }

  @override
  Future<String?> launchPayload() async {
    final d = await _p.getNotificationAppLaunchDetails();
    if (d == null || !d.didNotificationLaunchApp) return null;
    final p = d.notificationResponse?.payload;
    return (p == null || p.isEmpty) ? null : p;
  }

  @override
  Future<NotificationPermission> permission() async {
    if (Platform.isIOS) {
      final o = await _p.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()?.checkPermissions();
      if (o == null) return NotificationPermission.notDetermined;
      if (o.isEnabled) return NotificationPermission.granted;
      // checkPermissions cannot tell "never asked" from "denied". Our own record of having asked decides (AlertPrefs.asked),
      // see AlertsController.permission.
      return NotificationPermission.notDetermined;
    }
    if (Platform.isAndroid) {
      final on = await _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.areNotificationsEnabled();
      return on == true ? NotificationPermission.granted : NotificationPermission.notDetermined;
    }
    return NotificationPermission.restricted;
  }

  @override
  Future<NotificationPermission> requestPermission() async {
    if (Platform.isIOS) {
      final ok = await _p
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
      return ok == true ? NotificationPermission.granted : NotificationPermission.denied;
    }
    if (Platform.isAndroid) {
      final ok = await _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      return ok == true ? NotificationPermission.granted : NotificationPermission.denied;
    }
    return NotificationPermission.restricted;
  }

  @override
  Future<void> show(AlertNotification n) async {
    final android = AndroidNotificationDetails(
      _androidChannelId,
      'Messages',
      channelDescription: 'New chat messages from your radio',
      importance: Importance.high,
      priority: Priority.high,
      groupKey: 'app.meshsonar.chat',
      playSound: !n.silent,
      enableVibration: n.vibrate && !n.silent,
      category: AndroidNotificationCategory.message,
      visibility: NotificationVisibility.private,
    );
    final darwin = DarwinNotificationDetails(
      threadIdentifier: n.threadId,
      presentSound: !n.silent,
      badgeNumber: n.badge,
      // Never time-sensitive or critical: Focus / Do Not Disturb must be able to hold these back.
      interruptionLevel: InterruptionLevel.active,
    );
    await _p.show(
      id: n.id,
      title: n.title,
      body: n.body,
      notificationDetails: NotificationDetails(android: android, iOS: darwin),
      payload: n.payload,
    );
  }

  @override
  Future<void> cancelConversation(int id) => _p.cancel(id: id);

  @override
  Future<void> cancelAll() => _p.cancelAll();

  @override
  Future<void> setBadge(int count) async {
    if (!Platform.isIOS) return;
    try {
      await _badgeChannel.invokeMethod<void>('setBadge', count);
    } catch (_) {}
  }

  @override
  Future<bool> openSystemSettings() async {
    if (Platform.isIOS) return launchUrl(Uri.parse('app-settings:'));
    if (Platform.isAndroid) {
      try {
        await _badgeChannel.invokeMethod<void>('openNotificationSettings');
        return true;
      } catch (_) {
        return false;
      }
    }
    return false;
  }
}
