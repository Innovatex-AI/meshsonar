// On-device flow test: runs the REAL app (real wiring, storage, engine) on an iOS/Android simulator or a device,
// using MeshSonar's Simulator radio so no hardware is needed. Prints "SCREEN <name>" while holding each key screen,
// so a script can grab platform screenshots (e.g. `xcrun simctl io booted screenshot`).
//
//   flutter test integration_test/app_flow_test.dart -d <device id>
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;

Future<void> pumpFor(WidgetTester t, Duration d) async {
  final end = DateTime.now().add(d);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<bool> waitFor(WidgetTester t, Finder f, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 100));
    if (f.evaluate().isNotEmpty) return true;
  }
  return false;
}

/// Waits for [f], lets page transitions finish, then taps it.
Future<void> tapWhenReady(WidgetTester t, Finder f, String what, {Duration timeout = const Duration(seconds: 20)}) async {
  expect(await waitFor(t, f, timeout: timeout), isTrue, reason: what);
  await pumpFor(t, const Duration(milliseconds: 1200));
  await t.tap(f.last);
}

Future<void> screen(WidgetTester t, String name) async {
  await pumpFor(t, const Duration(milliseconds: 800));
  // ignore: avoid_print
  print('SCREEN $name');
  await pumpFor(t, const Duration(seconds: 4)); // hold still for the screenshot
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first run → simulator drive → drives list → drive detail', (t) async {
    await app.main();

    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      await screen(t, 'onboarding');
      await t.tap(find.text('Skip'));
    }

    expect(await waitFor(t, find.text('Connect radio')), isTrue, reason: 'Drive screen with Connect radio');
    await screen(t, 'drive-empty');
    await tapWhenReady(t, find.text('Connect radio'), 'Connect radio button');

    expect(await waitFor(t, find.text('Simulator (no radio)')), isTrue, reason: 'Connect screen');
    await screen(t, 'connect');
    await tapWhenReady(t, find.text('Simulator (no radio)'), 'Simulator option');

    await tapWhenReady(t, find.text('Start drive'), 'connected to the simulator radio', timeout: const Duration(seconds: 30));
    expect(await waitFor(t, find.text('Stop drive')), isTrue, reason: 'drive started');

    // let auto-pings run (first is immediate) and add two manual pings
    await pumpFor(t, const Duration(seconds: 12));
    for (var i = 0; i < 2; i++) {
      await t.tap(find.text('Ping now'));
      await pumpFor(t, const Duration(seconds: 9));
    }
    expect(find.textContaining(RegExp(r'repeaters? heard|Heard nothing')), findsWidgets, reason: 'pings recorded');
    await screen(t, 'drive-active');

    await t.tap(find.text('Stop drive'));
    expect(await waitFor(t, find.text('Start drive'), timeout: const Duration(seconds: 30)), isTrue, reason: 'stopped');

    await tapWhenReady(t, find.text('Drives'), 'Drives tab');
    expect(await waitFor(t, find.textContaining('pings')), isTrue, reason: 'drives list shows the drive');
    await screen(t, 'drives');

    await pumpFor(t, const Duration(milliseconds: 800));
    await t.tap(find.textContaining('pings').first);
    expect(await waitFor(t, find.text('Median SNR')), isTrue, reason: 'drive detail stats');
    await screen(t, 'detail');

    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(find.byIcon(Icons.settings).last);
    await screen(t, 'settings');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
