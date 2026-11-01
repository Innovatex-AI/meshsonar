// The geolocator plugin memoises its position stream: while any listener is attached every later getPositionStream call returns the SAME
// stream and ignores its settings (geolocator_apple 2.3.15 / geolocator_android 5.1.1, `_positionStream`). MemoPlatform below copies
// exactly that rule, so these tests show the bug (idle listening first => the drive gets idle settings) and that the hub removes it.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:meshsonar/platform/geolocator_stream_hub.dart';

class MemoPlatform {
  Stream<Position>? _memo;
  final startedWith = <LocationAccuracy>[]; // the settings the NATIVE side was started with, one per native listen
  final startedFilter = <int>[];
  int nativeStops = 0;
  late StreamController<Position> _native;

  Stream<Position> getPositionStream(LocationSettings s) {
    if (_memo != null) return _memo!;
    _native = StreamController<Position>.broadcast(onListen: () {
      startedWith.add(s.accuracy);
      startedFilter.add(s.distanceFilter);
    }, onCancel: () {
      nativeStops++;
      _memo = null;
    });
    return _memo = _native.stream;
  }

  void emit(double acc) => _native.add(Position(
      longitude: -82.9,
      latitude: 40.1,
      timestamp: DateTime.utc(2026, 11, 1),
      accuracy: acc,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0));
}

const idleSettings = LocationSettings(accuracy: LocationAccuracy.low, distanceFilter: 500);
const driveSettings = LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 0);

void main() {
  test('THE BUG, reproduced against the plugin\'s rule: calling the plugin directly while idle listens gives the drive the idle settings', () async {
    final plat = MemoPlatform();
    final idle = plat.getPositionStream(idleSettings).listen((_) {});
    await Future<void>.delayed(Duration.zero);
    final drive = plat.getPositionStream(driveSettings).listen((_) {});
    await idle.cancel(); // the app stops the idle watcher when a drive starts
    await Future<void>.delayed(Duration.zero);
    expect(plat.startedWith, [LocationAccuracy.low], reason: 'native side runs with the IDLE settings for the whole drive');
    expect(plat.startedFilter, [500]);
    expect(plat.nativeStops, 0);
    await drive.cancel();
  });

  test('hub: a drive that starts while idle listens restarts the platform stream with drive settings', () async {
    final plat = MemoPlatform();
    final hub = GeolocatorStreamHub(open: plat.getPositionStream);
    final idleGot = <double>[], driveGot = <double>[];
    final idle = hub.stream(HubProfile.idle, idleSettings, key: 'idle-fg').listen((p) => idleGot.add(p.accuracy));
    await Future<void>.delayed(Duration.zero);
    expect(plat.startedWith, [LocationAccuracy.low]);

    final drive = hub.stream(HubProfile.drive, driveSettings, key: 'drive').listen((p) => driveGot.add(p.accuracy));
    await Future<void>.delayed(Duration.zero);
    expect(plat.startedWith, [LocationAccuracy.low, LocationAccuracy.bestForNavigation]);
    expect(plat.startedFilter, [500, 0]);
    expect(hub.activeKey, 'drive');

    plat.emit(5);
    await Future<void>.delayed(Duration.zero);
    expect(driveGot, [5]);
    expect(idleGot, [5], reason: 'a cheap consumer simply shares the better stream');

    // The idle watcher stops for the drive: the drive stream must keep running with drive settings.
    await idle.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(hub.activeKey, 'drive');
    expect(plat.startedWith.length, 2, reason: 'no restart when the cheap consumer leaves');
    plat.emit(6);
    await Future<void>.delayed(Duration.zero);
    expect(driveGot, [5, 6]);

    // After the drive, idle comes back: back to cheap settings, and when nobody listens the platform stream stops.
    final idle2 = hub.stream(HubProfile.idle, idleSettings, key: 'idle-fg').listen((_) {});
    await drive.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(hub.activeKey, 'idle-fg');
    expect(plat.startedWith.last, LocationAccuracy.low);
    await idle2.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(hub.activeKey, isNull);
    expect(plat.nativeStops, plat.startedWith.length);
  });

  test('hub: drive first, then idle joining, never downgrades the drive', () async {
    final plat = MemoPlatform();
    final hub = GeolocatorStreamHub(open: plat.getPositionStream);
    final drive = hub.stream(HubProfile.drive, driveSettings, key: 'drive').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    final idle = hub.stream(HubProfile.idle, idleSettings, key: 'idle-fg').listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(plat.startedWith, [LocationAccuracy.bestForNavigation]);
    expect(hub.activeKey, 'drive');
    await idle.cancel();
    await drive.cancel();
  });

  test('hub: rapid listen/cancel churn settles on the right settings', () async {
    final plat = MemoPlatform();
    final hub = GeolocatorStreamHub(open: plat.getPositionStream);
    final a = hub.stream(HubProfile.idle, idleSettings, key: 'idle-fg').listen((_) {});
    final b = hub.stream(HubProfile.drive, driveSettings, key: 'drive').listen((_) {});
    await a.cancel();
    final c = hub.stream(HubProfile.idle, idleSettings, key: 'idle-fg').listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(hub.activeKey, 'drive');
    await b.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(hub.activeKey, 'idle-fg');
    await c.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(hub.activeKey, isNull);
  });
}
