// The clustered repeater layers fed by a RepeaterMapSource, tap -> MapHit -> detail sheet, and the sheets themselves.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/cluster_index.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexPoint;
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_cluster_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/sheets/map_hit_sheet.dart';
import 'package:meshsonar/ui/map/sheets/repeater_sheet.dart';

final now = DateTime.utc(2026, 10, 24, 12);
const cmh = RosterRegion(slug: 'cmh', name: 'CMH', baseUrl: 'https://cmh.meshsonar.com');
const attribution = 'Data: MeshCore Map (map.meshcore.io)';
String k(String c) => c * 64;

final globalRows = [
  MapRepeaterRow(key: k('a'), name: 'Alpha Tower', lat: 40.01, lon: -83, lastSeen: now.subtract(const Duration(hours: 3))),
  MapRepeaterRow(key: k('b'), name: null, lat: 40.0, lon: -82.99, isRoom: true, lastSeen: now.subtract(const Duration(days: 9))),
  MapRepeaterRow(key: k('c'), name: 'Roster too', lat: 39.99, lon: -83.01, lastSeen: now),
];
final roster = [
  RegionRepeater(
    key: k('c'),
    hashPrefix: 'cc',
    name: 'Roster too',
    lat: 39.99,
    lon: -83.01,
    status: RepeaterActivity.active,
    snrMeanDb: 6.5,
    signalGrade: 'A',
    adverts24h: 12,
    neighbours: 4,
    lastHeardAt: now.subtract(const Duration(minutes: 20)),
  ),
];

StaticRepeaterMapFeed feed() => StaticRepeaterMapFeed(
  global: MapRepeaterSet(rows: globalRows, state: MapFeedState.ready, attribution: attribution),
  region: MapRepeaterSet(rows: rosterRows(roster), state: MapFeedState.ready),
  rosterRegion: cmh,
  roster: roster,
);

