// GPS for the real app, via the geolocator package. High accuracy, every metre counts on a wardrive. The app wraps
// this in FilteredLocationSource (lib/core/position_filter.dart) so parked jitter and poor fixes never reach a ping.
// Unknown values stay null (the plugin reports 0 or negative for "not available").
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../radio/radio_api.dart';
import 'geolocator_stream_hub.dart';

/// A remembered position is only good for a ping when it is this fresh: a fix from an hour ago is where the car WAS.
const Duration lastKnownMaxAge = Duration(seconds: 30);

/// A fix handed back by `current()` must have been taken this recently.
const Duration currentFixMaxAge = Duration(seconds: 15);

/// Whether a remembered fix taken at [at] may still stand in for a live one at [now].
bool lastKnownIsFresh(DateTime at, DateTime now, {Duration maxAge = lastKnownMaxAge}) {
  final age = now.difference(at);
  return age <= maxAge && age >= -maxAge;
}

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
        // Altitude is only trusted with a positive vertical accuracy (0 = the platform did not measure it).
        altitudeM: p.altitudeAccuracy > 0 && p.altitude.isFinite ? p.altitude : null,
        altitudeAccuracyM: _positive(p.altitudeAccuracy),
        // Course is valid only while moving; iOS reports -1 when unknown.
        courseDeg: p.headingAccuracy > 0 && p.heading >= 0 && p.heading < 360 ? p.heading : null,
        courseAccuracyDeg: _positive(p.headingAccuracy),
        speedAccuracyMps: _positive(p.speedAccuracy),
      );

  @override
  Stream<GeoFix> get fixes => GeolocatorStreamHub.shared.stream(HubProfile.drive, _settings(), key: 'drive').map(_toFix);

  @override
  Future<GeoFix?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition(locationSettings: _settings()).timeout(const Duration(seconds: 15));
      // iOS can answer with its cached position, minutes old, while the app is in the background: that is where the car
      // WAS. Treat it as no fix.
      if (!lastKnownIsFresh(p.timestamp, DateTime.now(), maxAge: currentFixMaxAge)) return null;
      return _toFix(p);
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        // Never a stale one: the ping would be placed where the car was long ago.
        return last == null || !lastKnownIsFresh(last.timestamp, DateTime.now()) ? null : _toFix(last);
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
