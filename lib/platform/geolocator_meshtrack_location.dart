// The phone position for MeshTrack sharing BETWEEN drives (battery plan A8). Its own, cheaper request instead of the drive source:
// best accuracy with a 20 m distance filter, iOS auto-pause allowed, ActivityType.otherNavigation, foreground only (sharing without a
// drive only runs while the app is in front, lib/app/meshtrack_wiring.dart). It asks the hub for HubProfile.track, which ranks
// above the idle region watcher and below a drive: it never pushes the idle watcher up to drive settings, and a drive still gets
// its own settings while it runs.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../radio/radio_api.dart';
import 'geolocator_stream_hub.dart';

class GeolocatorMeshTrackLocationSource implements LocationSource {
  final GeolocatorStreamHub hub;
  final TargetPlatform? _platform;

  /// The underlying drive-grade source for [current] and [ensurePermission] (never its stream).
  final LocationSource? oneShot;

  GeolocatorMeshTrackLocationSource({GeolocatorStreamHub? hub, this.oneShot, @visibleForTesting TargetPlatform? platform})
      : hub = hub ?? GeolocatorStreamHub.shared,
        // ignore: prefer_initializing_formals
        _platform = platform;

  static const int distanceFilterM = 20;

  LocationSettings settings() {
    final target = _platform ?? defaultTargetPlatform;
    if (kIsWeb) return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: distanceFilterM);
    switch (target) {
      case TargetPlatform.android:
        return AndroidSettings(
            accuracy: LocationAccuracy.best, distanceFilter: distanceFilterM, intervalDuration: const Duration(seconds: 5));
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.best,
          activityType: ActivityType.otherNavigation,
          distanceFilter: distanceFilterM,
          pauseLocationUpdatesAutomatically: true,
          showBackgroundLocationIndicator: false,
          allowBackgroundLocationUpdates: false,
        );
      default:
        return const LocationSettings(accuracy: LocationAccuracy.best, distanceFilter: distanceFilterM);
    }
  }

  @override
  Stream<GeoFix> get fixes => hub.stream(HubProfile.track, settings(), key: 'meshtrack').map((p) => GeoFix(
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: (p.accuracy.isNaN || p.accuracy <= 0) ? null : p.accuracy,
        speedMps: p.speedAccuracy > 0 ? (p.speed.isNaN || p.speed < 0 ? null : p.speed) : (p.speed > 0 ? p.speed : null),
        at: p.timestamp.toUtc(),
        courseDeg: p.headingAccuracy > 0 && p.heading >= 0 && p.heading < 360 ? p.heading : null,
        courseAccuracyDeg: p.headingAccuracy > 0 ? p.headingAccuracy : null,
      ));

  @override
  Future<GeoFix?> current() async => oneShot?.current();

  @override
  Future<bool> ensurePermission() async => await oneShot?.ensurePermission() ?? false;
}
