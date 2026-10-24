// Repeater "Your drives" section (stream 5 D7) in the app: facts from every drive on this phone, the cell map, the
// drives list opening a drive report, the shared-id note, nothing heard, no drives, units, the drive repeater sheet
// hosting it, and no AppScope (an isolated screen test) rendering nothing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/repeater_detail_sheet.dart';
import 'package:meshsonar/ui/your_drives_section.dart';

import 'fakes.dart';

final t0 = DateTime.utc(2026, 10, 14, 15);
const mPerDegLat = 111195.0802;
const key = 'a1b2c3d4';

DrivePing p(String id, int min, double north, List<Echo> echoes) =>
    DrivePing(id: id, ts: t0.add(Duration(minutes: min)), lat: 40.101 + north / mPerDegLat, lon: -82.931, echoes: echoes);

Harness seeded({UnitsPreference units = UnitsPreference.metric}) {
  final h = Harness();
  h.settings.saved = h.settings.saved.copyWith(units: units);
  h.cache.items = const [
    RepeaterRef(key: key, name: 'Westerville North', lat: 40.101, lon: -82.931),
    RepeaterRef(key: 'c0ffee00', name: 'Other C0', lat: 40.2, lon: -83),
    RepeaterRef(key: 'c0aa0000', name: 'Another C0', lat: 40.2, lon: -83),
  ];
  h.store.seed(DriveSession(id: 'd1', startedAt: t0, label: 'Morning'), [
    p('1', 0, 0, const [Echo(repeater: 'a1b2', snrDb: 4, hops: 1)]),
    p('2', 1, 1500, const [Echo(repeater: 'a1', snrDb: 7.5, hops: 2)]),
  ]);
  h.store.seed(DriveSession(id: 'd2', startedAt: t0.add(const Duration(days: 1)), label: 'Evening'), [
    p('3', 1440, 3000, const [Echo(repeater: 'A1B2C3', snrDb: -2, hops: 1)]),
  ]);
  h.store.seed(DriveSession(id: 'd3', startedAt: t0.add(const Duration(days: 2))), [p('4', 2880, 0, const [])]);
  return h;
}

Future<void> show(WidgetTester tester, Harness h, Widget child) async {
  useTallScreen(tester);
  await h.pumpApp(tester);
  Navigator.of(tester.element(find.byType(Scaffold).first))
      .push(MaterialPageRoute<void>(builder: (_) => Scaffold(body: ListView(children: [child]))));
  await tester.pumpAndSettle();
}

String _text(WidgetTester t, String k) => t.widget<Text>(find.byKey(Key(k))).data!;

void main() {
  testWidgets('every drive that heard it: times, direct, best SNR, cells, farthest, drives newest first', (tester) async {
    final h = seeded();
    await show(tester, h, const YourDrivesSection(repeaterKey: key, lat: 40.101, lon: -82.931));
    expect(find.text('From drives stored on this phone.'), findsOneWidget);
    expect(_text(tester, 'your-drives-heard'), '3 times on 2 of 3 drives (2 direct)');
    expect(_text(tester, 'your-drives-best'), '7.5 dB (Morning)');
    expect(_text(tester, 'your-drives-cells'), '3');
    expect(_text(tester, 'your-drives-farthest'), '3.0 km from the repeater');
    expect(find.byKey(const Key('your-drives-map')), findsOneWidget);
    final evening = tester.getTopLeft(find.byKey(const Key('your-drives-drive-d2'))).dy;
    final morning = tester.getTopLeft(find.byKey(const Key('your-drives-drive-d1'))).dy;
    expect(evening, lessThan(morning));
    expect(find.byKey(const Key('your-drives-shared')), findsNothing);
    await tester.tap(find.byKey(const Key('your-drives-drive-d1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('drive-report')), findsOneWidget);
  });

  testWidgets('imperial: the farthest distance in miles', (tester) async {
    final h = seeded(units: UnitsPreference.imperial);
    await show(tester, h, const YourDrivesSection(repeaterKey: key, lat: 40.101, lon: -82.931));
    expect(_text(tester, 'your-drives-farthest'), '1.9 mi from the repeater');
    expect(find.textContaining(' km'), findsNothing);
  });

  testWidgets('a short id two known repeaters share: counted, and said', (tester) async {
    final h = seeded();
    h.store.seed(DriveSession(id: 'd4', startedAt: t0.add(const Duration(days: 3))), [
      p('5', 4320, 0, const [Echo(repeater: 'c0', snrDb: 1)]),
    ]);
    await show(tester, h, const YourDrivesSection(repeaterKey: 'c0ffee00'));
    expect(_text(tester, 'your-drives-heard'), '1 time on 1 of 4 drives');
    expect(find.byKey(const Key('your-drives-shared')), findsOneWidget);
  });

  testWidgets('never heard, and no drives at all: one plain line each', (tester) async {
    final h = seeded();
    await show(tester, h, const YourDrivesSection(repeaterKey: 'ffffffff'));
    expect(_text(tester, 'your-drives-none'), 'None of the 3 drives on this phone heard this repeater.');
    expect(find.byKey(const Key('your-drives-map')), findsNothing);
  });

  testWidgets('no drives on the phone', (tester) async {
    await show(tester, Harness(), const YourDrivesSection(repeaterKey: key));
    expect(_text(tester, 'your-drives-none'), 'No drives on this phone yet.');
  });

  testWidgets('the drive repeater sheet carries the section for the id as heard', (tester) async {
    final h = seeded();
    await show(
        tester,
        h,
        SizedBox(
          height: 1600,
          child: RepeaterDetailSheet(id: 'a1b2', lookup: h.state.lookup, pings: [p('1', 0, 0, const [Echo(repeater: 'a1b2', snrDb: 4, hops: 1)])]),
        ));
    await tester.scrollUntilVisible(find.byKey(const Key('your-drives-heard')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('repeater-detail')), matching: find.byType(Scrollable)).first);
    expect(_text(tester, 'your-drives-heard'), '3 times on 2 of 3 drives (2 direct)');
  });

  testWidgets('without AppScope (an isolated screen) it renders nothing', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: YourDrivesSection(repeaterKey: key))));
    await tester.pump();
    expect(find.byKey(const Key('your-drives')), findsNothing);
  });
}