void main() {
  group('RepeaterMapSource', () {
    testWidgets('builds both lists; the global layer leaves out roster keys unless told not to', (t) async {
      final src = RepeaterMapSource(feed(), clock: () => now);
      await t.pump();
      await src.settled;
      expect(src.rosterPoints.key, [k('c')]);
      expect(src.globalPoints.key, [k('a'), k('b')]);
      expect(src.globalPoints.skipped, 1);
      expect(src.globalPoints.band.toList(), [0, 2], reason: '3 h = 24 h band, 9 days = 30 d band');
      expect(src.rosterPoints.band.toList(), [RepeaterActivity.active.index]);
      src.dedupeAgainstRoster = false;
      await t.pump();
      await src.settled;
      expect(src.globalPoints.key, [k('a'), k('b'), k('c')]);
      src.dispose();
    });

    testWidgets('pointAt carries roster detail and region for a key the roster knows (also from the global layer)', (t) async {
      final src = RepeaterMapSource(feed(), clock: () => now)..dedupeAgainstRoster = false;
      await t.pump();
      await src.settled;
      final g = src.pointAt('network', 2);
      expect(g.source, RepeaterPointSource.global);
      expect(g.roster!.signalGrade, 'A');
      expect(g.region, cmh);
      expect(g.attribution, attribution);
      final b = src.pointAt('network', 1);
      expect(b.name, 'bbbbbbbb');
      expect(b.isRoom, isTrue);
      expect(b.region, isNull, reason: 'not in any roster: no region page link');
      final r = src.pointAt('repeaters', 0);
      expect(r.source, RepeaterPointSource.roster);
      expect(r.lastSeen, now.subtract(const Duration(minutes: 20)));
      src.dispose();
    });

    testWidgets('rebuilds only when the rows change identity; a stale result never overwrites a newer one', (t) async {
      final f = feed();
      final src = RepeaterMapSource(f, clock: () => now);
      await t.pump();
      await src.settled;
      final before = src.globalIndex;
      f.global = MapRepeaterSet(rows: f.global.rows, state: MapFeedState.stale, attribution: attribution);
      await t.pump();
      expect(src.globalIndex, same(before), reason: 'same rows: state change only');
      f.global = MapRepeaterSet(rows: [globalRows[0]], state: MapFeedState.ready);
      f.global = MapRepeaterSet(rows: [globalRows[1]], state: MapFeedState.ready);
      await t.pump();
      await src.settled;
      expect(src.globalPoints.key, [k('b')]);
      src.dispose();
    });

    testWidgets('a big list is clustered in a background isolate', (t) async {
      final rows = [for (var i = 0; i < 3000; i++) MapRepeaterRow(key: i.toRadixString(16).padLeft(64, '0'), lat: 30 + (i % 100) * 0.1, lon: -100 + (i ~/ 100) * 0.1)];
      final f = StaticRepeaterMapFeed(global: MapRepeaterSet(rows: rows, state: MapFeedState.ready));
      late RepeaterMapSource src;
      await t.runAsync(() async {
        src = RepeaterMapSource(f, clock: () => now, isolateThreshold: 1000);
        await src.settled;
      });
      expect(src.globalIndex!.indexedCount, 3000);
      src.dispose();
    });
  });

  group('layer + tap dispatch', () {
    Widget host(RepeaterMapSource src, String layerId, List<MapHit> hits, MapController c, {double zoom = 14}) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 400,
            height: 600,
            child: FlutterMap(
              mapController: c,
              options: MapOptions(initialCenter: const LatLng(40, -83), initialZoom: zoom),
              children: [RepeaterClusterLayer(source: src, layerId: layerId, onHit: hits.add, selectedKey: k('a'))],
            ),
          ),
        ),
      ),
    );

    testWidgets('tap a global repeater: a RepeaterHit for that key', (t) async {
      final src = RepeaterMapSource(feed(), clock: () => now);
      final hits = <MapHit>[];
      final c = MapController();
      await t.pumpWidget(host(src, 'network', hits, c));
      await src.settled;
      await t.pump();
      expect(find.byKey(const ValueKey('layer-network-paint')), findsOneWidget);
      await t.tapAt(c.camera.latLngToScreenOffset(const LatLng(40.01, -83)));
      await t.pump(const Duration(milliseconds: 400));
      final hit = hits.single as RepeaterHit;
      expect(hit.point.key, k('a'));
      expect(hit.point.name, 'Alpha Tower');
      src.dispose();
    });

    testWidgets('the roster layer draws the roster key', (t) async {
      final src = RepeaterMapSource(feed(), clock: () => now);
      final hits = <MapHit>[];
      final c = MapController();
      await t.pumpWidget(host(src, 'repeaters', hits, c));
      await src.settled;
      await t.pump();
      await t.tapAt(c.camera.latLngToScreenOffset(const LatLng(39.99, -83.01)));
      await t.pump(const Duration(milliseconds: 400));
      expect((hits.single as RepeaterHit).point.source, RepeaterPointSource.roster);
      src.dispose();
    });

    testWidgets('nothing loaded yet: the layer draws nothing and does not throw', (t) async {
      final src = RepeaterMapSource(StaticRepeaterMapFeed(), clock: () => now);
      await t.pumpWidget(host(src, 'network', [], MapController()));
      await t.pump();
      expect(find.byKey(const ValueKey('layer-network-paint')), findsNothing);
      src.dispose();
    });

    testWidgets('a cluster hit with a controller zooms in and opens no sheet', (t) async {
      final src = RepeaterMapSource(feed(), clock: () => now);
      final hits = <MapHit>[];
      final c = MapController();
      await t.pumpWidget(host(src, 'network', hits, c, zoom: 7));
      await src.settled;
      await t.pump();
      await t.tapAt(c.camera.latLngToScreenOffset(const LatLng(40.005, -82.995)));
      await t.pump(const Duration(milliseconds: 400));
      final hit = hits.single as ClusterHit;
      expect(hit.tap.count, 2);
      final ctx = t.element(find.byType(FlutterMap));
      final opened = await showMapHitSheet(ctx, hit, controller: c);
      await t.pump();
      expect(opened, isFalse);
      expect(c.camera.zoom, greaterThan(10));
      expect(find.byKey(const Key('repeater-sheet')), findsNothing);
      src.dispose();
    });
  });

  group('sheets', () {
    RepeaterPoint pt({RosterRegion? region, RegionRepeater? r, RepeaterPointSource source = RepeaterPointSource.global, bool room = false}) => RepeaterPoint(
      layerId: source == RepeaterPointSource.global ? 'network' : 'repeaters',
      source: source,
      key: k('a'),
      name: 'Alpha Tower',
      isRoom: room,
      lat: 40.01,
      lon: -83,
      band: 0,
      lastSeen: now.subtract(const Duration(hours: 3)),
      roster: r,
      region: region,
      attribution: source == RepeaterPointSource.global ? attribution : null,
    );

    Future<BuildContext> app(WidgetTester t) async {
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox.expand())));
      return t.element(find.byType(SizedBox).last);
    }

    testWidgets('global repeater: name, role, key, last advert, metric distance, source; no page link', (t) async {
      final ctx = await app(t);
      showRepeaterSheet(ctx, pt(), ctx: RepeaterSheetContext(position: const LatLng(40, -83), clock: () => now, openRegionPage: (_, _) {}));
      await t.pumpAndSettle();
      expect(find.text('Alpha Tower'), findsOneWidget);
      expect(find.text('Repeater'), findsOneWidget);
      expect(find.text('3 h ago (2026-10-24)'), findsOneWidget);
      expect(find.text('Last advert'), findsOneWidget);
      expect(find.text('1.1 km'), findsOneWidget);
      expect(find.text(attribution), findsOneWidget);
      final keyText = t.widget<RichText>(find.descendant(of: find.byKey(const Key('repeater-sheet-key')), matching: find.byType(RichText)));
      expect(keyText.text.toPlainText(), k('a'));
      expect(find.byKey(const Key('repeater-sheet-open')), findsNothing, reason: 'not in a known roster');
      expect(find.byKey(const Key('repeater-sheet-status')), findsNothing);
    });

    testWidgets('imperial units, no fix, room server', (t) async {
      final ctx = await app(t);
      showRepeaterSheet(ctx, pt(room: true), ctx: RepeaterSheetContext(position: const LatLng(40, -83), clock: () => now, units: Units.imperial));
      await t.pumpAndSettle();
      expect(find.text('0.7 mi'), findsOneWidget);
      expect(find.text('Room server'), findsOneWidget);
      Navigator.of(t.element(find.byKey(const Key('repeater-sheet')))).pop();
      await t.pumpAndSettle();
      showRepeaterSheet(ctx, pt(), ctx: RepeaterSheetContext(clock: () => now));
      await t.pumpAndSettle();
      expect(find.text('No position fix'), findsOneWidget);
    });

    testWidgets('roster repeater: roster figures, "Last heard", and Open repeater page calls the host', (t) async {
      final ctx = await app(t);
      final opened = <RepeaterPoint>[];
      showRepeaterSheet(
        ctx,
        pt(region: cmh, r: roster.single, source: RepeaterPointSource.roster),
        ctx: RepeaterSheetContext(clock: () => now, openRegionPage: (_, p) => opened.add(p)),
      );
      await t.pumpAndSettle();
      expect(find.text('Last heard'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('+6.5 dB'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
      expect(find.text('CC'), findsOneWidget);
      expect(find.text('MeshSonar region roster (CMH)'), findsOneWidget);
      await t.tap(find.byKey(const Key('repeater-sheet-open')));
      await t.pumpAndSettle();
      expect(opened.single.key, k('a'));
      expect(find.byKey(const Key('repeater-sheet')), findsNothing, reason: 'the sheet closes first');
    });

    testWidgets('copy key puts the full key on the clipboard', (t) async {
      final copied = <String>[];
      t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final ctx = await app(t);
      showRepeaterSheet(ctx, pt(), ctx: RepeaterSheetContext(clock: () => now));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('repeater-sheet-copy')));
      await t.pumpAndSettle();
      expect(copied, [k('a')]);
      expect(find.text('Key copied'), findsOneWidget);
    });

    testWidgets('unknown last advert reads "Not reported"', (t) async {
      final ctx = await app(t);
      final p = RepeaterPoint(layerId: 'network', source: RepeaterPointSource.global, key: k('d'), name: 'dddddddd', isRoom: false, lat: 1, lon: 1, band: 3);
      showRepeaterSheet(ctx, p, ctx: RepeaterSheetContext(clock: () => now));
      await t.pumpAndSettle();
      expect(find.text('Not reported'), findsOneWidget);
      expect(find.text(attribution), findsOneWidget, reason: 'default credit line for the global list');
    });

    testWidgets('dispatch: repeaters on one spot open a list, picking one opens its sheet', (t) async {
      final ctx = await app(t);
      final a = pt(), b = RepeaterPoint(layerId: 'network', source: RepeaterPointSource.global, key: k('b'), name: 'Bravo', isRoom: true, lat: 40.01, lon: -83, band: 1);
      const tap = ClusterTap(id: 1, count: 2, point: null, lat: 40.01, lon: -83, bounds: GeoBounds(south: 40.01, west: -83, north: 40.01, east: -83));
      final done = showMapHitSheet(ctx, ClusterHit('network', tap, colocated: [a, b]), repeaterContext: RepeaterSheetContext(clock: () => now));
      await t.pumpAndSettle();
      expect(find.text('2 repeaters at this spot'), findsOneWidget);
      await t.tap(find.byKey(ValueKey('repeater-list-${k('b')}')));
      await t.pumpAndSettle();
      expect(find.text('Bravo'), findsOneWidget);
      expect(find.text('Room server'), findsOneWidget);
      expect(await done, isTrue);
    });

    testWidgets('dispatch: a cell opens the cell sheet, a repeater the repeater sheet', (t) async {
      final ctx = await app(t);
      const c = CoverageCell(lat: 40, lon: -83, pings: 4, heard: 2, bestSnr: 3.0, medianSnr: 1.0, repeaters: 1, lastAt: '2026-10-24T10:00:00Z');
      const cell = NetworkCell(
        id: '40,-83',
        boundary: [HexPoint(39.99, -83.01), HexPoint(39.99, -82.99), HexPoint(40.01, -82.99), HexPoint(40.01, -83.01)],
        level: CoverageLevel.good,
        cell: c,
      );
      showMapHitSheet(ctx, const CellHit(cell));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cell-sheet')), findsOneWidget);
      Navigator.of(t.element(find.byKey(const Key('cell-sheet')))).pop();
      await t.pumpAndSettle();
      showMapHitSheet(ctx, RepeaterHit(pt()), repeaterContext: RepeaterSheetContext(clock: () => now));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
    });
  });
}
