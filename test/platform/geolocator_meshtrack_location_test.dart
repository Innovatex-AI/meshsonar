// MeshTrack between drives has its own cheaper GPS request (battery plan A8).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meshsonar/platform/geolocator_idle_location.dart';
import 'package:meshsonar/platform/geolocator_meshtrack_location.dart';
import 'package:meshsonar/platform/geolocator_stream_hub.dart';

void main() {
  test('settings: best accuracy, 20 m filter, auto-pause allowed, otherNavigation, foreground only', () {
    final s = GeolocatorMeshTrackLocationSource(platform: TargetPlatform.iOS).settings() as AppleSettings;
    expect(s.accuracy, LocationAccuracy.best);
    expect(s.distanceFilter, 20);
    expect(s.pauseLocationUpdatesAutomatically, isTrue);
    expect(s.activityType, ActivityType.otherNavigation);
    expect(s.allowBackgroundLocationUpdates, isFalse);
  });

  test('ranks above the idle watcher and below a drive: never pushes idle to drive settings', () async {
    final opened = <LocationSettings>[];
    final hub = GeolocatorStreamHub(open: (s) {
      opened.add(s);
      return StreamController<Position>().stream;
    });
    final idle = hub.stream(HubProfile.idle, const LocationSettings(accuracy: LocationAccuracy.low, distanceFilter: 500), key: 'idle-fg')
        .listen((_) {});
    await pumpEventQueue();
    final mt = GeolocatorMeshTrackLocationSource(hub: hub, platform: TargetPlatform.iOS).fixes.listen((_) {});
    await pumpEventQueue();
    expect(hub.activeKey, 'meshtrack');
    expect(opened.last.accuracy, LocationAccuracy.best);
    expect(opened.last.distanceFilter, 20);
    expect(opened.any((s) => s.accuracy == LocationAccuracy.bestForNavigation), isFalse);
    final drive = hub
        .stream(HubProfile.drive, const LocationSettings(accuracy: LocationAccuracy.bestForNavigation), key: 'drive-best')
        .listen((_) {});
    await pumpEventQueue();
    expect(hub.activeKey, 'drive-best');
    await drive.cancel();
    await pumpEventQueue();
    expect(hub.activeKey, 'meshtrack');
    await mt.cancel();
    await pumpEventQueue();
    expect(hub.activeKey, 'idle-fg');
    await idle.cancel();
    // Silence the unused-import lint for the idle source type the app pairs with this one.
    expect(GeolocatorIdleLocationSource().distanceFilterM, 500);
  });
}
