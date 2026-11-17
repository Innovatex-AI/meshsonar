// Drive GPS settings per battery mode, and the re-subscribe when the mode changes during a drive (battery plan §3, A10).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meshsonar/core/drive_gps_tuning.dart';
import 'package:meshsonar/platform/geolocator_location.dart';
import 'package:meshsonar/platform/geolocator_stream_hub.dart';

Position pos(double lat) => Position(
    longitude: -84.19,
    latitude: lat,
    timestamp: DateTime.utc(2026, 11, 17),
    accuracy: 5,
    altitude: 0,
    altitudeAccuracy: 0,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0);

void main() {
  test('iOS settings per mode: best / high / standard / parked; auto-pause stays off, background on', () {
    final src = GeolocatorLocationSource(tuning: DriveGpsTuning(), platform: TargetPlatform.iOS);
    final want = {
      DriveGpsMode.best: (LocationAccuracy.bestForNavigation, 0),
      DriveGpsMode.high: (LocationAccuracy.best, 5),
      DriveGpsMode.standard: (LocationAccuracy.high, 15),
      DriveGpsMode.parked: (LocationAccuracy.medium, 50),
    };
    for (final e in want.entries) {
      final s = src.settingsFor(e.key) as AppleSettings;
      expect(s.accuracy, e.value.$1, reason: e.key.name);
      expect(s.distanceFilter, e.value.$2, reason: e.key.name);
      expect(s.pauseLocationUpdatesAutomatically, isFalse);
      expect(s.allowBackgroundLocationUpdates, isTrue);
      expect(s.activityType, ActivityType.automotiveNavigation);
    }
  });

  test('Android keeps the foreground notification in every mode', () {
    final src = GeolocatorLocationSource(tuning: DriveGpsTuning(), platform: TargetPlatform.android);
    for (final m in DriveGpsMode.values) {
      final s = src.settingsFor(m) as AndroidSettings;
      expect(s.foregroundNotificationConfig, isNotNull);
    }
    expect((src.settingsFor(DriveGpsMode.standard) as AndroidSettings).distanceFilter, 15);
  });

  test('the ping-time one-shot is always precise, even while parked', () {
    final tuning = DriveGpsTuning();
    final src = GeolocatorLocationSource(tuning: tuning, platform: TargetPlatform.iOS);
    tuning.mode = DriveGpsMode.parked;
    expect(src.oneShotSettings().accuracy, LocationAccuracy.best);
    tuning.mode = DriveGpsMode.best;
    expect(src.oneShotSettings().accuracy, LocationAccuracy.bestForNavigation);
  });

  test('a mode change during a drive re-subscribes the platform stream once, with the new settings; fixes keep flowing', () async {
    final opened = <LocationSettings>[];
    StreamController<Position>? native;
    final hub = GeolocatorStreamHub(open: (s) {
      opened.add(s);
      native = StreamController<Position>();
      return native!.stream;
    });
    final tuning = DriveGpsTuning()..mode = DriveGpsMode.high;
    final src = GeolocatorLocationSource(tuning: tuning, hub: hub, platform: TargetPlatform.iOS);
    final got = <double>[];
    final sub = src.fixes.listen((f) => got.add(f.lat));
    await pumpEventQueue();
    expect(opened.map((s) => s.distanceFilter), [5]);
    native!.add(pos(1));
    await pumpEventQueue();
    tuning.mode = DriveGpsMode.parked;
    await pumpEventQueue();
    expect(opened.map((s) => s.distanceFilter), [5, 50]);
    expect(hub.starts, 2);
    expect(src.subscriptions, 2);
    native!.add(pos(2));
    await pumpEventQueue();
    tuning.mode = DriveGpsMode.parked; // no change: no restart
    await pumpEventQueue();
    expect(hub.starts, 2);
    tuning.mode = DriveGpsMode.high;
    await pumpEventQueue();
    expect(opened.map((s) => s.distanceFilter), [5, 50, 5]);
    expect(got, [1, 2]);
    await sub.cancel();
    await pumpEventQueue();
    expect(hub.activeKey, isNull);
    tuning.mode = DriveGpsMode.best; // nobody listening: nothing opens
    await pumpEventQueue();
    expect(hub.starts, 3);
  });
}
