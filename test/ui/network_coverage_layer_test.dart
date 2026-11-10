// The network-coverage background map layer (GET /api/cmh/public-coverage, the website's own measured cells —
// not just this drive's pings): on by default, drawn under everything else, toggled with the other layers.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import '../support/cell_layers.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/ui/app.dart' show MeshSonarApp;

import 'fakes.dart';
import '../support/huge_screen.dart';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Total polygons across every PolygonLayer on screen. Under `flutter test` the H3 plugin never loads (see
/// hex_cells.dart's loadHexEngine), so the drive's own hex layer always contributes 0 — any polygons found here
/// are the network-coverage layer's, unambiguously.
int polygonCount(WidgetTester tester) {
  return drawnCellCount(tester);
}

PublicCoverage twoCells() => PublicCoverage(
      asOf: '2026-10-20T12:00:00Z',
      grid: const CoverageGrid.square(cellDeg: 0.005),
      cells: const [
        CoverageCell(lat: 39.9612, lon: -82.9988, pings: 10, heard: 8, bestSnr: 6.0, medianSnr: 4.0, repeaters: 2, lastAt: '2026-10-20T11:00:00Z'),
        CoverageCell(lat: 39.97, lon: -83.01, pings: 5, heard: 1, bestSnr: -8.0, medianSnr: -8.0, repeaters: 1, lastAt: '2026-10-20T10:00:00Z'),
      ],
    );

/// A few bounded pumps: with cells on the very tall test surface the map keeps tile timers alive, so pumpAndSettle never returns.
Future<void> settleShort(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  testWidgets('drawn by default at startup, underneath the drive map, no manual step needed', (tester) async {
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 2);
  });

  testWidgets('toggled off and back on from the layers sheet, same as the other layers', (tester) async {
    useHugeScreen(tester); // a small test surface would put the (now 7-row) sheet right under the dismiss tap
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 2);

    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await settleShort(tester);
    expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
    final sw = tester.widget<Switch>(find.byKey(const Key('layer-network-coverage')));
    expect(sw.value, isTrue, reason: 'basic visibility: on by default, no extra step to find it');

    await tester.tap(find.byKey(const Key('layer-network-coverage')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('layers-done'))); // dismiss the sheet
    await settleShort(tester);
    expect(find.byKey(const Key('layers-sheet')), findsNothing);
    expect(polygonCount(tester), 0, reason: 'toggled off');

    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await settleShort(tester);
    await tester.tap(find.byKey(const Key('layer-network-coverage')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('layers-done')));
    await settleShort(tester);
    expect(polygonCount(tester), 2, reason: 'toggled back on');
  });

  testWidgets('no answer yet (or the endpoint 404s): blank map, no placeholder, no crash', (tester) async {
    final h = Harness(); // publicCoverageResult left null: the fake throws 404, same as a server without it
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 0);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('drive-map')), findsOneWidget, reason: 'the rest of the map is unaffected');
  });

  testWidgets('a later fetch failing never blanks cells already drawn (stale beats blank)', (tester) async {
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 2);

    h.client.publicCoverageResult = null;
    h.client.publicCoverageError = const CmatException('server error', status: 500);
    await h.state.refreshNetworkCoverage();
    await settle(tester);
    expect(polygonCount(tester), 2, reason: 'the earlier fetch\'s cells are kept, not cleared');
    expect(tester.takeException(), isNull);
  });

  testWidgets('coverage options: source and since chips refetch with the website params', (tester) async {
    useHugeScreen(tester);
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await settleShort(tester);
    // The Filters section is on the sheet's main page (the website's Layers panel): scroll it into view.
    await tester.ensureVisible(find.byKey(const Key('cov-source-meshmapper')));
    await settleShort(tester);
    await tester.tap(find.byKey(const Key('cov-source-meshmapper')));
    await settle(tester);
    expect(h.client.lastCoverageSource, 'meshmapper');
    expect(h.client.lastCoverageRes, inInclusiveRange(7, 11)); // auto: from the map zoom
    await tester.ensureVisible(find.byKey(const Key('cov-since-24h')));
    await settleShort(tester);
    await tester.tap(find.byKey(const Key('cov-since-24h')));
    await settle(tester);
    expect(h.client.lastCoverageSince, isNotNull);
    expect(find.byKey(const Key('cov-res-11')), findsNothing, reason: 'the detail chips are gone (coverage plan D1)');
    expect(h.client.lastCoverageMetric, isNull, reason: 'no coverageV2 on this server: the old path');
  });

  group('coverage v2 (site-config capability coverageV2)', () {
    Uint8List fx(String n) => File('test/fixtures/coverage_v2/$n').readAsBytesSync();
    Harness v2Harness(List<String> asked) {
      final h = Harness();
      h.client.siteConfigResult = const SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'coverageV2'});
      h.client.publicCoverageResult = twoCells();
      h.state.coverageV2ClientFactory = (u) => CoverageV2Client(u, client: MockClient((r) async {
        asked.add(r.url.path);
        final path = r.url.path;
        if (path.endsWith('/meta')) return http.Response.bytes(fx('meta.json'), 200);
        if (path.contains('/cell/')) return http.Response.bytes(fx('cell-measured.json'), 200);
        // Every measured tile answers with the Columbus z13 fixture's cells, every predicted tile with the z16 one: enough to see
        // that features reach the painter and are styled per band.
        if (path.contains('/tiles/measured/')) return http.Response.bytes(fx('measured-13-2207-3102.mvt'), 200);
        if (path.contains('/tiles/predicted/')) return http.Response.bytes(fx('predicted-16-17658-24819.mvt'), 200);
        return http.Response('', 404);
      }));
      return h;
    }

    testWidgets('the cells are fetched with metric=mean at res 11, the meta is read, and the tile layers draw', (tester) async {
      final asked = <String>[];
      final h = v2Harness(asked);
      await tester.runAsync(() async {
        await h.state.init();
        await h.state.refreshSiteConfig();
        await h.state.refreshNetworkCoverage();
        await h.state.refreshCoverageMeta();
      });
      expect(h.state.coverageV2, isTrue);
      expect(h.client.lastCoverageMetric, 'mean');
      expect(h.client.lastCoverageRes, 11);
      expect(h.state.coverageMeta.version, 101);
      await tester.pumpWidget(MeshSonarApp(state: h.state));
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.runAsync(() => h.state.coverageTiles.idle());
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(asked.any((p) => p.contains('/tiles/measured/')), isTrue);
      expect(find.byKey(const Key('coverage-measured-layer')), findsOneWidget);
      expect(find.byKey(const Key('network-cells-layer')), findsNothing, reason: 'live and unfiltered: the tiles draw, not the JSON cells');
      expect(drawnCellCount(tester), greaterThan(0));
    });
  });
}
