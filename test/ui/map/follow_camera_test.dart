// The live map's follow camera and direction arrow, on a real CoverageMap with a puck: the arrow stays at its place on the screen
// while the car moves, points along the course (compass when stopped) without spinning at north, a finger pauses follow and the
// re-centre button (or 10 s of quiet) resumes it, heading-up turns the map, zoom-by-speed eases out, GPS weak shows a tag.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexPoint;
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/live_puck.dart';

const _mLat = 111320.0;
final _t0 = DateTime.utc(2026, 11, 1, 12);

class Rig {
  late PuckController puck;
  late MapPrefs prefs;
  DateTime now = _t0;
  double northM = 0, eastM = 0;
  int sec = 0;
  Rig() {
    prefs = MapPrefs();
    puck = PuckController(clock: () => now);
  }

  GeoFix fix({double speed = 13, double? course = 0, double acc = 5}) => GeoFix(
    lat: 40 + northM / _mLat,
    lon: -83 + eastM / (_mLat * math.cos(40 * math.pi / 180)),
    at: _t0.add(Duration(seconds: sec)),
    accuracyM: acc,
    speedMps: speed,
    courseDeg: course,
  );

  Widget app({List<NetworkCell> cells = const [], bool rotatable = false}) => MaterialApp(
    theme: meshSonarTheme(Brightness.light),
    home: Scaffold(
      body: SizedBox(
        width: 400,
        height: 800,
        child: CoverageMap(
          key: const Key('map'),
          pings: const [],
          puck: puck,
          prefs: prefs,
          position: const LatLng(40, -83),
          showRings: true,
          showTiles: false,
          networkCells: cells,
          rotatable: rotatable,
        ),
      ),
    ),
  );

  /// Drives [seconds] of a car going [speed] along [course]: a fix each second, a frame every 16 ms.
  Future<void> drive(WidgetTester t, double seconds, {double speed = 13, double? course = 0, bool fixes = true}) async {
    for (var s = 0; s < seconds; s++) {
      if (fixes) {
        final r = (course ?? 0) * math.pi / 180;
        northM += math.cos(r) * speed;
        eastM += math.sin(r) * speed;
        sec++;
        puck.onFix(fix(speed: speed, course: course));
      } else {
        sec++;
      }
      for (var i = 0; i < 62; i++) {
        now = now.add(const Duration(milliseconds: 16));
        await t.pump(const Duration(milliseconds: 16));
      }
    }
  }
}

MapCamera cameraOf(WidgetTester t) => MapCamera.of(t.element(find.byKey(const Key('puck-paint'))));
Offset markAt(WidgetTester t) => t.getCenter(find.byKey(const Key('map-position')));
double arrowAngle(WidgetTester t) {
  final w = t.widget<Transform>(find.byKey(const Key('map-heading-arrow')));
  final m = w.transform;
  return math.atan2(m.entry(1, 0), m.entry(0, 0));
}

NetworkCell cell(double lat, double lon) => NetworkCell(
  id: '$lat,$lon',
  boundary: [HexPoint(lat, lon), HexPoint(lat + 0.001, lon), HexPoint(lat + 0.001, lon + 0.001), HexPoint(lat, lon + 0.001)],
  level: CoverageLevel.good,
);

