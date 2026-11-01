// The network-coverage background map layer (GET /api/cmh/public-coverage, the website's own measured cells —
// not just this drive's pings): on by default, drawn under everything else, toggled with the other layers.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/cell_layers.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';

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

void main() {
  testWidgets('drawn by default at startup, underneath the drive map, no manual step needed', (tester) async {
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 2);
  });

  testWidgets('toggled off and back on from the layers sheet, same as the other layers', (tester) async {
    useTallScreen(tester); // a small test surface would put the (now 7-row) sheet right under the dismiss tap
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    expect(polygonCount(tester), 2);

    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
    final sw = tester.widget<SwitchListTile>(find.byKey(const Key('layer-network-coverage')));
    expect(sw.value, isTrue, reason: 'basic visibility: on by default, no extra step to find it');

    await tester.tap(find.byKey(const Key('layer-network-coverage')));
    await settle(tester);
    await tester.tapAt(const Offset(200, 60)); // dismiss the sheet
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('layers-sheet')), findsNothing);
    expect(polygonCount(tester), 0, reason: 'toggled off');

    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('layer-network-coverage')));
    await settle(tester);
    await tester.tapAt(const Offset(200, 60));
    await tester.pumpAndSettle();
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
    useTallScreen(tester);
    final h = Harness();
    h.client.publicCoverageResult = twoCells();
    await h.pumpApp(tester);
    await settle(tester);
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.pumpAndSettle();
    // The generated sheet lists "This drive" first, so the coverage controls sit lower: scroll them into view.
    await tester.ensureVisible(find.byKey(const Key('coverage-layer-controls')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coverage-layer-controls')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('cov-source-MeshMapper')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cov-source-MeshMapper')));
    await settle(tester);
    expect(h.client.lastCoverageSource, 'meshmapper');
    expect(h.client.lastCoverageRes, inInclusiveRange(7, 11)); // auto: from the map zoom
    await tester.ensureVisible(find.byKey(const Key('cov-since-24 h')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cov-since-24 h')));
    await settle(tester);
    expect(h.client.lastCoverageSince, isNotNull);
    await tester.ensureVisible(find.byKey(const Key('cov-res-11')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cov-res-11')));
    await settle(tester);
    expect(h.client.lastCoverageRes, 11);
  });
}
