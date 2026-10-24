// The Drive screen's second, mid-drive-only stats strip (lib/ui/drive/drive_live_stats.dart,
// DriveLiveStatsStrip in lib/ui/drive/drive_controls.dart): distance and elapsed time this session, the live
// new-vs-repeat grid-cell tally, and the current GPS fix's accuracy.
import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/drive_stats.dart' show haversineM;
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 20));
  await tester.pump(const Duration(seconds: 1));
}

final distanceTile = find.byKey(const Key('stat-distance'));
final elapsedTile = find.byKey(const Key('stat-elapsed'));
final cellsTile = find.byKey(const Key('stat-cells'));
final cellsLabel = find.byKey(const Key('stat-cells-label'));
final gpsTile = find.byKey(const Key('stat-gps'));

void main() {
  testWidgets('the second strip only shows while actually driving', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(distanceTile, findsNothing);

    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await settle(tester);
    expect(distanceTile, findsOneWidget);
    expect(elapsedTile, findsOneWidget);
    expect(cellsTile, findsOneWidget);
    expect(gpsTile, findsOneWidget);

    await h.state.stopDrive();
    await settle(tester);
    expect(distanceTile, findsNothing); // the top strip's recap (pings/heard/SNR/synced) stays; this one doesn't
    await drain(tester);
  });

  testWidgets('distance sums consecutive pings; cells split new vs. repeat; GPS accuracy is colour-coded', (tester) async {
    useTallScreen(tester);
    final h = Harness();

    // A drive from yesterday already pinged the "cellB" grid cell (40.0030, -83.0000 -> same (i, j) as the
    // 0.002°x0.0025° grid cell drive_report.dart's cellIndexOf gives that point): that cell should come up
    // "repeat" today, not "new".
    h.store.seed(
      DriveSession(id: 'old-1', startedAt: DateTime.utc(2026, 10, 15, 12, 0, 0), endedAt: DateTime.utc(2026, 10, 15, 12, 30, 0)),
      [DrivePing(id: 'old-p1', ts: DateTime.utc(2026, 10, 15, 12, 5, 0), lat: 40.0030, lon: -83.0000, echoes: const [])],
    );

    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pumpAndSettle(); // let the one-time earlier-drives history read resolve

    // No GPS fix published yet.
    expect(tester.widget<Text>(gpsTile).data, 'No fix');

    const p0 = (lat: 40.0000, lon: -83.0000); // cell "A"
    const p1 = (lat: 40.0005, lon: -83.0000); // same cell as p0 (< 0.002° away)
    const p2 = (lat: 40.0030, lon: -83.0000); // cell "B" -- the one seeded as already driven

    h.engines.single.emit(DrivePing(id: 'p0', ts: DateTime.utc(2026, 10, 16, 18, 0, 0), lat: p0.lat, lon: p0.lon, echoes: const []));
    await settle(tester);
    expect(tester.widget<Text>(cellsTile).data, '1 new');
    expect(tester.widget<Text>(cellsLabel).data, '0 repeat');

    h.engines.single.emit(DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 16, 18, 0, 10), lat: p1.lat, lon: p1.lon, echoes: const []));
    await settle(tester);
    // Revisiting the same cell this drive doesn't bump either count.
    expect(tester.widget<Text>(cellsTile).data, '1 new');
    expect(tester.widget<Text>(cellsLabel).data, '0 repeat');

    h.engines.single.emit(DrivePing(id: 'p2', ts: DateTime.utc(2026, 10, 16, 18, 0, 20), lat: p2.lat, lon: p2.lon, echoes: const []));
    await settle(tester);
    expect(tester.widget<Text>(cellsTile).data, '1 new');
    expect(tester.widget<Text>(cellsLabel).data, '1 repeat');

    // Distance is the same running sum DriveStats/DriveReport use (haversine, ping to ping, in arrival order).
    final expectedM = haversineM(p0.lat, p0.lon, p1.lat, p1.lon) + haversineM(p1.lat, p1.lon, p2.lat, p2.lon);
    expect(tester.widget<Text>(distanceTile).data, Units.metric.distance(expectedM));

    // Elapsed ticks off the harness's clock (fixed in tests), so it reads a real, computed zero, not a placeholder.
    expect(tester.widget<Text>(elapsedTile).data, '0 s');

    // GPS accuracy: colour-coded, and updates live as fresh fixes land.
    final mc = MeshSonarColors.of(tester.element(gpsTile));
    Color? gpsColor() => tester.widget<Text>(gpsTile).style?.color;

    h.engines.single.setStatus(EngineStatus(
      EngineState.driving,
      lastFix: GeoFix(lat: 40.0, lon: -83.0, at: DateTime.utc(2026, 10, 16, 18, 0, 20), accuracyM: 8),
    ));
    await settle(tester);
    expect(tester.widget<Text>(gpsTile).data, '±8 m');
    expect(gpsColor(), mc.snrStrong);

    h.engines.single.setStatus(EngineStatus(
      EngineState.driving,
      lastFix: GeoFix(lat: 40.0, lon: -83.0, at: DateTime.utc(2026, 10, 16, 18, 0, 25), accuracyM: 20),
    ));
    await settle(tester);
    expect(tester.widget<Text>(gpsTile).data, '±20 m');
    expect(gpsColor(), mc.snrMid);

    h.engines.single.setStatus(EngineStatus(
      EngineState.driving,
      lastFix: GeoFix(lat: 40.0, lon: -83.0, at: DateTime.utc(2026, 10, 16, 18, 0, 30), accuracyM: 45),
    ));
    await settle(tester);
    expect(tester.widget<Text>(gpsTile).data, '±45 m');
    expect(gpsColor(), mc.snrWeak);

    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('a first-ever drive (no local history) counts every cell as new', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await tester.pumpAndSettle();

    h.engines.single.emit(DrivePing(id: 'p0', ts: DateTime.utc(2026, 10, 16, 18, 0, 0), lat: 40.0, lon: -83.0, echoes: const []));
    await settle(tester);
    expect(tester.widget<Text>(cellsTile).data, '1 new');
    expect(tester.widget<Text>(cellsLabel).data, '0 repeat');

    await h.state.stopDrive();
    await drain(tester);
  });
}
