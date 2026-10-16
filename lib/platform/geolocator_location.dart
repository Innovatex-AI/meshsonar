// GPS for the real app, via the geolocator package. High accuracy, every metre counts on a wardrive.
// Unknown values stay null (the plugin reports 0 or negative for "not available").
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../radio/radio_api.dart';

class GeolocatorLocationSource implements LocationSource {
  /// Shown in the Android foreground-service notification so GPS keeps running with the screen off.
  final bool androidForegroundNotification;
  GeolocatorLocationSource({this.androidForegroundNotification = true});

  LocationSettings _settings() {
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.best);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 1),
          foregroundNotificationConfig: androidForegroundNotification
              ? const ForegroundNotificationConfig(
                  notificationTitle: 'MeshSonar is recording a drive',
                  notificationText: 'Location is used to place each ping on the map.',
                  enableWakeLock: true,
                  setOngoing: true,
                )
              : null,
        );
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: 0,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: defaultTargetPlatform == TargetPlatform.iOS,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: 0);
    }
  }

  static double? _positive(double v) => (v.isNaN || v <= 0) ? null : v;
  static double? _nonNegative(double v) => (v.isNaN || v < 0) ? null : v;

  static GeoFix _toFix(Position p) => GeoFix(
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: _positive(p.accuracy),
        // Speed 0 is a real reading when parked, but only trust it if the platform says it measured speed.
        speedMps: p.speedAccuracy > 0 ? _nonNegative(p.speed) : (p.speed > 0 ? p.speed : null),
        at: p.timestamp.toUtc(),
      );

  @override
  Stream<GeoFix> get fixes => Geolocator.getPositionStream(locationSettings: _settings()).map(_toFix);

  @override
  Future<GeoFix?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition(locationSettings: _settings()).timeout(const Duration(seconds: 15));
      return _toFix(p);
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        return last == null ? null : _toFix(last);
      } catch (_) {
        return null;
      }
    }
  }

  @override
  Future<bool> ensurePermission() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
      return perm == LocationPermission.whileInUse || perm == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }
}
