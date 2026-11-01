// First run with no radio: what each tab says, then the Plan tab's "Where to drive next" with the simulator's location.
// Prints "SCREEN <name>" for a script to screenshot. Debug builds only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first run tabs and Plan', (t) async {
    // A simulator has no barometer: the platform stream reports UNAVAILABLE through FlutterError. Not a failure of this flow.
    final prev = FlutterError.onError;
    FlutterError.onError = (d) {
      if (d.exceptionAsString().contains('Barometer is not available')) return;
      prev?.call(d);
    };
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }
    for (final tab in ['Map', 'Chat', 'Analyze', 'Plan', 'More']) {
      await openShellTab(t, tab);
      await pumpFor(t, const Duration(seconds: 4));
      await shot(t, 'first-$tab');
    }
    await openShellTab(t, 'Plan');
    await pumpFor(t, const Duration(seconds: 6));
    final list = find.descendant(of: find.byKey(const Key('plan-list')), matching: find.byType(Scrollable)).first;
    await t.drag(list, const Offset(0, -500));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'plan-scrolled');
    // With a position (the simulator radio's GPS drives around Columbus): the list of gaps near it.
    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await state.startDrive();
    await pumpFor(t, const Duration(seconds: 10));
    await state.stopDrive();
    await pumpFor(t, const Duration(seconds: 2));
    await openShellTab(t, 'Plan');
    await pumpFor(t, const Duration(seconds: 10));
    await t.drag(find.byKey(const Key('plan-list')), const Offset(0, 300));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'plan-with-position');
    await t.drag(find.byKey(const Key('plan-list')), const Offset(0, -420));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'plan-with-position-2');
    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
