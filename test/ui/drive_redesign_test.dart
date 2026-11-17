// The Drive screen: the heard snapshot rules, the antenna chip, the LOG button and the simulator tag. (The heard box, the
// full-screen button, the report card and the footer next-ping indicator went with the old layout in build 70.) The helpers
// below are shared by other Drive tests.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/map/map_layers.dart';
import 'package:meshsonar/ui/ping_log_screen.dart';

import 'fakes.dart';
import '../support/huge_screen.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Lets snackbars and flashes time out so no timers are left pending.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

const tower = RepeaterRef(key: 'a1b2c3d4', name: 'Westerville Water Tower', lat: 40.135, lon: -82.92);

Future<Harness> driving(WidgetTester tester, {int hold = 3}) async {
  useHugeScreen(tester);
  final h = Harness();
  h.settings.saved = Settings(heardHoldPings: hold);
  h.cache.items = const [tower];
  await h.pumpApp(tester);
  await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  await h.state.startDrive();
  await settle(tester);
  return h;
}


void main() {
  test('heard snapshot: fresh, holding with pips left, then stale after the hold', () {
    final t = HeardTracker(holdPings: 2);
    t.addPing(heardPing('1', const [Echo(repeater: 'aa', snrDb: 4)]));
    expect(heardSnapshot(t).single.phase, HeardPhase.fresh);
    expect(heardSnapshot(t).single.holdLeft, 2);
    t.addPing(silentPing('2'));
    expect(heardSnapshot(t).single.phase, HeardPhase.holding);
    expect(heardSnapshot(t).single.holdLeft, 1);
    t.addPing(silentPing('3'));
    expect(heardSnapshot(t).single.phase, HeardPhase.stale);
    expect(Units.metric.distance(840, approx: true), '840 m');
    expect(Units.metric.distance(2345, approx: true), '2.3 km');
  });

  testWidgets('antenna chip: shows the radio\'s antenna, the drive records it, locked while driving', (tester) async {
    useHugeScreen(tester);
    final h = Harness(); // the radio's saved antenna is inside car, 1.2 m (fakes.dart)
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await settle(tester);
    await openDrivePanel(tester); // the chip lives in the Medium panel
    expect(find.text('Inside car · 1.2 m'), findsOneWidget);

    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isTrue);
    expect(h.store.sessionsById.values.single.antenna.type, 'internal');
    await tester.tap(find.byKey(const Key('antenna-chip')));
    await settle(tester);
    expect(find.byKey(const Key('antenna-sheet')), findsNothing, reason: 'locked while driving');

    await h.state.stopDrive();
    await settle(tester);
    // The "Drive saved" snackbar floats over the lower controls for a few seconds; clear it.
    for (var i = 0; i < 3 && find.byType(SnackBar).evaluate().isNotEmpty; i++) {
      for (final m in tester.stateList<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))) {
        m.removeCurrentSnackBar();
      }
      await settle(tester);
    }
    expect(find.byType(SnackBar), findsNothing);
    await openDrivePanel(tester);
    await tester.tap(find.byKey(const Key('antenna-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('antenna-sheet')), findsOneWidget, reason: 'editable again after the drive');
    await drain(tester);
  });

  testWidgets('LOG (in the Medium panel) opens the ping log', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);
    await openDrivePanel(tester);
    expect(find.text('Log · 1'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('open-log')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('open-log')));
    await tester.pumpAndSettle();
    expect(find.byType(PingLogScreen), findsOneWidget);
    await tester.pageBack();
    await settleLive(tester);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('simulator mode is labelled on the status capsule', (tester) async {
    useHugeScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(find.text('SIM'), findsNothing);
    await h.state.connectSimulator();
    await settle(tester);
    // The status capsule carries the amber SIM badge (there is no map-corner tag on the Drive screen).
    expect(find.descendant(of: find.byKey(const Key('connection-chip')), matching: find.text('SIM')), findsOneWidget);
    await drain(tester);
  });
}
