// Drive report v2 screen: noise floor / RSSI / TX power / distance / speed / GPS sections, honest empty states, the
// SNR chart's numbers in semantics, the Chart/Table switch, the CSV export through the share seam, and units.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/report/drive_report_screen.dart';

import 'fakes.dart';

final t0 = DateTime.utc(2026, 10, 16, 18);
const mPerDegLat = 111195.0802;

DrivePing at(String id, int sec, {double lat = 40.1, List<Echo> echoes = const [], double? noise, double? tx, double? speed, double? acc}) =>
    DrivePing(
        id: id,
        ts: t0.add(Duration(seconds: sec)),
        lat: lat,
        lon: -82.93,
        echoes: echoes,
        noiseFloorDbm: noise,
        txDbm: tx,
        speedMps: speed,
        gpsAccuracyM: acc);

Harness radioDrive({UnitsPreference units = UnitsPreference.metric}) {
  final h = Harness();
  h.settings.saved = h.settings.saved.copyWith(units: units);
  h.cache.items = const [RepeaterRef(key: 'a1b2c3d4', name: 'Westerville North', lat: 40.1, lon: -82.93)];
  h.store.seed(DriveSession(id: 'rf', startedAt: t0, endedAt: t0.add(const Duration(minutes: 5))), [
    at('n1', 0, lat: 40.1 + 1500 / mPerDegLat, noise: -108, tx: 22, speed: 10, acc: 4,
        echoes: const [Echo(repeater: 'a1b2', snrDb: 6.5, rssiDbm: -82, hops: 1)]),
    at('n2', 60, lat: 40.1 + 600 / mPerDegLat, noise: -96, tx: 22, speed: 20, acc: 6,
        echoes: const [Echo(repeater: 'a1b2', snrDb: 9, rssiDbm: -70, hops: 1)]),
    at('n3', 120, lat: 40.1 + 3000 / mPerDegLat, noise: -104, tx: 20, speed: 20, acc: 60),
    at('n4', 180, lat: 40.1 + 3100 / mPerDegLat, noise: -103, tx: 20, speed: 3, acc: 5,
        echoes: const [Echo(repeater: 'a1b2', snrDb: -2, rssiDbm: -95, hops: 1)]),
  ]);
  return h;
}

Future<void> openReport(WidgetTester tester, Harness h, String id) async {
  useTallScreen(tester);
  await h.pumpApp(tester);
  openDriveReport(tester.element(find.byType(Scaffold).first), id);
  await tester.pumpAndSettle();
}

Finder get _list => find.descendant(of: find.byKey(const Key('report-list')), matching: find.byType(Scrollable)).first;

void main() {
  testWidgets('v2 sections show the radio side with numbers; SNR chart semantics carry them', (tester) async {
    final handle = tester.ensureSemantics();
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.scrollUntilVisible(find.byKey(const Key('report-snr-chart')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'^SNR of the strongest reply\. 4 pings, 3 heard, 1 heard nothing\. Best 9\.0 dB')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-noise')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'Median -103\.5 dBm, from -108\.0 to -96\.0 dBm, 4 readings\. 1 above -100 dBm')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-rssi')), 200, scrollable: _list);
    await tester.scrollUntilVisible(find.byKey(const Key('report-txpower')), 200, scrollable: _list);
    expect(find.textContaining('TX power changed 1 time: 22.0 dBm from'), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'under 1\.0 km: mean 9\.0 dB from 1 reading\. 1\.0 km to 2\.0 km: mean 6\.5 dB')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-speed')), 200, scrollable: _list);
    await tester.scrollUntilVisible(find.byKey(const Key('report-gps-poor')), 200, scrollable: _list);
    expect(tester.widget<Text>(find.byKey(const Key('report-gps-median'))).data, '6 m');
    expect(tester.widget<Text>(find.byKey(const Key('report-gps-poor'))).data, '1 of 4');
    handle.dispose();
  });

  testWidgets('the distance chart switches to a table with every band', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-distance')), 200, scrollable: _list);
    final toggle = find.descendant(of: find.byKey(const Key('chart-distance-toggle')), matching: find.text('Table'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('chart-distance-table')), findsOneWidget);
    expect(find.text('20 km and more'), findsOneWidget);
    expect(find.text('2.0 km to 5.0 km'), findsOneWidget);
  });

  testWidgets('imperial: band labels and GPS in miles/feet, no km anywhere in the v2 sections', (tester) async {
    final handle = tester.ensureSemantics();
    final h = radioDrive(units: UnitsPreference.imperial);
    await openReport(tester, h, 'rf');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'under 0\.6 mi: mean 9\.0 dB')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('report-gps-median')), 200, scrollable: _list);
    expect(tester.widget<Text>(find.byKey(const Key('report-gps-median'))).data, '18 ft'); // median 5.5 m
    expect(find.textContaining(RegExp(r'\bkm\b')), findsNothing);
    handle.dispose();
  });

  testWidgets('a drive with no radio readings: honest noise note, no RSSI/TX/distance/speed/GPS sections', (tester) async {
    final h = Harness();
    h.store.seed(DriveSession(id: 'bare', startedAt: t0, endedAt: t0.add(const Duration(minutes: 1))), [
      at('a', 0, echoes: const [Echo(repeater: 'ffee', snrDb: 2)]),
      at('b', 30),
    ]);
    await openReport(tester, h, 'bare');
    await tester.scrollUntilVisible(find.byKey(const Key('report-noise-none')), 200, scrollable: _list);
    expect(find.text('Your radio did not report a noise floor for this drive.'), findsOneWidget);
    expect(find.byKey(const Key('report-rssi')), findsNothing);
    expect(find.byKey(const Key('report-txpower')), findsNothing);
    expect(find.byKey(const Key('report-distance-bands')), findsNothing);
    expect(find.byKey(const Key('report-speed-bands')), findsNothing);
    expect(find.byKey(const Key('report-gps')), findsNothing);
  });

  testWidgets('Export menu: CSV goes through the share seam as one .csv file', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    expect(find.text('Contains your exact track'), findsOneWidget);
    await tester.tap(find.byKey(const Key('report-export-csv')));
    await tester.pumpAndSettle();
    // The file is written with real IO: let it run outside the fake clock, then let its callbacks land.
    for (var i = 0; i < 40 && h.shared.isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(h.shared, hasLength(1));
    expect(h.shared.single.path, endsWith('.csv'));
    final csv = await tester.runAsync(() => h.shared.single.readAsString());
    expect(csv, startsWith('table,ping_id,'));
    expect(csv, contains('Westerville North'));
    expect('\r\n'.allMatches(csv!).length, greaterThan(4));
  });
}
