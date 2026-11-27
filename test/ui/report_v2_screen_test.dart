// Drive report v2 screen: noise floor / RSSI / TX power / distance / speed / GPS sections, honest empty states, the
// SNR chart's numbers in semantics, the Chart/Table switch, the CSV export through the share seam, and units.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/drive_report.dart';
import 'package:meshsonar/core/time_format.dart' as tf;
import 'package:meshsonar/ui/report/drive_report_screen.dart';
import 'package:meshsonar/ui/report/drive_report_sections.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';
import 'toast_test_kit.dart';

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
  // The report is built from the store asynchronously: wait for its list.
  for (var i = 0; i < 100 && find.byKey(const Key('report-list')).evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Finder get _list => find.descendant(of: find.byKey(const Key('report-list')), matching: find.byType(Scrollable)).first;

/// Round 5 D-11: the radio charts sit folded in "Radio details"; scroll to a row and open it.
Future<void> openRow(WidgetTester tester, String id) async {
  await tester.scrollUntilVisible(find.byKey(Key('radio-row-$id')), 200, scrollable: _list);
  await tester.ensureVisible(find.byKey(Key('radio-row-$id')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key('radio-row-$id')));
  await tester.pumpAndSettle();
}

String readingOf(WidgetTester tester, String id) => tester.widget<Text>(find.byKey(Key('radio-reading-$id'))).data!;

void main() {
  testWidgets('v2 sections show the radio side with numbers; SNR chart semantics carry them', (tester) async {
    final handle = tester.ensureSemantics();
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.scrollUntilVisible(find.byKey(const Key('report-snr-chart')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'^Signal of the strongest reply \(SNR\)\. 4 pings, 3 heard, 1 heard nothing\. Best 9\.0 dB')), findsOneWidget);
    // One-line readings, plain words first (D-2, D-11).
    await tester.scrollUntilVisible(find.byKey(const Key('report-radio-details')), 200, scrollable: _list);
    expect(readingOf(tester, 'noise'), 'Noise floor: raised, -104 dBm');
    expect(readingOf(tester, 'rssi'), 'Reply strength: median -82 dBm, strongest -70 dBm');
    expect(readingOf(tester, 'txpower'), 'Transmit power: changed 1 time');
    expect(readingOf(tester, 'distance'), 'Signal by distance: Strong under 1.0 km, fair at 2.0 km to 5.0 km');
    expect(readingOf(tester, 'gps'), 'GPS: good, within 6 m');
    expect(find.byKey(const Key('chart-noise')), findsNothing);
    await openRow(tester, 'noise');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-noise')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'Median -103\.5 dBm, from -108\.0 to -96\.0 dBm, 4 readings\. 1 above -100 dBm')), findsOneWidget);
    await openRow(tester, 'rssi');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-rssi')), 200, scrollable: _list);
    await openRow(tester, 'txpower');
    await tester.scrollUntilVisible(find.byKey(const Key('report-txpower')), 200, scrollable: _list);
    expect(find.textContaining('Transmit power changed 1 time: 22 dBm from'), findsOneWidget);
    await openRow(tester, 'distance');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'under 1\.0 km: mean 9\.0 dB from 1 reading\. 1\.0 km to 2\.0 km: mean 6\.5 dB')), findsOneWidget);
    await openRow(tester, 'speed');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-speed')), 200, scrollable: _list);
    await openRow(tester, 'gps');
    await tester.scrollUntilVisible(find.byKey(const Key('report-gps-poor')), 200, scrollable: _list);
    expect(tester.widget<Text>(find.byKey(const Key('report-gps-median'))).data, '6 m');
    expect(tester.widget<Text>(find.byKey(const Key('report-gps-poor'))).data, '1 of 4');
    handle.dispose();
  });

  testWidgets('the distance chart switches to a table with every band', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await openRow(tester, 'distance');
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
    await openRow(tester, 'distance');
    await tester.scrollUntilVisible(find.byKey(const Key('chart-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'under 0\.6 mi: mean 9\.0 dB')), findsOneWidget);
    await openRow(tester, 'gps');
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
    await tester.scrollUntilVisible(find.byKey(const Key('report-radio-details')), 200, scrollable: _list);
    expect(readingOf(tester, 'noise'), 'Noise floor: not reported');
    for (final id in ['rssi', 'txpower', 'distance', 'speed', 'gps']) {
      expect(find.byKey(Key('radio-row-$id')), findsNothing, reason: id);
    }
    await openRow(tester, 'noise');
    await tester.scrollUntilVisible(find.byKey(const Key('report-noise-none')), 200, scrollable: _list);
    expect(find.text('Your radio did not report a noise floor for this drive.'), findsOneWidget);
    expect(find.byKey(const Key('report-rssi')), findsNothing);
    expect(find.byKey(const Key('report-txpower')), findsNothing);
    expect(find.byKey(const Key('report-distance-bands')), findsNothing);
    expect(find.byKey(const Key('report-speed-bands')), findsNothing);
    expect(find.byKey(const Key('report-gps')), findsNothing);
  });

  testWidgetsT('Export menu: cancel shares nothing; a failed share shows an error toast', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-export-text')), findsNothing);
    expect(h.shared, isEmpty);
    h.shareError = StateError('nope');
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('report-export-text')));
    await tester.pumpAndSettle();
    for (var i = 0; i < 40 && find.textContaining('Couldn\'t share the report').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump();
    }
    expect(find.textContaining('Couldn\'t share the report'), findsOneWidget);
  });

  testWidgets('Export menu: CSV goes through the share seam as one .csv file', (tester) async {
    final h = radioDrive();
    await openReport(tester, h, 'rf');
    await tester.tap(find.byKey(const Key('report-export')));
    await tester.pumpAndSettle();
    expect(find.textContaining('The spreadsheet and the drive file contain your exact track'), findsOneWidget);
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

  testWidgets('Round 5 D-18: report times follow the time setting and the caption names the zone', (tester) async {
    addTearDown(() => tf.activeTimeZone = tf.TimeZonePreference.phone);
    final h = radioDrive();
    // Settings > Map & display > Time zone: UTC (the app applies it when the settings load).
    h.settings.saved = h.settings.saved.copyWith(timeZone: tf.TimeZonePreference.utc);
    await openReport(tester, h, 'rf');
    await openRow(tester, 'txpower');
    expect(find.textContaining(tf.timeOfDay(t0, showZone: false)), findsWidgets);
    expect(find.textContaining('(times UTC)'), findsOneWidget);
    expect(find.textContaining('local time'), findsNothing);
  });

  testWidgets('Round 5 D-14: percent heard is teal, the noise line is neutral unless the noise is high', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    final m = MeshSonarColors.of(ctx);
    expect(noiseLineColor(ctx, -111), Theme.of(ctx).colorScheme.onSurfaceVariant);
    expect(noiseLineColor(ctx, -95), m.warning);
    final r = DriveReport.compute(session: DriveSession(id: 'x', startedAt: t0), pings: [
      at('a', 0, echoes: const [Echo(repeater: 'aa', snrDb: -12)]),
      at('b', 30, lat: 40.2),
    ]);
    final heard = r.cells.firstWhere((c) => c.heard > 0), silent = r.cells.firstWhere((c) => c.heard == 0);
    // A fully heard cell with a weak reply is still the top of the teal scale: heard % is not signal strength.
    expect(heardColor(m, heard), m.heardStops.last);
    expect(heardColor(m, silent), m.silent);
  });
}
