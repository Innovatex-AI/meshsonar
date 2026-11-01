// Run on a simulator (see scripts/verify_sim.sh for the device handling): connects the debug Simulator radio, starts a
// drive and prints "SCREEN <name>" while the simulated car drives, so a script can screenshot the sonar puck moving
// between pings, the ping rings, and the lines to the repeaters that heard it. Also opens the Map tab's Ping settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live puck', (t) async {
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
    await t.drag(find.byKey(const Key('drive-map')), const Offset(120, 40));
    await pumpFor(t, const Duration(seconds: 1));
    await shot1(t, 'puck-panned');
    await t.tap(find.byKey(const Key('map-recenter')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot1(t, 'puck-recentred');
    // Quick ping settings.
    await t.tap(find.byKey(const Key('ping-settings-chip')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot1(t, 'ping-settings-sheet');
    await t.tapAt(const Offset(5, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await openTab(t, 'Settings');
    await shot1(t, 'settings');
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
