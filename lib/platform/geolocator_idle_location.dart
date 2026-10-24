// Low-power GPS for idle region detection (lib/core/idle_region_watcher.dart): coarse accuracy, a 500 m distance
// filter, no foreground-service notification on Android (so nothing runs once the app is backgrounded), and on iOS a
// background stream only when "Always" is granted. Drives use GeolocatorLocationSource instead.
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../core/idle_region_watcher.dart';
import '../radio/radio_api.dart';

class GeolocatorIdleLocationSource implements IdleLocationSource {
  final int distanceFilterM;
  GeolocatorIdleLocationSource({this.distanceFilterM = 500});

  LocationSettings _settings(bool background) {
    if (kIsWeb) return LocationSettings(accuracy: LocationAccuracy.low, distanceFilter: distanceFilterM);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return AndroidSettings(accuracy: LocationAccuracy.low, distanceFilter: distanceFilterM, intervalDuration: const Duration(minutes: 1));
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return AppleSettings(
          accuracy: LocationAccuracy.low,
          activityType: ActivityType.other,
          distanceFilter: distanceFilterM,
          pauseLocationUpdatesAutomatically: true,
          showBackgroundLocationIndicator: false,
          allowBackgroundLocationUpdates: background && defaultTargetPlatform == TargetPlatform.iOS,
        );
      default:
        return LocationSettings(accuracy: LocationAccuracy.low, distanceFilter: distanceFilterM);
    }
  }

  @override
  Stream<GeoFix> fixes({required bool background}) => Geolocator.getPositionStream(locationSettings: _settings(background)).map((p) => GeoFix(
        lat: p.latitude,
        lon: p.longitude,
        accuracyM: (p.accuracy.isNaN || p.accuracy <= 0) ? null : p.accuracy,
        at: p.timestamp.toUtc(),
      ));

  @override
  Future<bool> hasAlways() async {
    try {
      return await Geolocator.checkPermission() == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> permitted() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final p = await Geolocator.checkPermission();
      return p == LocationPermission.whileInUse || p == LocationPermission.always;
    } catch (_) {
      return false;
    }
  }
}
