// Visual check of the Chat CONVERSATION screens (Andy, Nov 8: "when you go into a thread it gets off base"). Runs the real app with
// the simulated radio, fills Public with a busy multi-person thread plus your own messages, then holds a channel thread and a DM
// thread long enough to screenshot. Every held screen prints "SCREEN <name>" (scripts/verify_sim.sh grabs those). Debug builds only.
//
//   flutter test integration_test/chat_thread_look_test.dart -d <simulator id>
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

  testWidgets('chat threads look', (t) async {
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
    for (final (who, text) in [
      ('Maya', 'Net check-in at 8, anyone near the bridge?'),
      ('Maya', 'I can relay from the water tower if needed.'),
      ('Ann KE8ANN', 'Here. Signal is great from the north side tonight.'),
      ('Sam W8SAM', 'Copy. I will be mobile on 33 heading east, listening on the hilltop repeater the whole way.'),
      ('Sam W8SAM', 'ok'),
      ('Maya', 'Thanks all. Starting the roll call in 5.'),
    ]) {
      radio.injectChannelMessage(0, who, text);
      await pumpFor(t, const Duration(milliseconds: 400));
    }
    radio.injectDirectMessage('Ann KE8ANN', 'Are you bringing the long antenna tonight?');
    await pumpFor(t, const Duration(seconds: 4));

    final ctl = ChatWiring.controller.value!;
    final public = ctl.store.channels.list(ctl.radioId!).firstWhere((c) => c.name == 'Public');
    ctl.send(public.convKey, 'On my way, 10 minutes out.');
    await pumpFor(t, const Duration(seconds: 2));
    radio.injectChannelMessage(0, 'Maya', 'See you there!');
    ctl.send(public.convKey, 'Can someone check the hilltop battery?');
    await pumpFor(t, const Duration(seconds: 3));
    await hold(t, 'thread-list');

    await t.tap(find.text('Public').first);
    await pumpFor(t, const Duration(seconds: 2));
    await hold(t, 'thread-channel');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));

    await t.tap(find.text('Ann KE8ANN').first);
    await pumpFor(t, const Duration(seconds: 2));
    final dm = ctl.conversationRows().firstWhere((r) => r.title == 'Ann KE8ANN');
    ctl.send(dm.key, 'Yes, the 5 dBi on the mast. See you at 8.');
    await pumpFor(t, const Duration(seconds: 3));
    await hold(t, 'thread-dm');
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
