// Network coverage cells (the website's /coverage data turned into drawable squares/hexagons): colour-by
// thresholds (ported from meshcore-insights `src/components/coverage/cells.ts`) and geometry.
//
// Square-cell geometry needs no H3 engine. Hexagon geometry needs libh3 on the machine running the tests (macOS:
// `brew install h3`, v4) — loaded the same direct-FFI way test/hex_cells_test.dart does, skipped when it's not
// there.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/network_coverage.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) {
      continue;
    }
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

CoverageCell _cell({
  double lat = 39.9612,
  double lon = -82.9988,
  int pings = 10,
  int heard = 5,
  double? bestSnr,
  double? noiseFloor,
  String? h3,
}) =>
    CoverageCell(
      lat: lat,
      lon: lon,
      pings: pings,
      heard: heard,
      bestSnr: bestSnr,
      medianSnr: bestSnr,
      repeaters: heard > 0 ? 1 : 0,
      lastAt: '2026-10-18T12:00:00Z',
      h3: h3,
      noiseFloor: noiseFloor,
    );

void main() {
  final h3 = _load();
  final skip = h3 == null ? 'libh3 not found (brew install h3)' : false;

  group('levelFor: best SNR (the website\'s own 4-step thresholds)', () {
    test('nothing heard is none, regardless of other fields', () {
      expect(levelFor(_cell(heard: 0, bestSnr: 9), CoverageColorBy.snr), CoverageLevel.none);
    });
    test('heard but no SNR reading is unknown (its own colour), never a strength guess', () {
      expect(levelFor(_cell(heard: 3, bestSnr: null), CoverageColorBy.snr), CoverageLevel.unknown);
    });
    test('boundaries: >=5 strong, [0,5) good, [-5,0) fair, <-5 weak', () {
      expect(levelFor(_cell(bestSnr: 5.0), CoverageColorBy.snr), CoverageLevel.strong);
      expect(levelFor(_cell(bestSnr: 12.0), CoverageColorBy.snr), CoverageLevel.strong);
      expect(levelFor(_cell(bestSnr: 4.9), CoverageColorBy.snr), CoverageLevel.good);
      expect(levelFor(_cell(bestSnr: 0.0), CoverageColorBy.snr), CoverageLevel.good);
      expect(levelFor(_cell(bestSnr: -0.1), CoverageColorBy.snr), CoverageLevel.fair);
      expect(levelFor(_cell(bestSnr: -5.0), CoverageColorBy.snr), CoverageLevel.fair);
      expect(levelFor(_cell(bestSnr: -5.1), CoverageColorBy.snr), CoverageLevel.weak);
      expect(levelFor(_cell(bestSnr: -40.0), CoverageColorBy.snr), CoverageLevel.weak);
    });
  });

  group('levelFor: share heard', () {
    test('no pings is none', () {
      expect(levelFor(_cell(pings: 0, heard: 0), CoverageColorBy.heard), CoverageLevel.none);
    });
    test('boundaries: >=75% strong, [50,75) good, [25,50) fair, <25 weak', () {
      expect(levelFor(_cell(pings: 4, heard: 3), CoverageColorBy.heard), CoverageLevel.strong); // 75%
      expect(levelFor(_cell(pings: 100, heard: 74), CoverageColorBy.heard), CoverageLevel.good);
      expect(levelFor(_cell(pings: 4, heard: 2), CoverageColorBy.heard), CoverageLevel.good); // 50%
      expect(levelFor(_cell(pings: 4, heard: 1), CoverageColorBy.heard), CoverageLevel.fair); // 25%
      expect(levelFor(_cell(pings: 100, heard: 24), CoverageColorBy.heard), CoverageLevel.weak);
      expect(levelFor(_cell(pings: 10, heard: 0), CoverageColorBy.heard), CoverageLevel.none); // nothing heard is grey, not red
    });
  });

  group('levelFor: noise floor', () {
    test('no reading is none', () {
      expect(levelFor(_cell(noiseFloor: null), CoverageColorBy.noise), CoverageLevel.none);
    });
    test('boundaries: <-125 strong (quiet), [-125,-115) good, [-115,-105) fair, >=-105 weak (noisy)', () {
      expect(levelFor(_cell(noiseFloor: -130), CoverageColorBy.noise), CoverageLevel.strong);
      expect(levelFor(_cell(noiseFloor: -125.1), CoverageColorBy.noise), CoverageLevel.strong);
      expect(levelFor(_cell(noiseFloor: -125), CoverageColorBy.noise), CoverageLevel.good);
      expect(levelFor(_cell(noiseFloor: -116), CoverageColorBy.noise), CoverageLevel.good);
      expect(levelFor(_cell(noiseFloor: -115), CoverageColorBy.noise), CoverageLevel.fair);
      expect(levelFor(_cell(noiseFloor: -106), CoverageColorBy.noise), CoverageLevel.fair);
      expect(levelFor(_cell(noiseFloor: -105), CoverageColorBy.noise), CoverageLevel.weak);
      expect(levelFor(_cell(noiseFloor: -60), CoverageColorBy.noise), CoverageLevel.weak);
    });
  });

  group('buildNetworkCells: square grid (no H3 engine needed)', () {
    test('boxes the cell\'s centre +/- half the cell size, bucketed by the chosen dimension', () {
      final coverage = PublicCoverage(
        asOf: '2026-10-18T12:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.01),
        cells: [
          _cell(lat: 40.0, lon: -83.0, bestSnr: 8.0, heard: 5, pings: 5),
          _cell(lat: 40.1, lon: -83.1, bestSnr: -9.0, heard: 1, pings: 5),
        ],
      );
      final cells = buildNetworkCells(coverage, null, CoverageColorBy.snr);
      expect(cells, hasLength(2));
      final a = cells.first;
      expect(a.id, '40.0,-83.0');
      expect(a.level, CoverageLevel.strong);
      expect(a.boundary, hasLength(4));
      expect(a.boundary[0].lat, closeTo(39.995, 1e-9));
      expect(a.boundary[0].lon, closeTo(-83.005, 1e-9));
      expect(a.boundary[2].lat, closeTo(40.005, 1e-9));
      expect(a.boundary[2].lon, closeTo(-82.995, 1e-9));
      expect(cells[1].level, CoverageLevel.weak);
    });

    test('a cell with an unusable position is skipped, not lost for the whole map crashing', () {
      final coverage = PublicCoverage(
        asOf: '2026-10-18T12:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.01),
        cells: [_cell(lat: double.nan, lon: -83.0), _cell(lat: 40.0, lon: 200.0), _cell(lat: 40.0, lon: -83.0)],
      );
      expect(buildNetworkCells(coverage, null, CoverageColorBy.snr), hasLength(1));
    });

    test('no cells, no network cells', () {
      final coverage = PublicCoverage(asOf: '2026-10-18T12:00:00Z', grid: const CoverageGrid.square(cellDeg: 0.01), cells: const []);
      expect(buildNetworkCells(coverage, null, CoverageColorBy.snr), isEmpty);
    });
  });

  group('buildNetworkCells: hexagon grid', () {
    test('boundary matches the website\'s own H3 hexagon; a null engine skips hex cells cleanly', () {
      final coverage = PublicCoverage(
        asOf: '2026-10-18T12:00:00Z',
        grid: const CoverageGrid.h3(res: 9, cellDeg: 0.005),
        cells: [_cell(lat: 39.9612, lon: -82.9988, bestSnr: 7.0, h3: '892a956a94bffff')],
      );
      // No engine: skipped rather than guessed at (same philosophy as a ping with an unusable position).
      expect(buildNetworkCells(coverage, null, CoverageColorBy.snr), isEmpty);

      final cells = buildNetworkCells(coverage, h3, CoverageColorBy.snr);
      expect(cells, hasLength(1), skip: skip);
      if (h3 != null) {
        expect(cells.single.id, '892a956a94bffff');
        expect(cells.single.level, CoverageLevel.strong);
        expect(cells.single.boundary, hasLength(6));
        expect(cells.single.boundary.first.lat, closeTo(39.96321833225654, 1e-9));
        expect(cells.single.boundary.first.lon, closeTo(-82.99754267395762, 1e-9));
      }
    }, skip: skip);

    test('a cell with no h3 id on the hex grid is skipped', () {
      final coverage = PublicCoverage(
        asOf: '2026-10-18T12:00:00Z',
        grid: const CoverageGrid.h3(res: 9, cellDeg: 0.005),
        cells: [_cell(h3: null)],
      );
      expect(buildNetworkCells(coverage, h3, CoverageColorBy.snr), isEmpty);
    }, skip: skip);

    test('an unparsable h3 id is skipped, not thrown', () {
      final coverage = PublicCoverage(
        asOf: '2026-10-18T12:00:00Z',
        grid: const CoverageGrid.h3(res: 9, cellDeg: 0.005),
        cells: [_cell(h3: 'not-hex!')],
      );
      expect(buildNetworkCells(coverage, h3, CoverageColorBy.snr), isEmpty);
    }, skip: skip);
  });
}
