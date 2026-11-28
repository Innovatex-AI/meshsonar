// Build 78 screenshot flow: the MeshSonar radio page on the Simulator's MeshSonar radio (fake local API):
//   FLOW_TEST=integration_test/msradio_visual_test.dart scripts/verify_sim.sh <worktree>
// Shoots More > Radio with the row, the page before pairing, the pairing sheet, the page paired, and every section.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/msradio/ms_sections.dart';

import 'chat_harness.dart' show closeAntennaSheet;
import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('meshsonar radio', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    for (var i = 0; i < 2; i++) {
      final keep = find.byKey(const Key('telemetry-keep'));
      if (await waitFor(t, keep, timeout: const Duration(seconds: 5))) {
        await t.tap(keep);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    expect(await state.connectSimulator(meshSonar: true), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    await closeAntennaSheet(t);
    await pumpFor(t, const Duration(seconds: 1));

    Future<bool> tapKey(String key, String step) async {
      final f = find.byKey(Key(key));
      if (!await waitFor(t, f, timeout: const Duration(seconds: 8))) {
        // ignore: avoid_print
        print('STEPFAIL $step: $key not found');
        return false;
      }
      await t.ensureVisible(f.first);
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.tap(f.first);
      await pumpFor(t, const Duration(seconds: 2));
      return true;
    }

    Future<void> back() async {
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
    }

    await openShellTab(t, 'More');
    await tapKey('more-radio', 'more-radio');
    await pumpFor(t, const Duration(seconds: 3));
    await shot(t, 'msr-more-radio');
    if (!await tapKey('more-meshsonar-radio', 'entry-row')) return;
    await shot(t, 'msr-page-unpaired');
    await tapKey('ms-section-pairing', 'pairing');
    await shot(t, 'msr-pairing');
    if (await tapKey('ms-pair-signed', 'pair-signed')) {
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'msr-pairing-sheet');
      final done = find.byKey(const Key('ms-pairing-done'));
      if (await waitFor(t, done, timeout: const Duration(seconds: 10))) {
        await t.tap(done);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    await shot(t, 'msr-pairing-paired');
    await back();
    await shot(t, 'msr-page-paired');
    for (final s in MsSection.values.where((s) => s != MsSection.pairing)) {
      final f = find.byKey(Key('ms-section-${s.name}'));
      if (f.evaluate().isEmpty) {
        await t.scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).last).catchError((_) {});
      }
      if (f.evaluate().isEmpty) continue; // hidden (Owner link while radio proof is off)
      if (!await tapKey('ms-section-${s.name}', s.name)) continue;
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'msr-${s.name}');
      await back();
    }
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
