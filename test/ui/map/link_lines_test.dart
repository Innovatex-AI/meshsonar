// Tap a coverage cell -> a line to every repeater heard there; tap a repeater -> a line to every cell it was heard in;
// each with its SNR, a chip to fit or clear them. Needs libh3 (brew install h3); skipped without it.
import 'dart:io';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/hex_cells.dart';
import 'package:meshsonar/core/map_links.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/map_layers.dart';
import 'package:meshsonar/ui/map/layers/map_layers_adapter.dart';

import '../fakes.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

String k(String c) => c * 64;
const _site = SiteConfig(
  region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'),
  capabilities: {'cellLinks', 'reachDriverKey'},
);

class _LinksClient extends FakeCmatClient {
  _LinksClient(super.u);
  final cellCalls = <String>[];
  final reachCalls = <String>[];
  late Future<CellLinks> Function(String h3) onCell;
  late Future<RepeaterReach> Function(String key) onReach;
  @override
  Future<CellLinks> cellLinks(String driverKey, String h3) {
    cellCalls.add(h3);
    return onCell(h3);
  }

  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon, bool h3 = false}) {
    reachCalls.add(repeaterKey);
    return onReach(repeaterKey);
  }
}

class _H extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => _LinksClient(u)..siteConfigResult = _site;
  _LinksClient get lc => client as _LinksClient;
}

