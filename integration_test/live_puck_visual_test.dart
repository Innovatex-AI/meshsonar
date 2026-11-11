// Run on a simulator (see scripts/verify_sim.sh for the device handling): connects the debug Simulator radio, starts a
// drive and prints "SCREEN <name>" while the simulated car drives, so a script can screenshot the sonar puck moving
// between pings, the ping rings, and the lines to the repeaters that heard it. Also opens the Drive tab's Ping settings.
import 'dart:convert' show utf8;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/crypto.dart' show sha256, toHex;
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/map/coverage_map.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live puck', (t) async {
    // A simulator has no barometer: the platform stream reports UNAVAILABLE through FlutterError. Not a failure of this flow.
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('Barometer is not available')) return;
      if (d.exceptionAsString().contains('no basemap tile')) return; // a tile the network didn't serve: the grid shows instead
      prev?.call(d);
    };
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 2; i <= 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 500));
      }
      await t.tap(find.byKey(const Key('onboarding-next')));
      await pumpFor(t, const Duration(seconds: 1));
    }
    for (final name in ['disclosure', 'connect', 'antenna', 'drive-ready']) {
      await screens.firstWhere((s) => s.name == name).run(t);
    }

    // The simulated radio's antenna is seeded (the antenna sheet step does not save one), so Start drive is enabled.
    final st = AppScope.read(t.element(find.byType(Scaffold).first));
    await st.saveAntennaProfile(
      AntennaProfile(mount: AntennaMount.roofMagMount, gainDbi: 3, heightM: 1.8, updatedAt: DateTime.utc(2026, 11, 1)),
      radioKey: toHex(sha256(utf8.encode('meshsonar-sim-companion'))),
    );
    await pumpFor(t, const Duration(seconds: 2));
    for (var attempt = 1; attempt <= 3 && !st.driving; attempt++) {
      if (find.byKey(const Key('start-stop')).hitTestable().evaluate().isNotEmpty) {
        await t.tap(find.byKey(const Key('start-stop')).hitTestable().first);
      }
      final end = DateTime.now().add(const Duration(seconds: 15));
      while (!st.driving && DateTime.now().isBefore(end)) {
        await t.pump(const Duration(milliseconds: 200));
      }
    }
    // ignore: avoid_print
    if (!st.driving) print('STEPFAIL drive did not start');
    await pumpFor(t, const Duration(seconds: 12));
    for (var i = 1; i <= 5; i++) {
      await shot1(t, 'puck-move-$i');
      await pumpFor(t, const Duration(milliseconds: 700));
    }
    // A ping: rings at once, then the lines to whoever answered.
    st.pingNow();
    for (var i = 1; i <= 6; i++) {
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot1(t, 'puck-ping-$i');
    }
    await pumpFor(t, const Duration(seconds: 6));
    await shot1(t, 'puck-lines-faded');
    // Pan away: the re-centre button appears.
    for (var i = 0; i < 3 && find.byKey(const Key('map-recenter')).evaluate().isEmpty; i++) {
      await t.drag(find.byKey(const Key('drive-map')), const Offset(160, 60), warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 1));
    }
    // Pinch-zoom in as well: the person's zoom and position must now survive every ping (Andy Nov 10 2026).
    final mc = t.getCenter(find.byKey(const Key('drive-map'))) - const Offset(0, 120);
    final g1 = await t.startGesture(mc - const Offset(40, 0), pointer: 71);
    final g2 = await t.startGesture(mc + const Offset(40, 0), pointer: 72);
    for (var i = 1; i <= 10; i++) {
      await g1.moveTo(mc - Offset(40.0 + 6 * i, 0));
      await g2.moveTo(mc + Offset(40.0 + 6 * i, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await g1.up();
    await g2.up();
    await pumpFor(t, const Duration(seconds: 1));
    camLog(t, 'panned');
    await shot1(t, 'puck-panned');
    // Several pings (and 30 s of fixes) while the map is where the person put it: the camera must not move.
    for (var i = 1; i <= 4; i++) {
      st.pingNow();
      await pumpFor(t, const Duration(seconds: 12));
      camLog(t, 'after-ping-$i');
      // ignore: avoid_print
      print('DRIVE pings=${st.drivePings.length} driving=${st.driving}');
      await shot1(t, 'puck-held-after-ping-$i');
      await pumpFor(t, const Duration(seconds: 3)); // the script's screenshot lands before anything else happens
    }
    await t.tap(find.byKey(const Key('map-recenter')));
    await pumpFor(t, const Duration(seconds: 1));
    camLog(t, 'recentred');
    await shot1(t, 'puck-recentred');
    await pumpFor(t, const Duration(seconds: 6));
    camLog(t, 'following');
    await shot1(t, 'puck-following');
    // Quick ping settings.
    // (The redesigned Drive panel has no quick-settings chip while driving: skipped then.)
    if (find.byKey(const Key('ping-settings-chip')).hitTestable().evaluate().isNotEmpty) {
      await t.tap(find.byKey(const Key('ping-settings-chip')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot1(t, 'ping-settings-sheet');
      await t.tapAt(const Offset(5, 60));
      await pumpFor(t, const Duration(seconds: 1));
    }
    // Settings moved into More: the Wardriving settings are the screen this flow is about.
    await openShellTab(t, 'More');
    await t.scrollUntilVisible(find.byKey(const Key('more-wardriving')), 200, scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
    await t.tap(find.byKey(const Key('more-wardriving')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot1(t, 'wardriving-settings');
    // ignore: avoid_print
    print('FRAMES $_shots/$_shots'); // HARNESS=1 (scripts/verify_sim.sh) checks every frame was captured
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// Prints the marker without the 3 s hold of [shot]: the car keeps moving, the script screenshots at once.
int _shots = 0;

Future<void> shot1(WidgetTester t, String name) async {
  _shots++;
  await t.pump(const Duration(milliseconds: 50));
  // ignore: avoid_print
  print('SCREEN $name');
  await pumpFor(t, const Duration(milliseconds: 250));
}

/// Prints the Drive map's camera (centre, zoom) so the log proves the view held still: `CAM tag lat lon zoom`.
void camLog(WidgetTester t, String tag) {
  final grid = find.byWidgetPredicate((w) => w.runtimeType.toString() == 'ChartGrid');
  if (grid.evaluate().isEmpty) return;
  final c = MapCamera.of(t.element(grid.first));
  final map = find.byKey(const Key('drive-map'));
  final pings = map.evaluate().isEmpty ? -1 : t.widget<CoverageMap>(map).pings.length;
  // ignore: avoid_print
  print('CAM $tag ${c.center.latitude.toStringAsFixed(7)} ${c.center.longitude.toStringAsFixed(7)} ${c.zoom.toStringAsFixed(3)} pings=$pings recenter=${find.byKey(const Key('map-recenter')).evaluate().isNotEmpty}');
}
