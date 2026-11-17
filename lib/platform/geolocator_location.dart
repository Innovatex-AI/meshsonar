// GPS for the real app, via the geolocator package. The drive stream's precision follows the battery mode (DriveGpsTuning:
// best / high / standard, coarse while parked); the ping-time one-shot fix is always precise. The app wraps
// this in FilteredLocationSource (lib/core/position_filter.dart) so parked jitter and poor fixes never reach a ping.
// Unknown values stay null (the plugin reports 0 or negative for "not available").
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../core/drive_gps_tuning.dart';
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

  /// The drive GPS mode in force (battery plan §3); a change re-subscribes the platform stream with the new settings.
  final DriveGpsTuning tuning;
  final GeolocatorStreamHub hub;
  final TargetPlatform? _platform;

  GeolocatorLocationSource({
    this.androidForegroundNotification = true,
    DriveGpsTuning? tuning,
    GeolocatorStreamHub? hub,
    @visibleForTesting TargetPlatform? platform,
  })  : tuning = tuning ?? DriveGpsTuning.shared,
        hub = hub ?? GeolocatorStreamHub.shared,
        // ignore: prefer_initializing_formals
        _platform = platform;

  TargetPlatform get _target => _platform ?? defaultTargetPlatform;

  /// The stream settings for [mode]:
  ///  * best: navigation accuracy, every fix (today's behaviour, Max data);
  ///  * high: best accuracy, 5 m filter (Balanced);
  ///  * standard: kCLLocationAccuracyNearestTenMeters (~10 m), 15 m filter (Saver);
  ///  * parked: kCLLocationAccuracyHundredMeters, 50 m filter, until the phone moves 50 m.
  /// iOS auto-pause stays OFF in every mode, parked included: once iOS pauses a session it does not resume it from the
  /// background on its own, and a locked phone would then never see the car drive off.
  LocationSettings settingsFor(DriveGpsMode mode) {
    final (LocationAccuracy apple, LocationAccuracy android, int filter) = switch (mode) {
      DriveGpsMode.best => (LocationAccuracy.bestForNavigation, LocationAccuracy.best, 0),
      DriveGpsMode.high => (LocationAccuracy.best, LocationAccuracy.best, 5),
      DriveGpsMode.standard => (LocationAccuracy.high, LocationAccuracy.high, 15),
      DriveGpsMode.parked => (LocationAccuracy.medium, LocationAccuracy.medium, 50),
    };
    if (kIsWeb) return LocationSettings(accuracy: android, distanceFilter: filter);
    switch (_target) {
      case TargetPlatform.android:
        return AndroidSettings(
          accuracy: android,
          distanceFilter: filter,
          intervalDuration: Duration(seconds: mode == DriveGpsMode.parked ? 10 : 1),
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
          accuracy: apple,
          activityType: ActivityType.automotiveNavigation,
          distanceFilter: filter,
          pauseLocationUpdatesAutomatically: false,
          showBackgroundLocationIndicator: true,
          allowBackgroundLocationUpdates: _target == TargetPlatform.iOS,
        );
      default:
        return LocationSettings(accuracy: android, distanceFilter: filter);
    }
  }

  /// The one-shot fix at ping time always asks for a precise, fresh position (iOS answers it from a separate one-time
  /// location manager, so the stream's coarser settings never apply to it): navigation accuracy in Best, best otherwise.
  LocationSettings oneShotSettings() {
    final acc = tuning.mode == DriveGpsMode.best ? LocationAccuracy.bestForNavigation : LocationAccuracy.best;
    if (!kIsWeb && (_target == TargetPlatform.iOS || _target == TargetPlatform.macOS)) {
      return AppleSettings(
        accuracy: acc,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        allowBackgroundLocationUpdates: _target == TargetPlatform.iOS,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }

  /// How many times this source (re)subscribed the platform stream; for tests and diagnostics.
  int subscriptions = 0;

  @override
  Stream<GeoFix> get fixes {
    late StreamController<GeoFix> out;
    StreamSubscription<Position>? sub;
    DriveGpsMode? on;
    void open() {
      final m = tuning.mode;
      on = m;
      final old = sub;
      subscriptions++;
      // Listen to the new settings first, then drop the old ones: the hub restarts the platform stream exactly once.
      sub = hub
          .stream(HubProfile.drive, settingsFor(m), key: 'drive-${m.name}')
          .listen((p) => out.add(_toFix(p)), onError: out.addError);
      unawaited(old?.cancel());
    }

    void changed() {
      if (sub != null && tuning.mode != on) open();
    }

    out = StreamController<GeoFix>(
      onListen: () {
        tuning.addListener(changed);
        open();
      },
      onCancel: () async {
        tuning.removeListener(changed);
        final s = sub;
        sub = null;
        await s?.cancel();
      },
    );
    return out.stream;
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
  Future<GeoFix?> current() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) return null;
      final p = await Geolocator.getCurrentPosition(locationSettings: oneShotSettings()).timeout(const Duration(seconds: 15));
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