void main() {
  late Rig r;
  setUp(() => r = Rig());
  void phone(WidgetTester t) {
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  tearDown(() => r.puck.dispose());

  testWidgets('following: the arrow stays at its place on the screen (lower third) while the car drives 20 s', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix());
    await r.drive(t, 6);
    final anchor = markAt(t);
    final mapBox = t.getRect(find.byKey(const Key('map')));
    expect(anchor.dx, closeTo(mapBox.center.dx, 1));
    expect(anchor.dy - mapBox.top, closeTo(800 * 0.66, 2), reason: 'lower third: more road ahead');
    var worst = 0.0;
    for (var i = 0; i < 14; i++) {
      await r.drive(t, 1);
      worst = math.max(worst, (markAt(t) - anchor).distance);
    }
    expect(worst, lessThan(1.0), reason: 'the map slides under a fixed arrow');
    // and the map really moved: 14 s * 13 m/s = 180 m north
    final c = cameraOf(t).center;
    expect((c.latitude - 40) * _mLat, greaterThan(150));
  });

  testWidgets('the arrow points along the course and turns the short way through north', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(course: 350));
    await r.drive(t, 4, course: 350);
    expect(arrowAngle(t), closeTo(-10 * math.pi / 180, 0.08));
    final angles = <double>[];
    for (var s = 0; s < 3; s++) {
      r.northM += 13;
      r.sec++;
      r.puck.onFix(r.fix(course: 10));
      for (var i = 0; i < 62; i++) {
        r.now = r.now.add(const Duration(milliseconds: 16));
        await t.pump(const Duration(milliseconds: 16));
        angles.add(arrowAngle(t));
      }
    }
    for (var i = 1; i < angles.length; i++) {
      expect((angles[i] - angles[i - 1]).abs(), lessThan(0.25), reason: 'frame $i: no spin');
    }
    expect(angles.every((a) => a.abs() < 0.4), isTrue, reason: 'stayed within +-23 degrees of north the whole time');
    expect(arrowAngle(t), closeTo(10 * math.pi / 180, 0.08));
  });

  testWidgets('stopped: the arrow follows the compass; moving: the course wins', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(speed: 0, course: null));
    await r.drive(t, 3, speed: 0, course: null);
    r.puck.onCompass(90);
    await r.drive(t, 2, speed: 0, course: null);
    expect(arrowAngle(t), closeTo(math.pi / 2, 0.1), reason: 'facing east by the compass');
    r.puck.onCompass(180);
    await r.drive(t, 2, speed: 0, course: null);
    expect(arrowAngle(t), closeTo(math.pi, 0.1));
    r.puck.onCompass(270); // a reading while driving north is ignored
    await r.drive(t, 6, speed: 13, course: 0);
    expect(arrowAngle(t).abs(), lessThan(0.1));
  });

  testWidgets('no direction known yet: a plain dot, no arrow', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(speed: 0, course: null));
    await r.drive(t, 1, speed: 0, course: null);
    expect(find.byKey(const Key('map-heading-arrow')), findsNothing);
    expect(find.byKey(const Key('map-position')), findsOneWidget);
  });

  testWidgets('GPS weak: a tag after 2.5 s without a fix, the arrow holds after 5 s, a fix clears it', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix());
    await r.drive(t, 2);
    expect(find.byKey(const Key('gps-weak-tag')), findsNothing);
    await r.drive(t, 2, fixes: false);
    expect(find.byKey(const Key('gps-weak-tag')), findsOneWidget);
    expect(r.puck.pose!.frozen, isFalse);
    await r.drive(t, 3, fixes: false);
    expect(r.puck.pose!.frozen, isTrue);
    final held = markAt(t);
    await r.drive(t, 2, fixes: false);
    expect((markAt(t) - held).distance, lessThan(0.5), reason: 'frozen: the camera has nothing to follow');
    await r.drive(t, 1);
    expect(find.byKey(const Key('gps-weak-tag')), findsNothing);
  });

  testWidgets('a finger on the map pauses follow and shows the re-centre button; the button resumes it', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix());
    await r.drive(t, 5);
    expect(find.byKey(const Key('map-recenter')), findsNothing);
    await t.drag(find.byKey(const Key('map')), const Offset(0, 120));
    await t.pump();
    expect(find.byKey(const Key('map-recenter')), findsOneWidget);
    final centre = cameraOf(t).center;
    final afterDrag = markAt(t);
    await r.drive(t, 5);
    expect((cameraOf(t).center.latitude - centre.latitude).abs(), lessThan(1e-7), reason: 'the camera stays where the person put it');
    final off = markAt(t);
    expect(off.dy, lessThan(afterDrag.dy - 4), reason: 'the arrow drove on up the screen while the map stood still');
    await t.tap(find.byKey(const Key('map-recenter')));
    await t.pump();
    await r.drive(t, 2);
    expect(find.byKey(const Key('map-recenter')), findsNothing);
    final mapBox = t.getRect(find.byKey(const Key('map')));
    expect(markAt(t).dy - mapBox.top, closeTo(800 * 0.66, 3));
  });

  testWidgets('auto re-centre: 10 s after the last touch (setting), and not when the setting is off', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix());
    await r.drive(t, 3);
    await t.drag(find.byKey(const Key('map')), const Offset(0, 100));
    await t.pump();
    expect(find.byKey(const Key('map-recenter')), findsOneWidget);
    await r.drive(t, 8);
    expect(find.byKey(const Key('map-recenter')), findsOneWidget, reason: '8 s is not enough');
    await r.drive(t, 4);
    expect(find.byKey(const Key('map-recenter')), findsNothing, reason: 'back on the car by itself');

    r.prefs.autoResumeSec = 0;
    await t.pump();
    await t.drag(find.byKey(const Key('map')), const Offset(0, 100));
    await t.pump();
    await r.drive(t, 30);
    expect(find.byKey(const Key('map-recenter')), findsOneWidget, reason: 'setting off: only the button');
  });

  testWidgets('heading-up turns the map so the direction of travel is up; the button toggles it; north-up turns it back', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(course: 90));
    await r.drive(t, 3, course: 90);
    expect(cameraOf(t).rotation, 0, reason: 'north-up by default');
    await t.tap(find.byKey(const Key('map-heading-toggle')));
    await t.pump();
    expect(r.prefs.headingUp, isTrue);
    await r.drive(t, 3, course: 90);
    expect(cameraOf(t).rotation, closeTo(-90, 3), reason: 'east is up');
    expect(arrowAngle(t), closeTo(0, 0.1), reason: 'on a heading-up map the arrow points up the screen');
    // the arrow stays put on screen while the map turns
    final a = markAt(t);
    await r.drive(t, 3, course: 90);
    expect((markAt(t) - a).distance, lessThan(1));
    await t.tap(find.byKey(const Key('map-heading-toggle')));
    await t.pump();
    expect(r.prefs.headingUp, isFalse);
    expect(cameraOf(t).rotation, 0);
  });

  testWidgets('heading-up crosses north without spinning the map', (t) async {
    phone(t);
    r.prefs.headingUp = true;
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(course: 355));
    await r.drive(t, 5, course: 355);
    final rots = <double>[];
    for (var s = 0; s < 3; s++) {
      r.northM += 13;
      r.sec++;
      r.puck.onFix(r.fix(course: 5));
      for (var i = 0; i < 62; i++) {
        r.now = r.now.add(const Duration(milliseconds: 16));
        await t.pump(const Duration(milliseconds: 16));
        rots.add(cameraOf(t).rotation);
      }
    }
    for (var i = 1; i < rots.length; i++) {
      expect((rots[i] - rots[i - 1]).abs(), lessThan(5), reason: 'frame $i');
    }
    expect(rots.last, closeTo(-5, 3));
  });

  testWidgets('zoom by speed eases out on the highway and back; off keeps the zoom', (t) async {
    phone(t);
    await t.pumpWidget(r.app());
    r.puck.onFix(r.fix(speed: 28));
    await r.drive(t, 4, speed: 28);
    final z0 = cameraOf(t).zoom;
    await r.drive(t, 6, speed: 28);
    expect(cameraOf(t).zoom, closeTo(z0, 1e-9), reason: 'off by default: the zoom stays where it is');
    r.prefs.zoomBySpeed = true;
    await t.pump();
    final zs = <double>[];
    for (var s = 0; s < 8; s++) {
      await r.drive(t, 1, speed: 28);
      zs.add(cameraOf(t).zoom);
    }
    expect(zs.last, lessThan(z0 - 0.9), reason: 'zoomed out at 28 m/s');
    for (var i = 1; i < zs.length; i++) {
      expect(zs[i], lessThanOrEqualTo(zs[i - 1] + 1e-9), reason: 'smoothly, one way');
    }
    await r.drive(t, 10, speed: 5);
    expect(cameraOf(t).zoom, closeTo(z0, 0.1), reason: 'back to the person\'s zoom in town');
  });

  testWidgets('fixes never repaint the cell layers: 30 s of driving paints the cell picture a handful of times, not 1,800', (t) async {
    phone(t);
    final cells = [for (var i = 0; i < 40; i++) for (var j = 0; j < 40; j++) cell(40 - 0.02 + i * 0.001, -83 - 0.02 + j * 0.001)];
    await t.pumpWidget(r.app(cells: cells));
    r.puck.onFix(r.fix());
    await r.drive(t, 3);
    final st = t.state<CellRasterLayerState>(find.byKey(const Key('network-cells-layer')));
    final before = st.paints;
    expect(before, greaterThanOrEqualTo(1));
    await r.drive(t, 30);
    expect(st.paints - before, lessThanOrEqualTo(6), reason: '30 s at 13 m/s is 390 m: a few repaints as the view reaches the edge of the picture');
  });
}
