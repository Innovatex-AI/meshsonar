// Coverage layer upgrade: res by zoom, filters, tap-cell sheet.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexPoint;
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/map/cell_sheet.dart';

NetworkCell square(double lat, double lon, double half, CoverageCell c) => NetworkCell(
  id: '$lat,$lon',
  boundary: [
    HexPoint(lat - half, lon - half),
    HexPoint(lat - half, lon + half),
    HexPoint(lat + half, lon + half),
    HexPoint(lat + half, lon - half),
  ],
  level: levelFor(c, CoverageColorBy.snr),
  cell: c,
);

void main() {
  test('resolution follows zoom, 7 to 11', () {
    expect(coverageResForZoom(9), 7);
    expect(coverageResForZoom(12), 8);
    expect(coverageResForZoom(13), 9);
    expect(coverageResForZoom(15), 10);
    expect(coverageResForZoom(17), 11);
  });

  test('query equality and auto res', () {
    const q = CoverageQuery(res: 9);
    expect(q.copyWith(autoRes: true).res, isNull);
    expect(q.copyWith(since: CoverageSince.day).since, CoverageSince.day);
    expect(q == const CoverageQuery(res: 9), isTrue);
  });

  test('cellAt finds the cell under a tap, smallest wins', () {
    const big = CoverageCell(lat: 40, lon: -83, pings: 1, heard: 0, bestSnr: null, medianSnr: null, repeaters: 0, lastAt: '');
    const small = CoverageCell(lat: 40, lon: -83, pings: 2, heard: 1, bestSnr: null, medianSnr: null, repeaters: 0, lastAt: '');
    final cells = [square(40, -83, 0.01, big), square(40, -83, 0.002, small)];
    expect(networkCellAt(cells, const LatLng(40.001, -83.001))!.cell!.pings, 2);
    expect(networkCellAt(cells, const LatLng(40.008, -83.0))!.cell!.pings, 1);
    expect(networkCellAt(cells, const LatLng(41, -83)), isNull);
  });

  test('last seen text', () {
    final now = DateTime.utc(2026, 10, 23, 12);
    expect(lastSeenText('2026-10-23T11:30:00Z', now: now), '30 min ago');
    expect(lastSeenText('2026-10-23T05:00:00Z', now: now), '7 h ago');
    expect(lastSeenText('2026-10-20T12:00:00Z', now: now), '3 d ago');
    expect(lastSeenText('junk'), '-');
  });

  testWidgets('cell sheet shows the measured numbers', (tester) async {
    const c = CoverageCell(
      lat: 40, lon: -83, pings: 10, heard: 6, bestSnr: 7.5, medianSnr: -1.0, repeaters: 3,
      lastAt: '2026-10-20T11:00:00Z', noiseFloor: -112.4,
    );
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: CellSheet(cell: square(40, -83, 0.01, c)))));
    expect(find.text('6 of 10 (60%)'), findsOneWidget);
    expect(find.text('+7.5 dB'), findsOneWidget);
    expect(find.text('-1.0 dB'), findsOneWidget);
    expect(find.text('-112 dBm'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
