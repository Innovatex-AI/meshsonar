import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';

Color dotColor(WidgetTester tester, String id) {
  final box = tester.widget<DecoratedBox>(find.byKey(ValueKey('map-ping-$id')));
  return (box.decoration as BoxDecoration).color!;
}

Future<void> pumpMap(WidgetTester tester, Widget map, {Brightness b = Brightness.dark}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: meshSonarTheme(b),
      home: Scaffold(body: SizedBox(width: 600, height: 600, child: map)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 2)); // let the pulse finish
}

const tower = RepeaterRef(key: 'a1b2c3d4e5', name: 'Westerville Water Tower', lat: 40.13, lon: -82.925);
const hill = RepeaterRef(key: 'ff09aa', name: 'Otterbein Hill', lat: 40.12, lon: -82.937);

void main() {
  test('ping colours: silent is grey, SNR runs weak -> mid -> strong, unknown SNR is its own colour', () {
    final c = MeshSonarColors.dark;
    expect(c.forPing(heard: false), c.silent);
    expect(c.forPing(heard: true), c.heardUnknown);
    expect(c.forPing(heard: true, snr: -20), c.snrWeak);
    expect(c.forPing(heard: true, snr: 0), c.snrMid);
    expect(c.forPing(heard: true, snr: 15), c.snrStrong);
  });

  test('links resolve unique repeater prefixes only and keep the best SNR', () {
    final p = heardPing('p', const [
      Echo(repeater: 'a1b2', snrDb: 2),
      Echo(repeater: 'a1b2', snrDb: 6),
      Echo(repeater: 'ff', snrDb: -3), // ambiguous? no: only one ff... repeater
      Echo(repeater: '77', snrDb: 1), // unknown
    ]);
    final links = linksFor(p, const [tower, hill]);
    expect(links.map((l) => l.repeater.name), ['Westerville Water Tower', 'Otterbein Hill']);
    expect(links.first.snr, 6);
    expect(resolveRepeater(const [tower, RepeaterRef(key: 'a1ff', name: 'x', lat: 0, lon: 0)], 'a1'), isNull);
  });

  testWidgets('map draws every ping with its result colour, repeaters, and the position', (tester) async {
    final pings = [
      heardPing('strong', const [Echo(repeater: 'a1b2', snrDb: 12)], ts: DateTime.utc(2026, 10, 16, 18, 0, 0)),
      heardPing('weak', const [Echo(repeater: 'ff09', snrDb: -12)], ts: DateTime.utc(2026, 10, 16, 18, 0, 30)),
      silentPing('quiet'),
    ];
    await pumpMap(
      tester,
      CoverageMap(pings: pings, repeaters: const [tower, hill], position: const LatLng(40.126, -82.93)),
    );
    final c = MeshSonarColors.dark;
    expect(dotColor(tester, 'strong'), c.snrStrong);
    expect(dotColor(tester, 'weak'), c.snrWeak);
    expect(dotColor(tester, 'quiet'), c.silent);
    expect(find.byKey(const ValueKey('map-repeater-a1b2c3d4e5')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-repeater-ff09aa')), findsOneWidget);
    expect(find.byKey(const Key('map-position')), findsOneWidget);
    // Tiles are off under flutter test: the map says so instead of showing an empty grey box.
    expect(find.byKey(const Key('map-offline')), findsOneWidget);
    await tester.pump(const Duration(seconds: 20)); // link fade finishes
  });

  testWidgets('tapping a repeater shows its name', (tester) async {
    await pumpMap(tester, const CoverageMap(pings: [], repeaters: [tower], position: LatLng(40.13, -82.925)));
    expect(find.text('Westerville Water Tower'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('map-repeater-a1b2c3d4e5')));
    await tester.pump();
    expect(find.byKey(const Key('map-repeater-label')), findsOneWidget);
    expect(find.text('Westerville Water Tower'), findsWidgets); // the label and the panel title
  });

  testWidgets('attribution shows when tiles are on; dragging stops follow and offers Recenter', (tester) async {
    await pumpMap(
      tester,
      CoverageMap(pings: [silentPing('a')], position: const LatLng(40.126, -82.93), showTiles: true),
      b: Brightness.light,
    );
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    expect(find.byKey(const Key('map-recenter')), findsNothing);
    await tester.drag(find.byType(CoverageMap), const Offset(120, 80));
    await tester.pump();
    expect(find.byKey(const Key('map-recenter')), findsOneWidget);
    await tester.tap(find.byKey(const Key('map-recenter')));
    await tester.pump();
    expect(find.byKey(const Key('map-recenter')), findsNothing);
    // Network tile loads fail under test; drain them.
    await tester.pump(const Duration(seconds: 3));
  });
}
