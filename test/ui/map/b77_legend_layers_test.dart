// Build 77 (redesign Round 1 F4, N1, N2; Round 4 section 3; Round 5 D-13, D-17): the one map chip and Legend panel, the Layers
// sheet in plain words, and the past drive's "Show whole drive".
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show kRosterLayerId;
import 'package:meshsonar/ui/map/legend_card.dart';
import 'package:meshsonar/ui/map/parts/map_chips.dart';
import 'package:meshsonar/ui/theme.dart';

Widget _app(Widget child, {Brightness b = Brightness.dark}) => MaterialApp(
  theme: meshSonarTheme(b),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

MapDefinition _v2m10() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor10-cmh.json').readAsStringSync());

void main() {
  tearDown(() => ActiveMapDefinition.debugSet());

  group('F4: the one map chip', () {
    testWidgets('36 pt drawn, 44 pt to tap, the outline of the region chip, a chevron when it opens something', (t) async {
      var taps = 0;
      await t.pumpWidget(_app(Center(child: MapChip(tapKey: const Key('chip'), label: const Text('Weak → strong'), onTap: () => taps++))));
      final r = t.getRect(find.byKey(const Key('chip')));
      expect(r.height, MapChip.height);
      await t.tapAt(Offset(r.center.dx, r.top - 3)); // inside the 44 pt hit area, outside the drawn chip
      expect(taps, 1);
      final box = t.widget<Container>(find.descendant(of: find.byKey(const Key('chip')), matching: find.byType(Container)).first);
      expect((box.decoration! as BoxDecoration).border, isNotNull, reason: 'outlined like the region and status chips');
      expect(find.byType(Icon), findsWidgets, reason: 'the chevron');
    });

    testWidgets('the legend chip says "Weak → strong" on every map (Drive, Live, Plan), compact or not', (t) async {
      for (final page in MapLegendPage.values) {
        for (final compact in [true, false]) {
          await t.pumpWidget(_app(LegendCard(key: ValueKey((page, compact)), on: const {'measured'}, page: page, compact: compact, onOpen: () {})));
          expect(find.text('Weak → strong'), findsOneWidget, reason: '$page compact $compact');
          expect(find.text('Weak → strong signal'), findsNothing);
          expect(t.getSize(find.byKey(const Key('legend-card-toggle'))).height, MapChip.height);
        }
      }
    });
  });

  group('N2: the Legend panel', () {
    testWidgets('coverage first, then my drive, repeaters, people; the extras that are not layers are there', (t) async {
      await t.pumpWidget(_app(const LegendCard(asPanel: true, on: {'measured', kRosterLayerId, 'observers', 'hexes'}, page: MapLegendPage.drive)));
      double y(String k) => t.getTopLeft(find.byKey(Key(k))).dy;
      expect(y('legend-section-coverage'), lessThan(y('legend-section-repeaters')));
      expect(y('legend-section-drive'), lessThan(y('legend-section-repeaters')));
      expect(y('legend-section-repeaters'), lessThan(y('legend-section-people')));
      for (final id in ['position', 'heardTick', 'cluster', 'selected', 'room']) {
        expect(find.byKey(Key('legend-extra-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Several repeaters'), findsOneWidget);
    });

    testWidgets('a short label opens its detail on a tap', (t) async {
      await t.pumpWidget(_app(const LegendCard(asPanel: true, on: {kRosterLayerId}, page: MapLegendPage.drive)));
      expect(find.textContaining('Zoom in to see each one'), findsNothing);
      await t.tap(find.byKey(const Key('legend-extra-cluster')));
      await t.pump();
      expect(find.textContaining('Zoom in to see each one'), findsOneWidget);
    });

    testWidgets('Live: packet colours and route lines in the same panel; no drive-only extras', (t) async {
      await t.pumpWidget(_app(const LegendCard(asPanel: true, on: {kRosterLayerId}, page: MapLegendPage.live)));
      expect(find.byKey(const Key('legend-section-live')), findsOneWidget);
      expect(find.text('Packet colours'), findsOneWidget);
      for (final type in [4, 5, 2, 3, 1, 9, 8, 0]) {
        expect(find.byKey(Key('legend-packet-$type')), findsOneWidget);
      }
      for (final id in ['known', 'likely', 'unplaced']) {
        expect(find.byKey(Key('legend-line-$id')), findsOneWidget);
      }
      expect(find.text('Known hop'), findsOneWidget);
      expect(find.byKey(const Key('legend-extra-position')), findsNothing, reason: 'no puck on Live');
    });

    testWidgets('Plan: the plan\'s magenta markers are in the legend', (t) async {
      ActiveMapDefinition.debugSet(_v2m10());
      await t.pumpWidget(_app(const LegendCard(asPanel: true, on: {'measured'}, page: MapLegendPage.plan)));
      expect(find.byKey(const Key('legend-layer-plan')), findsOneWidget);
    });

    test('the definition\'s legend block is read; an older definition gets the same words built in', () {
      final v = _v2m10().legendDef;
      expect(v.order.first, 'coverage');
      expect(v.extras.map((e) => e.id), containsAll(['position', 'heardTick', 'cluster', 'selected', 'room', 'friend', 'meet']));
      expect(v.lineStyles.map((l) => l.label), ['Known hop', 'Likely hop', 'Hop nobody can place']);
      final b = MapDefinition.bundled.legendDef;
      expect(b.order, v.order);
      expect(b.noReplyLabel, 'No reply');
      expect(_v2m10().layerSections.map((s) => s.id), ['style', 'coverage', 'drive', 'repeaters', 'people', 'appearance', 'filters']);
      expect(MapDefinition.bundled.layerSections, isEmpty);
      expect(layerSectionOf(MapDefinition.bundled.layerDef('measured')!), 'coverage');
      expect(layerSectionOf(MapDefinition.bundled.layerDef('observers')!), 'people');
    });
  });

  group('D-13: a past drive\'s map', () {
    testWidgets('the arrow becomes "Show whole drive": it frames the drive again and never turns on follow', (t) async {
      final pings = [
        DrivePing(id: 'a', ts: DateTime.utc(2026, 11, 1, 12), lat: 39.96, lon: -83.0),
        DrivePing(id: 'b', ts: DateTime.utc(2026, 11, 1, 12, 5), lat: 40.06, lon: -82.9),
      ];
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: Scaffold(body: SizedBox(width: 400, height: 400, child: CoverageMap(pings: pings, follow: false, fitToPings: true, showTiles: false, onLayers: () {}))),
      ));
      await t.pump();
      final handle = t.ensureSemantics();
      expect(find.bySemanticsLabel('Show whole drive'), findsOneWidget);
      handle.dispose();
      LatLng centre() => (t.state(find.byType(CoverageMap)) as dynamic).debugCenter as LatLng;
      final framed = centre();
      await t.drag(find.byType(CoverageMap), const Offset(150, 0));
      await t.pump();
      expect(centre().longitude, isNot(closeTo(framed.longitude, 1e-4)), reason: 'moved away');
      await t.tap(find.byKey(const Key('map-recenter')));
      await t.pump();
      expect((t.state(find.byType(CoverageMap)) as dynamic).debugFollowing as bool, isFalse, reason: 'never follows the last ping');
      expect(centre().latitude, closeTo(40.01, 0.02), reason: 'the whole drive is framed again');
      expect(centre().longitude, closeTo(-82.95, 0.02));
    });
  });
}
