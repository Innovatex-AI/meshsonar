// The redesigned Drive screen: heard box (live → holding → stale), map markers following it, the antenna toggle,
// the full-screen map, the LOG button, the drive report card, the next-ping indicator and the simulator tag.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show FlutterMap;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/heard.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';
import 'package:meshsonar/ui/map/map_layers.dart';
import 'package:meshsonar/ui/ping_log_screen.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';

import 'fakes.dart';
import 'map/repeater_probe.dart';
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

Finder heardRow(String id) => find.byKey(ValueKey('heard-row-$id'));

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

  testWidgets('heard box: live while heard, dimmed while holding, greyed into "+N earlier" after holdPings pings',
      (tester) async {
    final h = await driving(tester, hold: 3);
    final e = h.engines.single;

    e.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5), Echo(repeater: 'ff09', snrDb: -3)]));
    await settle(tester);
    expect(find.byKey(const Key('heard-box')), findsOneWidget);
    expect(tester.widget<Text>(find.descendant(of: find.byKey(const Key('heard-count')), matching: find.byType(Text))).data, '2');
    expect(find.descendant(of: heardRow('a1b2'), matching: find.text('Westerville Water Tower')), findsOneWidget);
    expect(find.descendant(of: heardRow('a1b2'), matching: find.text('+6.5')), findsOneWidget);
    expect(find.descendant(of: heardRow('a1b2'), matching: find.textContaining('km')), findsOneWidget); // distance
    // On the map: the known repeater pops up, with a link and a distance label from here.
    expect(repeaterItem(tester, 'a1b2c3d4')!.heard, isTrue);
    expect(repeaterItem(tester, 'a1b2c3d4')!.variant, SpriteVariant.heard);
    expect(drawnLabels(tester).where((l) => l.tag && l.text.contains('km')), hasLength(1), reason: 'distance tag on the link');
    expect(labelContaining(tester, 'Westerville Water Tower'), isNotNull, reason: 'the heard repeater is named, with its SNR');

    // Only ff09 heard: the tower holds (still listed, "missed 1", marker still lit but not fresh).
    e.emit(heardPing('p2', const [Echo(repeater: 'ff09', snrDb: -2)]));
    await settle(tester);
    expect(heardRow('a1b2'), findsOneWidget);
    expect(find.descendant(of: heardRow('a1b2'), matching: find.textContaining('missed 1')), findsOneWidget);
    expect(repeaterItem(tester, 'a1b2c3d4')!.heard, isTrue);

    e.emit(silentPing('p3'));
    await settle(tester);
    expect(heardRow('a1b2'), findsOneWidget); // 2 pings missed, hold is 3

    e.emit(silentPing('p4'));
    await settle(tester);
    // Missed 3 pings: stale. Out of the live list, folded into "+N earlier", greyed on the map.
    expect(heardRow('a1b2'), findsNothing);
    expect(find.text('+1 earlier'), findsOneWidget);
    expect(repeaterItem(tester, 'a1b2c3d4')!.heard, isTrue, reason: 'still heard this drive');
    await tester.pump(const Duration(seconds: 1));
    expect(drawnLabels(tester).where((l) => l.tag), isEmpty, reason: 'no live link, no distance tag');
    expect(find.byKey(const ValueKey('heard-stale-a1b2')), findsNothing);
    await tester.tap(find.byKey(const Key('heard-earlier')));
    await settle(tester);
    expect(find.byKey(const ValueKey('heard-stale-a1b2')), findsOneWidget);

    // Heard again: back to live and fresh.
    e.emit(heardPing('p5', const [Echo(repeater: 'a1b2', snrDb: 1)]));
    await settle(tester);
    expect(heardRow('a1b2'), findsOneWidget);
    expect(repeaterItem(tester, 'a1b2c3d4')!.heard, isTrue);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('tapping a heard repeater highlights it on the map', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);
    expect(repeaterItem(tester, 'a1b2c3d4')!.selected, isFalse);
    await tester.tap(heardRow('a1b2'));
    await settle(tester);
    expect(repeaterItem(tester, 'a1b2c3d4')!.selected, isTrue);
    expect(repeaterItem(tester, 'a1b2c3d4')!.variant, SpriteVariant.selectedHeard);
    expect(labelContaining(tester, 'Heard now'), isNotNull, reason: 'second line of the selected label');
    await tester.tap(heardRow('a1b2'));
    await settle(tester);
    expect(repeaterItem(tester, 'a1b2c3d4')!.selected, isFalse);
    await h.state.stopDrive();
    await drain(tester);
  });

  // 0.4.0 (spec m1-app-0.4.0 §4): the Internal/External toggle became the per-radio antenna chip.
  testWidgets('antenna chip: shows the radio\'s antenna, the drive records it, locked while driving', (tester) async {
    useHugeScreen(tester);
    final h = Harness(); // the radio's saved antenna is inside car, 1.2 m (fakes.dart)
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await settle(tester);
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
    await tester.tap(find.byKey(const Key('antenna-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('antenna-sheet')), findsOneWidget, reason: 'editable again after the drive');
    await drain(tester);
  });

  testWidgets('full-screen map opens with the heard box, layers and controls, and closes', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);

    await tester.tap(find.byKey(const Key('map-fullscreen')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('fullscreen-close')), findsOneWidget, reason: 'the same map, expanded');
    expect(find.byType(FlutterMap), findsOneWidget, reason: 'one map instance, not a second route');
    expect(find.byKey(const Key('heard-box')), findsOneWidget);
    expect(heardRow('a1b2'), findsOneWidget);
    expect(find.byKey(const Key('map-compass')), findsOneWidget);
    expect(find.byKey(const Key('start-stop')), findsOneWidget);

    // Ping now works from full screen.
    await tester.tap(find.byKey(const Key('ping-now')));
    await settle(tester);
    expect(h.state.pingCount, 2);

    // Layers: switch ping colours to heard/not and hide repeaters.
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
    await tester.tap(find.byKey(const Key('layer-color-result')));
    await tester.tap(find.byKey(const Key('layer-repeaters')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('layers-done'))); // dismiss the sheet
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('layers-sheet')), findsNothing);
    expect(repeaterItem(tester, 'a1b2c3d4'), isNull, reason: 'known-repeaters layer is off');

    await tester.tap(find.byKey(const Key('fullscreen-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('fullscreen-close')), findsNothing);
    expect(find.byKey(const Key('map-fullscreen')), findsOneWidget);
    expect(find.byKey(const Key('drive-map')), findsOneWidget);
    // Layer choices are shared with the Drive screen's map.
    expect(repeaterItem(tester, 'a1b2c3d4'), isNull, reason: 'known-repeaters layer is off');
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('LOG opens the ping log; after Stop a card opens the drive report', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);
    expect(find.text('Log · 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-log')));
    await tester.pumpAndSettle();
    expect(find.byType(PingLogScreen), findsOneWidget);
    await tester.pageBack();
    await settleLive(tester);

    expect(find.byKey(const Key('drive-report-card')), findsNothing);
    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(h.state.lastFinishedSessionId, isNotNull);
    expect(find.byKey(const Key('drive-report-card')), findsOneWidget);
    await tester.tap(find.byKey(const Key('view-report')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final report = tester.widget<DriveReportScreen>(find.byType(DriveReportScreen));
    expect(report.sessionId, h.state.lastFinishedSessionId);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    await tester.tap(find.byKey(const Key('dismiss-report')));
    await settle(tester);
    expect(find.byKey(const Key('drive-report-card')), findsNothing);
    await drain(tester);
  });

  testWidgets('next-ping indicator: countdown for time, "Move N m" for distance, GPS wait', (tester) async {
    final h = await driving(tester);
    final e = h.engines.single;
    e.setStatus(EngineStatus(EngineState.driving, nextPingAt: DateTime.utc(2026, 10, 16, 18, 0, 12), waitingFor: PingWait.time));
    await settle(tester);
    expect(tester.widget<Text>(find.byKey(const Key('next-ping-seconds'))).data, '12');

    e.setStatus(EngineStatus(
      EngineState.driving,
      nextPingAt: DateTime.utc(2026, 10, 16, 17, 59, 50),
      waitingFor: PingWait.distance,
      metresToGo: 39.2,
    ));
    await settle(tester);
    expect(find.byKey(const Key('next-ping-countdown')), findsNothing);
    expect(find.text('Move 40 m'), findsOneWidget);

    e.setStatus(const EngineStatus(EngineState.driving, waitingFor: PingWait.gps));
    await settle(tester);
    expect(find.text('Waiting for GPS'), findsOneWidget);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('simulator mode is labelled on the chip and the map', (tester) async {
    useHugeScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(find.byKey(const Key('map-simulated')), findsNothing);
    await h.state.connectSimulator();
    await settle(tester);
    expect(find.byKey(const Key('chip-simulated')), findsOneWidget);
    expect(find.byKey(const Key('map-simulated')), findsOneWidget);
    expect(find.text('SIMULATED GPS & RADIO'), findsNWidgets(2));
    await drain(tester);
  });
}
