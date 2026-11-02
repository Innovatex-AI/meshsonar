// The sonar puck: the dot moves with every GPS fix (not only when a ping is sent), pings send rings and draw lines to the
// repeaters that heard them, reduced motion snaps, and a fix never rebuilds the map.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/live_puck.dart';
import 'package:meshsonar/ui/map/map_layers.dart';

import 'drive_flow_test.dart' show connectViaUi, drain, settle;
import 'fakes.dart';

const _mLat = 111320.0;

GeoFix fixAt(DateTime t, double northM, {double speed = 13}) => GeoFix(
      lat: 40.0 + northM / _mLat,
      lon: -83.0,
      at: t,
      accuracyM: 5,
      speedMps: speed,
      courseDeg: 0,
    );

/// A bare map with only the puck layers, a fixed camera and a clock the test owns.
Widget bareMap(PuckController puck, {List<HeardView> heard = const [], bool reduced = false}) {
  return MaterialApp(
    theme: meshSonarTheme(Brightness.light),
    home: MediaQuery(
      data: MediaQueryData(size: const Size(400, 600), disableAnimations: reduced),
      child: SizedBox(
        width: 400,
        height: 600,
        child: FlutterMap(
          options: const MapOptions(initialCenter: LatLng(40.0, -83.0), initialZoom: 17),
          children: [
            PuckLinksLayer(puck: puck, heard: heard),
            PuckLayer(puck: puck),
          ],
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => DriveMapModel.debugFixes = (s) => s.activeLocation.fixes);
  tearDown(() => DriveMapModel.debugFixes = null);
  testWidgets('the dot slides between fixes with no ping involved, and does not hop', (tester) async {
    var now = DateTime.utc(2026, 11, 1, 12);
    final puck = PuckController(clock: () => now);
    addTearDown(puck.dispose);
    await tester.pumpWidget(bareMap(puck));

    puck.onFix(fixAt(now, 0));
    await tester.pump();
    final start = tester.getCenter(find.byKey(const Key('map-position')));

    // Three seconds of driving north at 13 m/s: a fix each second, a frame every ~33 ms in between.
    final ys = <double>[start.dy];
    for (var sec = 1; sec <= 3; sec++) {
      for (var i = 0; i < 30; i++) {
        now = now.add(const Duration(milliseconds: 33));
        await tester.pump(const Duration(milliseconds: 33));
        ys.add(tester.getCenter(find.byKey(const Key('map-position'))).dy);
      }
      now = DateTime.utc(2026, 11, 1, 12).add(Duration(seconds: sec));
      puck.onFix(fixAt(now, 13.0 * sec));
    }
    expect(ys.last, lessThan(ys.first), reason: 'moved north (up the screen) with no ping sent');
    var biggest = 0.0;
    for (var i = 1; i < ys.length; i++) {
      biggest = biggest < (ys[i - 1] - ys[i]).abs() ? (ys[i - 1] - ys[i]).abs() : biggest;
      expect(ys[i], lessThanOrEqualTo(ys[i - 1] + 0.01), reason: 'never backwards');
    }
    // 13 m at zoom 17 is ~70 px; a hop would be one jump of that size. Frames move a few pixels.
    expect(biggest, lessThan(3), reason: 'a hop would be one ~14 px jump per fix (13 m at zoom 17 is ~14 px)');
    expect(ys.first - ys.last, greaterThan(30), reason: '39 m north at zoom 17 is ~43 px');
  });

  testWidgets('the ticker sleeps when nothing moves', (tester) async {
    var now = DateTime.utc(2026, 11, 1, 12);
    final puck = PuckController(clock: () => now);
    addTearDown(puck.dispose);
    await tester.pumpWidget(bareMap(puck));
    puck.onFix(fixAt(now, 0, speed: 0));
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      now = now.add(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('reduced motion shows the newest fix as it is (no slide, no rings)', (tester) async {
    var now = DateTime.utc(2026, 11, 1, 12);
    final puck = PuckController(clock: () => now);
    addTearDown(puck.dispose);
    await tester.pumpWidget(bareMap(puck, reduced: true));
    puck.onFix(fixAt(now, 0));
    await tester.pump();
    final a = tester.getCenter(find.byKey(const Key('map-position')));
    now = now.add(const Duration(seconds: 1));
    puck.onFix(fixAt(now, 13));
    puck.pingSent();
    await tester.pump(const Duration(milliseconds: 33));
    final b = tester.getCenter(find.byKey(const Key('map-position')));
    expect(a.dy - b.dy, closeTo(14, 3), reason: 'at the new fix at once (13 m is ~14 px at zoom 17)');
    await tester.pump(const Duration(milliseconds: 33));
    final c = tester.getCenter(find.byKey(const Key('map-position')));
    expect(c.dy, closeTo(b.dy, 0.5), reason: 'no extrapolation under reduced motion');
  });

  testWidgets('lines go from the moving dot to each heard repeater, in the link colour, and fade', (tester) async {
    var now = DateTime.utc(2026, 11, 1, 12);
    final puck = PuckController(clock: () => now);
    addTearDown(puck.dispose);
    final heard = [
      const HeardView(id: 'a1b2', label: 'A', ref: RepeaterRef(key: 'a1b2c3', name: 'A', lat: 40.001, lon: -83.001), snrDb: 5),
      const HeardView(id: 'ffee', label: 'No position'),
    ];
    await tester.pumpWidget(bareMap(puck, heard: heard));
    puck.onFix(fixAt(now, 0, speed: 0));
    puck.pingSent();
    await tester.pump();
    expect(puck.waiting, isTrue);
    expect(find.byKey(const Key('puck-links')), findsOneWidget, reason: 'one repeater with a position');

    now = now.add(const Duration(seconds: 3));
    puck.pingResolved(heard: true);
    expect(puck.waiting, isFalse);
    expect(puck.resolvedHeard, isTrue);
    await tester.pump(const Duration(milliseconds: 100));

    // Timeline helpers (the colour/alpha contract is in the painter; the maths is pinned here).
    expect(freshLinkAlpha(const Duration(seconds: 2)), 1);
    expect(freshLinkAlpha(const Duration(seconds: 7)), closeTo((1 + linkHeldAlpha) / 2, 0.15));
    expect(freshLinkAlpha(const Duration(seconds: 20)), linkHeldAlpha);
    expect(linkDrawProgress(Duration.zero), 0);
    expect(linkDrawProgress(const Duration(seconds: 2)), 1);
    expect(waitingRings(Duration.zero).length, 1);
    expect(waitingRings(const Duration(milliseconds: 1500)).length, 3);
    expect(waitingRings(const Duration(seconds: 20)), isEmpty);
  });

  testWidgets('end to end: fixes move the dot on the Drive tab between pings; rings follow a ping; it ends with the drive',
      (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    await connectViaUi(tester);
    await tester.tap(find.byKey(const Key('start-stop')));
    await settle(tester);
    expect(h.state.driving, isTrue);

    PuckController puck() => tester.widget<CoverageMap>(find.byKey(const Key('drive-map'))).puck!;
    expect(puck().pose, isNull, reason: 'no fix yet');

    var t = h.clockNow;
    final lats = <double>[];
    for (var i = 0; i < 6; i++) {
      t = t.add(const Duration(seconds: 1));
      h.clockNow = t;
      h.location.fixController.add(fixAt(t, 15.0 * i));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      lats.add(puck().pose!.lat);
    }
    expect(h.state.pingCount, 0, reason: 'no ping was sent: the dot moved on GPS alone');
    for (var i = 1; i < lats.length; i++) {
      expect(lats[i], greaterThan(lats[i - 1]));
    }
    expect(find.byKey(const Key('map-position')), findsOneWidget);

    // The engine starts a ping: rings.
    expect(puck().waiting, isFalse);
    h.engines.single.setStatus(const EngineStatus(EngineState.pinging, message: 'Pinging'));
    await tester.pump();
    expect(puck().waiting, isTrue);
    // It finishes and was heard: resolved with the answer.
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 4, hops: 1)]));
    await settle(tester);
    expect(puck().waiting, isFalse);
    expect(puck().resolvedHeard, isTrue);

    // The drive ends: the puck forgets it.
    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const Key('stop-drive-confirm')));
    await settle(tester);
    expect(find.text('Start drive'), findsOneWidget);
    expect(puck().pose, isNull, reason: 'forgotten with the drive');
    await drain(tester);
  });
}
