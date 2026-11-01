// Keeps the radio connection (and so incoming-message alerts) alive while the app is not in front.
//
//  * Android: a foreground service of type connectedDevice with a quiet, ongoing notification ("Connected to <radio>").
//    Android allows BLE in a foreground service without the 10-second limit iOS has. Implemented with
//    flutter_local_notifications' service support (no custom Kotlin service); declared in AndroidManifest.xml.
//    NOT compiled or run on this Mac: the Android toolchain is not installed and Android work is on hold. It is written
//    to compile in principle and kept behind this interface.
//  * iOS: nothing to start. Background behaviour comes from the `bluetooth-central` mode and, experimentally, the wake
//    keeper (lib/platform/ios_wake_keeper.dart). See docs/BACKGROUND_BLE_SPIKE.md.
import 'dart:io' show Platform;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'local_notifications.dart';

abstract class BackgroundLinkService {
  /// True when the platform has such a service.
  bool get supported;
  Future<void> start({required String radioName});
  Future<void> stop();
  bool get running;
}

class NoBackgroundLinkService implements BackgroundLinkService {
  const NoBackgroundLinkService();
  @override
  bool get supported => false;
  @override
  bool get running => false;
  @override
  Future<void> start({required String radioName}) async {}
  @override
  Future<void> stop() async {}
}

class AndroidBackgroundLinkService implements BackgroundLinkService {
  final FlutterLocalNotificationsPlugin _p;
  bool _running = false;
  AndroidBackgroundLinkService([FlutterLocalNotificationsPlugin? p]) : _p = p ?? FlutterLocalNotificationsPlugin();

  @override
  bool get supported => Platform.isAndroid;
  @override
  bool get running => _running;

  @override
  Future<void> start({required String radioName}) async {
    if (!supported || _running) return;
    final android = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return;
    await android.startForegroundService(
      id: foregroundServiceNotificationId,
      title: 'MeshSonar',
      body: 'Connected to $radioName. Messages from your radio can alert you.',
      notificationDetails: const AndroidNotificationDetails(
        'connection',
        'Radio connection',
        channelDescription: 'Shown while MeshSonar keeps your radio connected in the background',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        playSound: false,
        enableVibration: false,
      ),
      startType: AndroidServiceStartType.startSticky,
      foregroundServiceTypes: {AndroidServiceForegroundType.foregroundServiceTypeConnectedDevice},
    );
    _running = true;
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    final android = _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.stopForegroundService();
    _running = false;
  }
}
