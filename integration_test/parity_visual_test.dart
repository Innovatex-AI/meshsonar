// Visual check for the two website-parity features: the neighbouring regions on the map (names, switch confirm, after the
// switch) and the privacy-zone editor (empty, a zone added, radius changed, deleted). Prints "SCREEN <name>" lines for a
// script to screenshot. Talks to production like the other flows; the zone it adds is deleted again at the end.
//
//   flutter test integration_test/parity_visual_test.dart -d <simulator udid>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('region switching and privacy zones', (t) async {
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
    await pumpFor(t, const Duration(seconds: 6)); // site-config, regions-index and coverage arrive

    // ---- neighbouring regions on the map
    await openTab(t, 'Drive');
    await pumpFor(t, const Duration(seconds: 4));
    await shot(t, 'map-regions');
    final names = find.byWidgetPredicate((w) {
      final k = w.key;
      if (k is! ValueKey<String>) return false;
      final v = k.value;
      return (v.startsWith('region-name-') || v.startsWith('region-edge-')) && !v.contains('-pos-');
    });
    if (names.evaluate().isEmpty) {
      // ignore: avoid_print
      print('SKIPPED no neighbour names on screen');
    } else {
      await t.tap(names.first);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'switch-confirm');
      await t.tap(find.byKey(const Key('region-switch-cancel')));
      await pumpFor(t, const Duration(seconds: 1));
      await t.tap(names.first);
      await pumpFor(t, const Duration(seconds: 1));
      await t.tap(find.byKey(const Key('region-switch-confirm')));
      await pumpFor(t, const Duration(seconds: 3));
      await shot(t, 'map-after-switch');
    }
    final chip = find.byKey(const Key('region-switch-chip'));
    if (chip.evaluate().isNotEmpty) {
      await t.tap(chip.first);
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'switcher-recent');
      await t.tapAt(const Offset(20, 60));
      await pumpFor(t, const Duration(seconds: 1));
    }

    // ---- privacy zones
    await openTab(t, 'Settings');
    final row = find.byKey(const Key('privacy-zones'));
    await t.scrollUntilVisible(row, 200, scrollable: find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first);
    await t.ensureVisible(row);
    await t.tap(row);
    expect(await waitFor(t, find.byKey(const Key('privacy-zones-screen'))), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'zones-empty');
    await t.tap(find.byKey(const Key('zone-add')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'zones-add-mode');
    await t.tapAt(t.getCenter(find.byKey(const Key('zones-map'))) + const Offset(0, 30));
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'zones-added');
    final radius = find.byKey(const Key('zone-radius'));
    await t.ensureVisible(radius);
    await t.drag(radius, const Offset(60, 0));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'zones-radius');
    await t.ensureVisible(find.byKey(const Key('zone-delete')));
    await t.tap(find.byKey(const Key('zone-delete')));
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'zones-deleted');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
