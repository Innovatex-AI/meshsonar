// Visits every Tool on the real app with the Simulator radio and prints "SCREEN <name>" for a script to screenshot
// (flutter test integration_test/tools_screens_test.dart -d <simulator udid>, grab `xcrun simctl io <udid> screenshot`).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

import 'screens.dart';

Future<void> openTool(WidgetTester t, String rowKey) async {
  await openShellTab(t, 'More');
  if (!await waitFor(t, find.byKey(const Key('more-list')).hitTestable(), timeout: const Duration(seconds: 3))) {
    await openShellTab(t, 'More');
    await waitFor(t, find.byKey(const Key('more-list')));
  }
  final row = find.byKey(Key(rowKey));
  if (row.evaluate().isEmpty) {
    await t.drag(find.byKey(const Key('more-list')), const Offset(0, 3000));
    await t.pump(const Duration(milliseconds: 500));
  }
  if (row.evaluate().isEmpty) {
    await t.dragUntilVisible(row, find.byKey(const Key('more-list')), const Offset(0, -150));
  }
  await t.ensureVisible(row);
  await t.tap(row);
  await pumpFor(t, const Duration(seconds: 2));
}

Future<void> back(WidgetTester t) async {
  final b = find.byTooltip('Back');
  if (b.evaluate().isNotEmpty) {
    await t.tap(b.first);
  } else {
    await t.pageBack();
  }
  await pumpFor(t, const Duration(seconds: 1));
  // ignore: avoid_print
  print('BACK list=${find.byKey(const Key('more-list')).evaluate().isNotEmpty}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('tools', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    await waitFor(t, find.byKey(const Key('shell-tabs')));
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 5))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }
    // No radio yet: the gate.
    await openTool(t, 'more-trace');
    await shot(t, 'tool-gate-no-radio');
    await back(t);
    await pumpFor(t, const Duration(seconds: 1));
    // Connect the Simulator radio.
    await openShellTab(t, 'Drive');
    await t.tap(find.byKey(const Key('connection-chip')));
    await pumpFor(t, const Duration(seconds: 3));
    final sim = find.byKey(const Key('simulator'));
    if (sim.evaluate().isEmpty) {
      await t.scrollUntilVisible(sim, 300, scrollable: find.byType(Scrollable).first);
    }
    await t.ensureVisible(sim);
    await t.tapAt(t.getTopLeft(sim) + const Offset(60, 40));
    await pumpFor(t, const Duration(seconds: 4));
    final sheet = find.byKey(const Key('antenna-sheet'));
    if (await waitFor(t, sheet, timeout: const Duration(seconds: 6))) {
      final mount = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('mount-'));
      if (mount.evaluate().isNotEmpty) await t.tap(mount.first);
      await pumpFor(t, const Duration(milliseconds: 500));
      await t.tap(find.byKey(const Key('antenna-gain-unknown')));
      await t.enterText(find.byKey(const Key('antenna-height-field')), '5');
      await pumpFor(t, const Duration(milliseconds: 500));
      final save = find.byKey(const Key('antenna-save'));
      await t.ensureVisible(save);
      await t.tap(save);
      await pumpFor(t, const Duration(seconds: 2));
    }
    await pumpFor(t, const Duration(seconds: 20)); // let the simulated mesh advertise

    await openTool(t, 'more-adverts');
    await shot(t, 'tool-adverts');
    await back(t);
    await openTool(t, 'more-rxLog');
    await shot(t, 'tool-rxlog');
    await back(t);
    await openTool(t, 'more-discover');
    final scan = find.byKey(const Key('discover-scan'));
    if (scan.evaluate().isNotEmpty) {
      await t.ensureVisible(scan);
      await t.tap(scan);
      await pumpFor(t, const Duration(seconds: 18));
    }
    await shot(t, 'tool-discover');
    await back(t);
    await openTool(t, 'more-noiseFloor');
    await pumpFor(t, const Duration(seconds: 40));
    await shot(t, 'tool-noise');
    await back(t);
    await openTool(t, 'more-telemetry');
    await shot(t, 'tool-telemetry');
    await back(t);
    await openTool(t, 'more-radioSetup');
    await shot(t, 'tool-radio-setup-1');
    final list = find.byKey(const Key('setup-list'));
    if (list.evaluate().isNotEmpty) {
      await t.drag(list, const Offset(0, -700));
      await pumpFor(t, const Duration(milliseconds: 500));
      await shot(t, 'tool-radio-setup-2');
    }
    await back(t);
    await openTool(t, 'more-trace');
    await pumpFor(t, const Duration(seconds: 3));
    await t.tap(find.byKey(const Key('trace-add-hop')));
    await pumpFor(t, const Duration(seconds: 1));
    final pick = find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('trace-pick-'));
    if (pick.evaluate().isNotEmpty) await t.tap(pick.first);
    await pumpFor(t, const Duration(seconds: 1));
    final send = find.byKey(const Key('trace-send'));
    await t.ensureVisible(send);
    await t.tap(send);
    await pumpFor(t, const Duration(seconds: 8));
    await shot(t, 'tool-trace');
    await t.drag(find.byKey(const Key('trace-list')), const Offset(0, -600));
    await shot(t, 'tool-trace-result');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}
