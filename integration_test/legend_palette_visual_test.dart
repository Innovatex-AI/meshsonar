// Visual check for the map legend and the colour palettes: a simulated drive, then for each palette the Settings tile,
// the Drive map with network cells, and the Map legend sheet (light and dark come from the simulator appearance).
// Prints "SCREEN <name>" lines for a script to screenshot.
//
//   flutter test integration_test/legend_palette_visual_test.dart -d <simulator udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('legend and palettes', (t) async {
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

    for (final p in ['standard', 'colour_blind', 'high_contrast']) {
      // Settings tile
      await openTab(t, 'Settings');
      final opt = find.byKey(Key('colour-palette-$p'));
      await t.scrollUntilVisible(opt, 200, scrollable: find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first);
      await t.ensureVisible(opt);
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.tap(opt);
      await pumpFor(t, const Duration(seconds: 1));
      await t.ensureVisible(find.byKey(const Key('colour-palette')));
      await shot(t, 'p-$p-settings');

      // Drive map with cells, links and pings
      await openTab(t, 'Drive');
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'p-$p-drive-map');

      // Layers sheet, then the legend
      await t.tap(find.byKey(const Key('drive-map-layers')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'p-$p-layers');
      await t.tap(find.byKey(const Key('layers-legend')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'p-$p-legend-1');
      final sheet = find.byKey(const Key('legend-sheet'));
      var n = 2;
      for (final id in ['cells', 'repeaters', 'links', 'heard', 'why']) {
        await t.ensureVisible(find.byKey(Key('legend-section-$id')));
        await pumpFor(t, const Duration(milliseconds: 600));
        await shot(t, 'p-$p-legend-$n-$id');
        n++;
      }
      expect(sheet, findsOneWidget);
      await t.tapAt(const Offset(20, 60)); // scrim closes the legend
      await pumpFor(t, const Duration(seconds: 1));
      await t.tapAt(const Offset(20, 60)); // and the layers sheet
      await pumpFor(t, const Duration(seconds: 1));
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 25)));
}
