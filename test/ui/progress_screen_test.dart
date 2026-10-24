// "Your progress" (stream 5 D2/D6): the Drives tab card (this ISO week from the drive list), the screen's scope line,
// totals, weekly charts with numbers in semantics and a Table view, records opening the drive report, the radio
// section (and its honest "not reported" text), units, and the empty / error + retry / damaged-drive states.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/report/progress_screen.dart';

import 'fakes.dart';

// Harness clock: Fri 16 Oct 2026 18:00 UTC. This ISO week starts Mon 12 Oct.
final thisWeek = DateTime.utc(2026, 10, 14, 15);
final lastWeek = DateTime.utc(2026, 10, 6, 15);
const mPerDegLat = 111195.0802;

DrivePing p(String id, DateTime t, int sec, double north, {bool heard = true, double? noise, double? tx}) => DrivePing(
      id: id,
      ts: t.add(Duration(seconds: sec)),
      lat: 40.101 + north / mPerDegLat,
      lon: -82.931,
      echoes: heard ? [Echo(repeater: 'a1b2', snrDb: 4.0 + sec / 60, hops: 1)] : const [],
      noiseFloorDbm: noise,
      txDbm: tx,
    );

Harness seeded({UnitsPreference units = UnitsPreference.metric, bool radio = true}) {
  final h = Harness();
  h.settings.saved = h.settings.saved.copyWith(units: units);
  h.store.seed(DriveSession(id: 'old', startedAt: lastWeek, endedAt: lastWeek.add(const Duration(minutes: 5)), label: 'Old loop'), [
    p('o1', lastWeek, 0, 0, noise: radio ? -108 : null, tx: radio ? 22 : null),
    p('o2', lastWeek, 60, 500, heard: false, noise: radio ? -106 : null, tx: radio ? 22 : null),
    p('o3', lastWeek, 120, 1000, noise: radio ? -104 : null, tx: radio ? 22 : null),
  ]);
  h.store.seed(DriveSession(id: 'new', startedAt: thisWeek, endedAt: thisWeek.add(const Duration(minutes: 10)), label: 'Long run'), [
    p('n1', thisWeek, 0, 0, noise: radio ? -98 : null, tx: radio ? 20 : null),
    p('n2', thisWeek, 60, 3000, noise: radio ? -97 : null, tx: radio ? 20 : null),
    p('n3', thisWeek, 120, 6000, heard: false, noise: radio ? -99 : null, tx: radio ? 20 : null),
    p('n4', thisWeek, 180, 9000, noise: radio ? -96 : null, tx: radio ? 20 : null),
  ]);
  return h;
}

Future<void> openFromDrivesTab(WidgetTester tester, Harness h) async {
  useTallScreen(tester);
  await h.pumpApp(tester);
  await tester.tap(find.text('Drives'));
  await tester.pumpAndSettle();
}

Future<void> openDirect(WidgetTester tester, Harness h) async {
  useTallScreen(tester);
  await h.pumpApp(tester);
  openProgress(tester.element(find.byType(Scaffold).first));
  await tester.pumpAndSettle();
}

Finder get _list => find.descendant(of: find.byKey(const Key('progress-list')), matching: find.byType(Scrollable)).first;

