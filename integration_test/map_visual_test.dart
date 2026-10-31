// Map visual flow for scripts/verify_sim.sh style runs: a simulated drive, then the Drive map and the full-screen map at
// street / neighbourhood / city zoom, with repeater names on and off, the layers sheet, and a landscape-ish check.
// Prints "SCREEN <name>" lines for the script to screenshot. Needs a simulator (no radio, no GPS: the Simulator radio).
//
//   flutter test integration_test/map_visual_test.dart -d <simulator udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

Future<void> pinch(WidgetTester t, Finder f, {required bool out}) async {
  final c = t.getCenter(f);
  final start = out ? 130.0 : 20.0;
  final a = await t.startGesture(c + Offset(-start, 0), pointer: 1);
  final b = await t.startGesture(c + Offset(start, 0), pointer: 2);
  for (var i = 1; i <= 12; i++) {
    final d = out ? start - i * 9.0 : start + i * 9.0;
    await a.moveTo(c + Offset(-d, 0));
    await b.moveTo(c + Offset(d, 0));
    await t.pump(const Duration(milliseconds: 40));
  }
  await a.up();
  await b.up();
  await pumpFor(t, const Duration(seconds: 2));
}

Future<void> doubleTap(WidgetTester t, Finder f) async {
  final c = t.getCenter(f) + const Offset(0, -30);
  await t.tapAt(c);
  await t.pump(const Duration(milliseconds: 60));
  await t.tapAt(c);
  await pumpFor(t, const Duration(seconds: 2));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('maps: labels and grid across zoom levels', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await t.tap(find.text('Skip'));
    }
    for (var i = 0; i < 14; i++) {
      await pumpFor(t, const Duration(milliseconds: 700));
      final c = find.text('Continue');
      if (c.evaluate().isNotEmpty) {
        await t.tap(c.last, warnIfMissed: false);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    expect(await waitFor(t, find.text('Connect radio')), isTrue);
    await pumpFor(t, const Duration(milliseconds: 1200));
    await t.tap(find.text('Connect radio').last);
    expect(await waitFor(t, find.text('Simulator (no radio)')), isTrue);
    await pumpFor(t, const Duration(milliseconds: 1200));
    await t.tap(find.text('Simulator (no radio)').last);
    expect(await waitFor(t, find.text('Start drive'), timeout: const Duration(seconds: 30)), isTrue);
    await pumpFor(t, const Duration(milliseconds: 1200));
    await t.tap(find.text('Start drive').last);
    if (await waitFor(t, find.text('Inside car'), timeout: const Duration(seconds: 5))) {
      await t.tap(find.text('Inside car'));
      await pumpFor(t, const Duration(milliseconds: 600));
      await t.tap(find.text("Don't know"));
      await pumpFor(t, const Duration(milliseconds: 600));
      await t.enterText(find.byType(TextField).last, '3');
      await pumpFor(t, const Duration(milliseconds: 600));
      await t.testTextInput.receiveAction(TextInputAction.done);
      await pumpFor(t, const Duration(milliseconds: 600));
      await t.ensureVisible(find.text('Save antenna'));
      await shot(t, 'dbg3');
      await t.tap(find.text('Save antenna'), warnIfMissed: false);
      await pumpFor(t, const Duration(seconds: 2));
      if (find.text('Start drive').hitTestable().evaluate().isNotEmpty) await t.tap(find.text('Start drive').last);
    }
    expect(await waitFor(t, find.text('Stop drive')), isTrue);
    await pumpFor(t, const Duration(seconds: 12));
    for (var i = 0; i < 4; i++) {
      await t.tap(find.text('Ping now'));
      await pumpFor(t, const Duration(seconds: 8));
    }
    final map = find.byKey(const Key('drive-map'));
    await shot(t, 'm01-drive-default');
    await doubleTap(t, map);
    await shot(t, 'm02-drive-zoom-in');
    await doubleTap(t, map);
    await doubleTap(t, map);
    await shot(t, 'm03-drive-street');
    await pinch(t, map, out: true);
    await pinch(t, map, out: true);
    await shot(t, 'm04-drive-zoomed-out');
    await pinch(t, map, out: true);
    await pinch(t, map, out: true);
    await shot(t, 'm05-drive-far-out');

    // layers sheet
    await t.tap(find.byKey(const Key('drive-map-layers')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'm06-layers-sheet');
    await t.tapAt(const Offset(20, 60));
    await pumpFor(t, const Duration(seconds: 1));

    // full screen
    await t.tap(find.byKey(const Key('map-fullscreen')));
    expect(await waitFor(t, find.byKey(const Key('fullscreen-map'))), isTrue);
    await shot(t, 'm07-fullscreen');
    final fs = find.byKey(const Key('fullscreen-coverage-map'));
    await doubleTap(t, fs);
    await doubleTap(t, fs);
    await shot(t, 'm08-fullscreen-zoom-in');
    await pinch(t, fs, out: true);
    await shot(t, 'm09-fullscreen-zoom-out');
    await t.tap(find.byKey(const Key('map-layers')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'm10-fullscreen-layers');
    await t.tap(find.byKey(const Key('layer-labels')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'm11-fullscreen-layers-names-off');
    await t.tapAt(const Offset(20, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'm12-fullscreen-names-off');
    // tap a repeater if one is on screen
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
