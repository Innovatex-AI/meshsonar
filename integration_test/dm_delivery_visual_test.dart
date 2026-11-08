// Visual check of DM delivery states (fix round, Nov 8 2026, Andy's 0.29.0+49 report: messages the contact answered showed
// "Not delivered"). Runs the real app with the simulated radio: one DM confirmed (Delivered), then the radio drops acks
// (as a lost flood PATH return does), so the next DM sits in "Waiting for confirmation"; the contact replies and it turns
// "Probably delivered (they replied)" with no further tries. Prints "SCREEN <name>" for scripts/verify_sim.sh. Debug only.
//
//   FLOW_TEST=integration_test/dm_delivery_visual_test.dart scripts/verify_sim.sh
//   (light/dark: xcrun simctl ui <udid> appearance dark; HOLD_SECONDS=<n> keeps each screen longer)
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

final _hold = Duration(seconds: int.tryParse(Platform.environment['HOLD_SECONDS'] ?? '') ?? 25);

Future<void> hold(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 800));
  // ignore: avoid_print
  print('SCREEN $name');
  await pumpFor(t, _hold);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('dm delivery states', (t) async {
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
    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    final scanner = state.services.simulatorScanner as SimulatedRadioScanner;
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    // First connect of a radio asks for its antenna: keep the default and save.
    if (await waitFor(t, find.byKey(const Key('antenna-sheet')), timeout: const Duration(seconds: 6))) {
      final mount = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('mount-')).first;
      await t.tap(mount);
      await pumpFor(t, const Duration(milliseconds: 500));
      // Fill only what the form shows (a fresh install and a known radio differ).
      final height = find.byKey(const Key('antenna-height-field'));
      if (height.evaluate().isNotEmpty) {
        await t.ensureVisible(height);
        await t.enterText(height, '3');
      }
      final unknown = find.byKey(const Key('antenna-gain-unknown'));
      if (unknown.evaluate().isNotEmpty) {
        await t.ensureVisible(unknown);
        await t.tap(unknown);
        await pumpFor(t, const Duration(milliseconds: 500));
      }
      final save = find.byKey(const Key('antenna-save'));
      if (save.evaluate().isNotEmpty) {
        await t.ensureVisible(save);
        await t.tap(save);
        await pumpFor(t, const Duration(seconds: 1));
      }
    }
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await openShellTab(t, 'Chat');
    await pumpFor(t, const Duration(seconds: 2));

    final radio = scanner.lastTransport!;
    radio.injectDirectMessage('Ann KE8ANN', 'Where u putting it?');
    await pumpFor(t, const Duration(seconds: 4));
    final ctl = ChatWiring.controller.value!;
    await t.tap(find.text('Ann KE8ANN').first);
    await pumpFor(t, const Duration(seconds: 2));
    final dm = ctl.conversationRows().firstWhere((r) => r.title == 'Ann KE8ANN');
    ctl.send(dm.key, 'On the water tower, north side.');
    await pumpFor(t, const Duration(seconds: 5));
    radio.dropAcks = true; // the ack is lost on its way back
    ctl.send(dm.key, 'Sounds like our network is working lol');
    await pumpFor(t, const Duration(seconds: 4));
    await hold(t, 'dm-waiting-for-confirmation');
    radio.injectDirectMessage('Ann KE8ANN', 'Yes, yes it is.');
    await pumpFor(t, const Duration(seconds: 4));
    await hold(t, 'dm-probably-delivered');
    final shown = ctl.store.messages.page(dm.key, limit: 10).messages.where((m) => m.isOutgoing).map((m) => '${m.text} => ${m.state.name}').join(' | ');
    // ignore: avoid_print
    print('DM_STATES $shown');
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