String _text(WidgetTester t, String key) => t.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('Drives tab card: this week from the drive list, and it opens the screen with the scope said plainly', (tester) async {
    final h = seeded();
    await openFromDrivesTab(tester, h);
    expect(_text(tester, 'progress-card-week'), 'This week (since Monday Oct 12): 1 drive, 4 pings, 75% heard.');
    await tester.tap(find.byKey(const Key('open-progress')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-screen')), findsOneWidget);
    expect(_text(tester, 'progress-scope'), startsWith('From drives stored on this phone: 2 drives since '));
    final drives = find.descendant(of: find.byKey(const Key('progress-total-drives')), matching: find.text('2'));
    expect(drives, findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('progress-total-heard')), matching: find.text('71%')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('progress-total-repeaters')), matching: find.text('1')), findsOneWidget);
  });

  testWidgets('weekly charts carry their numbers in semantics; the Table view lists every week', (tester) async {
    final handle = tester.ensureSemantics();
    final h = seeded();
    await openDirect(tester, h);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-distance')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'^Distance per week \(km\)\. 2 weeks\. Most: Week 42 \(Oct 12\), 9\.0 km in 1 drive\. This week 9\.0 km\.')),
        findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-heard')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'Best Week 42 \(Oct 12\), 75% of 4 pings\. This week 75%\.')), findsOneWidget);
    final toggle = find.descendant(of: find.byKey(const Key('chart-progress-heard-toggle')), matching: find.text('Table'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('chart-progress-heard-table')), matching: find.text('Week 41 (Oct 5)')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('chart-progress-heard-table')), matching: find.text('75%')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-cells')), 200, scrollable: _list);
    expect(find.textContaining('ISO weeks starting Monday, your phone\'s local time ('), findsWidgets);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-repeaters')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'^New repeaters per week\. 1 repeaters heard in all\. This week 0 new repeaters\.')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('records open the drive report; the radio section shows noise per drive, by hour and TX power', (tester) async {
    final handle = tester.ensureSemantics();
    final h = seeded();
    await openDirect(tester, h);
    await tester.scrollUntilVisible(find.byKey(const Key('progress-record-longest-distance')), 200, scrollable: _list);
    expect(find.descendant(of: find.byKey(const Key('progress-record-longest-distance')), matching: find.text('Long run')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-noise')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'Quietest -106\.0 dBm \(Old loop\), noisiest -97\.5 dBm \(Long run\)\. 1 above -100 dBm\.')),
        findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-noise-hour')), 200, scrollable: _list);
    await tester.scrollUntilVisible(find.byKey(const Key('chart-progress-txpower')), 200, scrollable: _list);
    expect(find.bySemanticsLabel(RegExp(r'2 drives, from 20\.0 to 22\.0 dBm\.')), findsOneWidget);
    await tester.scrollUntilVisible(find.byKey(const Key('progress-record-longest-distance')), -200, scrollable: _list);
    await tester.ensureVisible(find.byKey(const Key('progress-record-longest-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('progress-record-longest-distance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-report')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('a radio that reported nothing: one honest line, no empty charts', (tester) async {
    final h = seeded(radio: false);
    await openDirect(tester, h);
    await tester.scrollUntilVisible(find.byKey(const Key('progress-radio-none')), 200, scrollable: _list);
    expect(find.byKey(const Key('chart-progress-noise')), findsNothing);
    expect(find.byKey(const Key('chart-progress-txpower')), findsNothing);
  });

  testWidgets('imperial: distances in miles, no km anywhere', (tester) async {
    final h = seeded(units: UnitsPreference.imperial);
    await openDirect(tester, h);
    expect(find.descendant(of: find.byKey(const Key('progress-total-distance')), matching: find.text('6.2 mi')), findsOneWidget);
    expect(find.text('Distance per week (mi)'), findsOneWidget);
    expect(find.textContaining('km'), findsNothing);
  });

  testWidgets('no drives: no card on the Drives tab, and the screen says so', (tester) async {
    final h = Harness();
    await openFromDrivesTab(tester, h);
    expect(find.byKey(const Key('progress-card')), findsNothing);
    openProgress(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-empty')), findsOneWidget);
    expect(find.textContaining('From drives stored on this phone.'), findsOneWidget);
  });

  testWidgets('the store fails: an error with Try again, which recovers', (tester) async {
    final h = seeded();
    useTallScreen(tester);
    await h.pumpApp(tester);
    h.store.failSessions = true;
    openProgress(tester.element(find.byType(Scaffold).first));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-error')), findsOneWidget);
    h.store.failSessions = false;
    await tester.tap(find.byKey(const Key('progress-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('progress-list')), findsOneWidget);
  });

  testWidgets('a damaged drive is skipped and counted, the rest still shows', (tester) async {
    final h = seeded();
    h.store.failPings.add('old');
    await openDirect(tester, h);
    expect(find.byKey(const Key('progress-unreadable')), findsOneWidget);
    expect(_text(tester, 'progress-scope'), startsWith('From drives stored on this phone: 1 drive since '));
  });
}
