// Link lines: the cell-links answer, re-bucketing a repeater's reach onto the drawn hexagons, placing a cell's repeaters.
// Needs libh3 for the hexagon tests (macOS: `brew install h3`); skipped when it is not there.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:meshsonar/core/hex_cells.dart';
import 'package:meshsonar/core/map_links.dart';
import 'package:meshsonar/core/repeater_reach.dart';

H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

RepeaterReach _reach(List<ReachCell> cells) => RepeaterReach(
  key: 'ab' * 16,
  cellDeg: 0.0025,
  cells: cells,
  totals: const ReachTotals(heardPings: 0, drives: 0, drivers: 0),
  snrByDistance: const [],
);

void main() {
  final h3 = _load();
  final skip = h3 == null ? 'libh3 not found (brew install h3)' : false;

  group('CellLinks.parse', () {
    test('reads rows, lower-cases keys, keeps unknown numbers null', () {
      final l = CellLinks.parse({
        'h3': '892A956A94BFFFF',
        'res': 9,
        'asOf': '2026-10-31T14:00:00Z',
        'links': [
          {'key': 'ABCDEF01', 'pings': 12, 'bestSnr': 6.5, 'medianSnr': 2, 'lastAt': '2026-10-31T13:00:00Z'},
          {'key': 'aa', 'pings': 3, 'bestSnr': null},
          {'key': '', 'pings': 1},
          {'key': 'bb'},
          'junk',
        ],
      });
      expect(l.h3, '892a956a94bffff');
      expect(l.links.map((e) => e.key), ['abcdef01', 'aa']);
      expect(l.links.first.bestSnr, 6.5);
      expect(l.links.first.medianSnr, 2.0);
      expect(l.links.last.bestSnr, isNull);
      expect(l.asOf, DateTime.utc(2026, 10, 31, 14));
    });

    test('rejects a body that is not an answer', () {
      expect(() => CellLinks.parse({'links': []}), throwsFormatException);
      expect(() => CellLinks.parse({'h3': 'x', 'links': 'no'}), throwsFormatException);
    });
  });

  group('cellEnds', () {
    final links = CellLinks(
      h3: 'x',
      links: const [
        CellLink(key: 'a1', pings: 9, bestSnr: 4),
        CellLink(key: 'b2', pings: 5, bestSnr: -3),
        CellLink(key: 'c3', pings: 1),
      ],
    );
    test('places known repeaters, counts the ones without a position', () {
      final r = cellEnds(links, (k) => k == 'b2' ? null : (lat: 40.0, lon: -83.0, name: 'N-$k'));
      expect(r.ends.map((e) => e.id), ['a1', 'c3']);
      expect(r.ends.first.name, 'N-a1');
      expect(r.ends.first.snr, 4);
      expect(r.ends.last.snr, isNull);
      expect(r.unplaced, 1);
    });
  });

  group('reachEnds', () {
    test('two reach cells in one hexagon become one end: pings add, SNR is the best', () {
      final a = hexCellOf(h3!, 39.9612, -82.9988);
      final g = h3.cellToGeo(a);
      final r = reachEnds(
        _reach([
          ReachCell(lat: g.lat, lon: g.lon, pings: 4, bestSnr: -2, medianSnr: -3),
          ReachCell(lat: g.lat + 0.0001, lon: g.lon + 0.0001, pings: 6, bestSnr: 5, medianSnr: 1),
        ]),
        h3,
        9,
      );
      expect(r, hasLength(1));
      expect(r.single.pings, 10);
      expect(r.single.snr, 5);
      expect(r.single.id, hexId(a));
      expect(r.single.lat, closeTo(g.lat, 1e-9));
    });

    test('a finer resolution splits what a coarse one merges', () {
      final c = h3!.cellToGeo(hexCellOf(h3, 39.9612, -82.9988, res: 7)); // a point well inside one resolution-7 hexagon
      final cells = [
        ReachCell(lat: c.lat, lon: c.lon, pings: 1, bestSnr: 1),
        ReachCell(lat: c.lat + 0.002, lon: c.lon, pings: 1, bestSnr: 1),
      ];
      expect(reachEnds(_reach(cells), h3, 7), hasLength(1));
      expect(reachEnds(_reach(cells), h3, 11), hasLength(2));
    });

    test('most pings first; unknown SNR stays null; bad positions are skipped', () {
      final r = reachEnds(
        _reach(const [
          ReachCell(lat: 39.9612, lon: -82.9988, pings: 2),
          ReachCell(lat: 39.9900, lon: -82.9000, pings: 9, bestSnr: 3),
          ReachCell(lat: double.nan, lon: 0, pings: 50),
          ReachCell(lat: 95, lon: 0, pings: 50),
        ]),
        h3!,
        9,
      );
      expect(r.map((e) => e.pings), [9, 2]);
      expect(r.last.snr, isNull);
    });

    test('caps at maxLinkLines', () {
      final cells = [
        for (var i = 0; i < maxLinkLines + 40; i++) ReachCell(lat: 39.0 + i * 0.01, lon: -83.0, pings: i + 1),
      ];
      expect(reachEnds(_reach(cells), h3!, 9), hasLength(maxLinkLines));
    });
  }, skip: skip);

  test('linkSnrLabel', () {
    expect(linkSnrLabel(6.5), '+6.5 dB');
    expect(linkSnrLabel(-3), '-3.0 dB');
    expect(linkSnrLabel(0), '0.0 dB');
    expect(linkSnrLabel(null), isNull);
  });
}
