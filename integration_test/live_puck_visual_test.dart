// Run on a simulator (see scripts/verify_sim.sh for the device handling): connects the debug Simulator radio, starts a
// drive and prints "SCREEN <name>" while the simulated car drives, so a script can screenshot the sonar puck moving
// between pings, the ping rings, and the lines to the repeaters that heard it. Also opens the Drive tab's Ping settings.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live puck', (t) async {
    // A simulator has no barometer: the platform stream reports UNAVAILABLE through FlutterError. Not a failure of this flow.
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('Barometer is not available')) return;
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

    await t.tap(find.byKey(const Key('start-stop')));
    await pumpFor(t, const Duration(seconds: 12));
    for (var i = 1; i <= 5; i++) {
      await shot1(t, 'puck-move-$i');
      await pumpFor(t, const Duration(milliseconds: 700));
    }
    // A ping: rings at once, then the lines to whoever answered.
    await t.tap(find.byKey(const Key('ping-now')));
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
      if (find.byKey(const Key('ping-now')).evaluate().isNotEmpty) await t.tap(find.byKey(const Key('ping-now')), warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 8));
      camLog(t, 'after-ping-$i');
      await shot1(t, 'puck-held-after-ping-$i');
    }
    await t.tap(find.byKey(const Key('map-recenter')));
    await pumpFor(t, const Duration(seconds: 1));
    camLog(t, 'recentred');
    await shot1(t, 'puck-recentred');
    await pumpFor(t, const Duration(seconds: 6));
    camLog(t, 'following');
    await shot1(t, 'puck-following');
    // Quick ping settings.
    await t.tap(find.byKey(const Key('ping-settings-chip')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot1(t, 'ping-settings-sheet');
    await t.tapAt(const Offset(5, 60));
    await pumpFor(t, const Duration(seconds: 1));
    // Settings moved into More: the Wardriving settings are the screen this flow is about.
    await openShellTab(t, 'More');
    await t.scrollUntilVisible(find.byKey(const Key('more-wardriving')), 200, scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
    await t.tap(find.byKey(const Key('more-wardriving')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot1(t, 'wardriving-settings');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// Prints the marker without the 3 s hold of [shot]: the car keeps moving, the script screenshots at once.
Future<void> shot1(WidgetTester t, String name) async {
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
  // ignore: avoid_print
  print('CAM $tag ${c.center.latitude.toStringAsFixed(7)} ${c.center.longitude.toStringAsFixed(7)} ${c.zoom.toStringAsFixed(3)} recenter=${find.byKey(const Key('map-recenter')).evaluate().isNotEmpty}');
}