void main() {
  final h3 = _load();
  final skip = h3 == null;

  final cellId = h3 == null ? '' : hexId(hexCellOf(h3, 40.0, -83.0));
  final centre = h3 == null ? const GeoCoord(lon: 0, lat: 0) : h3.cellToGeo(BigInt.parse(cellId, radix: 16));

  Future<_H> pump(WidgetTester tester, {bool approved = true, bool charlieInCell = false}) async {
    useTallScreen(tester);
    final h = _H();
    if (approved) h.approveKey();
    h.lc.onCell = (id) async => CellLinks(
      h3: id,
      links: [
        CellLink(key: k('a'), pings: 9, bestSnr: 6.5),
        CellLink(key: k('b'), pings: 4, bestSnr: -3),
        CellLink(key: k('f'), pings: 1, bestSnr: 1), // not on the map
      ],
    );
    h.lc.onReach = (key) async => RepeaterReach(
      key: key,
      cellDeg: 0.0025,
      cells: [
        ReachCell(lat: centre.lat, lon: centre.lon, pings: 5, bestSnr: 2.5),
        ReachCell(lat: centre.lat + 0.03, lon: centre.lon, pings: 2, bestSnr: -6),
      ],
      totals: const ReachTotals(heardPings: 7, drives: 1, drivers: 1),
      snrByDistance: const [],
    );
    await h.pumpApp(tester);
    await tester.runAsync(() => h.state.refreshUploadSiteConfig(force: true));
    CoverageMap.hexEngine = h3;
    addTearDown(() => CoverageMap.hexEngine = null);
    final feed = StaticRepeaterMapFeed(
      global: MapRepeaterSet(
        rows: [
          MapRepeaterRow(
            key: k('a'),
            name: 'Alpha Tower',
            lat: centre.lat + 0.01,
            lon: centre.lon,
            lastSeen: h.clockNow,
          ),
          MapRepeaterRow(key: k('b'), name: 'Bravo', lat: centre.lat, lon: centre.lon + 0.02, lastSeen: h.clockNow),
          if (charlieInCell) MapRepeaterRow(key: k('c'), name: 'Charlie', lat: centre.lat, lon: centre.lon, lastSeen: h.clockNow),
        ],
        state: MapFeedState.ready,
      ),
    );
    final src = RepeaterMapSource(feed, clock: () => h.clockNow);
    addTearDown(src.dispose);
    final cells = buildNetworkCells(
      PublicCoverage(
        cells: [
          CoverageCell(
            lat: centre.lat,
            lon: centre.lon,
            pings: 20,
            heard: 15,
            bestSnr: 6,
            medianSnr: 2,
            repeaters: 3,
            lastAt: '2026-10-31T10:00:00Z',
            h3: cellId,
          ),
        ],
        asOf: '2026-10-31T10:00:00Z',
        grid: CoverageGrid.h3(res: 9, cellDeg: 0.005, pending: 0),
      ),
      h3,
      CoverageColorBy.snr,
    );
    await tester.pumpWidget(
      AppScope(
        state: h.state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: Scaffold(
            body: CoverageMap(
              pings: const [],
              position: LatLng(centre.lat, centre.lon),
              hexRes: 9,
              layerState: const MapLayers().toLayerState().toggle(kNetworkLayerId, true),
              networkCells: cells,
              repeaterSource: src,
            ),
          ),
        ),
      ),
    );
    await src.settled;
    await tester.pump(const Duration(milliseconds: 300));
    return h;
  }

  Offset screenOf(WidgetTester t, double lat, double lon) {
    final cam = MapCamera.of(t.element(find.byType(CellRasterLayer).first));
    return cam.latLngToScreenOffset(LatLng(lat, lon));
  }

  testWidgets('tap a repeater that sits INSIDE a coverage cell: the repeater panel and its lines win, not the cell', (tester) async {
    final h = await pump(tester, charlieInCell: true);
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon));
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.lc.reachCalls, [k('c')]);
    expect(h.lc.cellCalls, isEmpty, reason: 'the cell under the repeater must not take the tap');
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('No MeshSonar drive has heard it yet'), findsNothing);
    expect(find.text('Heard in 2 cells  ·  tap to expand'), findsOneWidget);
  }, skip: skip);

  testWidgets('tap a cell: lines to the repeaters heard there, SNR labels, a chip, and the sheet', (tester) async {
    final h = await pump(tester);
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon)); // inside the cell, away from Charlie
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.lc.cellCalls, [cellId]);
    expect(find.byKey(const Key('info-panel-header')), findsOneWidget);
    expect(find.byKey(const Key('cell-sheet')), findsNothing, reason: 'collapsed: the map stays the focus');
    expect(find.byKey(const Key('link-lines')), findsOneWidget);
    expect(find.text('+6.5 dB'), findsOneWidget);
    expect(find.text('-3.0 dB'), findsOneWidget);
    expect(find.text('2 repeaters heard here (+1 not on the map)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('cell-sheet')), findsOneWidget);
    expect(find.byKey(const Key('cell-repeater-list')), findsOneWidget);
    expect(find.text('Alpha Tower'), findsOneWidget);
  }, skip: skip);

  testWidgets('a short stored id (key prefix) is placed when exactly one repeater starts with it', (tester) async {
    final h = await pump(tester);
    h.lc.onCell = (id) async => CellLinks(
      h3: id,
      links: [
        CellLink(key: 'aaaa', pings: 9, bestSnr: 6.5), // Alpha only
        CellLink(key: 'abab', pings: 2, bestSnr: 1), // nobody
      ],
    );
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('+6.5 dB'), findsOneWidget);
    expect(find.text('1 repeater heard here (+1 not on the map)'), findsOneWidget);
  }, skip: skip);

  testWidgets('clear puts the lines away; a tap on empty map does too', (tester) async {
    final h = await pump(tester);
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('info-panel-header')), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-clear')));
    await tester.pump();
    expect(find.byKey(const Key('info-panel-header')), findsNothing);
    expect(find.byKey(const Key('link-lines')), findsNothing);
    expect(h.lc.cellCalls, hasLength(1));
  }, skip: skip);

  testWidgets('tap a repeater: lines to every cell it was heard in', (tester) async {
    final h = await pump(tester);
    await tester.tapAt(screenOf(tester, centre.lat + 0.01, centre.lon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.lc.reachCalls, [k('a')]);
    expect(find.byKey(const Key('link-lines')), findsOneWidget);
    expect(find.text('Heard in 2 cells  ·  tap to expand'), findsOneWidget);
    expect(find.text('+2.5 dB'), findsOneWidget);
    expect(find.text('-6.0 dB'), findsOneWidget);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reach-stats')), findsOneWidget);
    expect(find.text('Pings heard'), findsOneWidget);
    expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
  }, skip: skip);

  testWidgets('a repeater no drive has heard says so in the panel, and the lines are orange', (tester) async {
    final h = await pump(tester);
    h.lc.onReach = (key) async => RepeaterReach(
      key: key,
      cellDeg: 0.0025,
      cells: const [],
      totals: const ReachTotals(heardPings: 0, drives: 0, drivers: 0),
      snrByDistance: const [],
    );
    await tester.tapAt(screenOf(tester, centre.lat + 0.01, centre.lon));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('No MeshSonar drive has heard it yet'), findsOneWidget);
    expect(find.byKey(const Key('link-lines')), findsNothing);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pumpAndSettle();
    expect(find.text('No MeshSonar drive has heard this repeater yet.'), findsOneWidget);
    // a repeater with data: every line is the one orange, whatever its SNR
    await tester.tap(find.byKey(const Key('link-clear')));
    await tester.pump();
    h.lc.onReach = (key) async => RepeaterReach(
      key: key,
      cellDeg: 0.0025,
      cells: [ReachCell(lat: centre.lat, lon: centre.lon, pings: 5, bestSnr: 2.5), ReachCell(lat: centre.lat + 0.03, lon: centre.lon, pings: 2, bestSnr: -6)],
      totals: const ReachTotals(heardPings: 7, drives: 1, drivers: 1),
      snrByDistance: const [],
    );
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon + 0.02)); // Bravo: the first answer for Alpha is cached
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    final lines = tester.widget<PolylineLayer>(find.byKey(const Key('link-lines')));
    expect(lines.polylines.map((p) => p.color).toSet(), {const Color(0xFFFF6D00)});
  }, skip: skip);

  testWidgets('no approved key: nothing is asked and no chip shows', (tester) async {
    final h = await pump(tester, approved: false);
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.lc.cellCalls, isEmpty);
    expect(find.byKey(const Key('link-lines')), findsNothing);
  }, skip: skip);

  testWidgets('a failed ask says so instead of drawing nothing silently', (tester) async {
    final h = await pump(tester);
    h.lc.onCell = (_) => Future.error(const CmatException('offline'));
    await tester.tapAt(screenOf(tester, centre.lat, centre.lon));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('Couldn\'t load the links'), findsOneWidget);
    expect(find.byKey(const Key('link-lines')), findsNothing);
  }, skip: skip);
}
