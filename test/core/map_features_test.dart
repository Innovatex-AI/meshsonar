// Map-tab quick wins, pure logic: base-map styles, the ping-age and noise-delta coverage modes (and the colour contract
// around them), the filter drawer's rules, and the coverage % of the view.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_filter.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/map/coverage_ramps.dart';
import 'package:meshsonar/ui/theme.dart';

final now = DateTime.utc(2026, 11, 1, 12);

CoverageCell cell({
  double lat = 40.0,
  double lon = -83.0,
  int pings = 10,
  int heard = 5,
  double? bestSnr = 3,
  double? noise,
  Duration age = const Duration(hours: 2),
}) => CoverageCell(
  lat: lat,
  lon: lon,
  pings: pings,
  heard: heard,
  bestSnr: bestSnr,
  medianSnr: bestSnr,
  repeaters: heard > 0 ? 1 : 0,
  lastAt: now.subtract(age).toIso8601String(),
  noiseFloor: noise,
);

DrivePing ping(String id, {List<String> heardBy = const [], Duration age = Duration.zero, double lat = 40.0, double lon = -83.0, PingKind kind = PingKind.tx}) => DrivePing(
  id: id,
  ts: now.subtract(age),
  lat: lat,
  lon: lon,
  kind: kind,
  echoes: [for (final r in heardBy) Echo(repeater: r, snrDb: 2)],
);

NetworkCell ncell(CoverageCell c, [CoverageColorBy by = CoverageColorBy.snr]) =>
    NetworkCell(id: '${c.lat},${c.lon}', boundary: const [], level: levelFor(c, by, now: now), cell: c, mode: by);

void main() {
  group('base map styles', () {
    test('cycle visits every style once and wraps', () {
      var s = BaseMapStyle.chart;
      final seen = <BaseMapStyle>[];
      for (var i = 0; i < BaseMapStyle.values.length; i++) {
        seen.add(s);
        s = s.next;
      }
      expect(seen.toSet(), BaseMapStyle.values.toSet());
      expect(s, BaseMapStyle.chart);
    });
    test('parse: known ids round-trip; unknown or missing is the default chart', () {
      for (final s in BaseMapStyle.values) {
        expect(BaseMapStyle.parse(s.id), s);
      }
      expect(BaseMapStyle.parse('satellite'), BaseMapStyle.chart);
      expect(BaseMapStyle.parse(null), BaseMapStyle.chart);
    });
    test('topo is the only one without an offline pack, and credits OpenTopoMap and OSM', () {
      expect([for (final s in BaseMapStyle.values) if (!s.usesOfflinePack) s], [BaseMapStyle.topo]);
      expect(BaseMapStyle.topo.attribution, allOf(contains('OpenTopoMap'), contains('OpenStreetMap')));
      expect(BaseMapStyle.topo.tileUrl, contains('opentopomap.org'));
      for (final s in BaseMapStyle.values) {
        expect(s.attribution, contains('OpenStreetMap'));
        expect(s.tileUrl, allOf(contains('{z}'), contains('{x}'), contains('{y}')));
      }
    });
    test('grading: chart follows the theme, street and topo are as served, dark is forced', () {
      expect(BaseMapStyle.chart.ungraded, isFalse);
      expect(BaseMapStyle.street.ungraded, isTrue);
      expect(BaseMapStyle.topo.ungraded, isTrue);
      expect(BaseMapStyle.dark.forcesDark, isTrue);
      expect(BaseMapStyle.chart.forcesDark, isFalse);
    });
    test('the style is saved in settings only when it is not the default', () {
      expect(const Settings().toJson().containsKey('base_map_style'), isFalse);
      final j = const Settings().copyWith(baseMapStyle: 'topo').toJson();
      expect(j['base_map_style'], 'topo');
      expect(Settings.fromJson(j).baseMapStyle, 'topo');
      expect(Settings.fromJson(const {}).baseMapStyle, 'chart');
    });
  });

  group('ping age mode', () {
    CoverageLevel lv(Duration age, {int heard = 4}) => levelFor(cell(age: age, heard: heard), CoverageColorBy.age, now: now);
    test('buckets: 24 h, 7 d, 30 d, older', () {
      expect(lv(const Duration(hours: 23)), CoverageLevel.strong);
      expect(lv(const Duration(hours: 24)), CoverageLevel.strong);
      expect(lv(const Duration(hours: 25)), CoverageLevel.good);
      expect(lv(const Duration(days: 7)), CoverageLevel.good);
      expect(lv(const Duration(days: 8)), CoverageLevel.fair);
      expect(lv(const Duration(days: 30)), CoverageLevel.fair);
      expect(lv(const Duration(days: 31)), CoverageLevel.weak);
    });
    test('mapped, nothing heard stays grey however fresh; an undated cell is grey too', () {
      expect(lv(const Duration(hours: 1), heard: 0), CoverageLevel.none);
      final undated = CoverageCell(lat: 1, lon: 1, pings: 5, heard: 3, bestSnr: 1, medianSnr: 1, repeaters: 1, lastAt: 'not a date');
      expect(levelFor(undated, CoverageColorBy.age, now: now), CoverageLevel.none);
    });
    test('never purple: purple means heard-signal-unknown and age has nothing to say about signal', () {
      final noSnr = cell(bestSnr: null, heard: 3);
      expect(levelFor(noSnr, CoverageColorBy.age, now: now), CoverageLevel.strong);
    });
  });

  group('noise vs typical mode', () {
    test('median needs 3 readings; ignores cells without one', () {
      expect(medianNoiseFloor([cell(noise: -110), cell(noise: -112), cell()]), isNull);
      expect(medianNoiseFloor([cell(noise: -110), cell(noise: -112), cell(noise: -90), cell()]), -110);
      expect(medianNoiseFloor([cell(noise: -100), cell(noise: -110), cell(noise: -120), cell(noise: -130)]), -115);
    });
    CoverageLevel lv(double noise, {int heard = 4, double base = -115}) =>
        levelFor(cell(noise: noise, heard: heard), CoverageColorBy.noiseDelta, now: now, noiseBaseline: base);
    test('buckets against the baseline: quieter by 3, within 3, up to 8 noisier, much noisier', () {
      expect(lv(-118), CoverageLevel.strong); // -3
      expect(lv(-117.9), CoverageLevel.good);
      expect(lv(-113), CoverageLevel.good); // +2
      expect(lv(-112), CoverageLevel.fair); // +3
      expect(lv(-108), CoverageLevel.fair); // +7
      expect(lv(-107), CoverageLevel.weak); // +8
    });
    test('no reading, no baseline, or nothing heard is grey', () {
      expect(levelFor(cell(noise: null), CoverageColorBy.noiseDelta, now: now, noiseBaseline: -115), CoverageLevel.none);
      expect(levelFor(cell(noise: -110), CoverageColorBy.noiseDelta, now: now), CoverageLevel.none);
      expect(lv(-110, heard: 0), CoverageLevel.none);
    });
    test('buildNetworkCells computes the baseline from the answer and stamps the mode on every cell', () {
      final cov = PublicCoverage(
        asOf: '2026-11-01T12:00:00Z',
        grid: const CoverageGrid.square(cellDeg: 0.01),
        cells: [
          cell(lat: 40.00, noise: -120),
          cell(lat: 40.01, noise: -115),
          cell(lat: 40.02, noise: -110),
          cell(lat: 40.03, noise: -100),
        ],
      );
      final cells = buildNetworkCells(cov, null, CoverageColorBy.noiseDelta, now: now);
      expect(cells.map((c) => c.mode).toSet(), {CoverageColorBy.noiseDelta});
      // median is -112.5: -120 is 7.5 quieter, -100 is 12.5 noisier.
      expect(cells.first.level, CoverageLevel.strong);
      expect(cells.last.level, CoverageLevel.weak);
    });
  });

  group('colour contract', () {
    test('strength modes are flagged as strength; age and noise-vs-typical are not', () {
      expect({for (final m in CoverageColorBy.values) if (m.isStrength) m}, {CoverageColorBy.snr, CoverageColorBy.heard, CoverageColorBy.noise});
    });
    test('ramps never reuse a strength step, and grey and purple come from the palette in every mode', () {
      for (final b in Brightness.values) {
        for (final p in ColourPalette.values) {
          final mc = MeshSonarColors.forPalette(p, b);
          final strength = {mc.levelStrong, mc.levelGood, mc.levelFair, mc.levelWeak, mc.silent, mc.heardUnknown};
          for (final mode in [CoverageColorBy.age, CoverageColorBy.noiseDelta]) {
            for (final l in [CoverageLevel.strong, CoverageLevel.good, CoverageLevel.fair, CoverageLevel.weak]) {
              final c = rampColor(mode, l, b)!;
              expect(strength.contains(c), isFalse, reason: '$mode $l in $b collides with a strength colour');
            }
            expect(rampColor(mode, CoverageLevel.none, b), isNull);
            expect(rampColor(mode, CoverageLevel.unknown, b), isNull);
          }
        }
      }
      expect(rampColor(CoverageColorBy.snr, CoverageLevel.strong, Brightness.light), isNull);
    });
    test('the age ramp is monotone in lightness (newest strongest), so it reads as one sequence', () {
      for (final b in Brightness.values) {
        final l = [for (final lv in [CoverageLevel.strong, CoverageLevel.good, CoverageLevel.fair, CoverageLevel.weak]) HSLColor.fromColor(rampColor(CoverageColorBy.age, lv, b)!).lightness];
        final increasing = b == Brightness.light;
        for (var i = 1; i < l.length; i++) {
          expect(increasing ? l[i] > l[i - 1] : l[i] < l[i - 1], isTrue, reason: '$b $l');
        }
      }
    });
  });

  group('filter drawer', () {
    final all = [
      ping('heard-new', heardBy: ['a1b2'], age: const Duration(hours: 1)),
      ping('heard-old', heardBy: ['c3d4'], age: const Duration(days: 20)),
      ping('silent-new', age: const Duration(hours: 2)),
      ping('silent-old', age: const Duration(days: 40)),
    ];
    List<String> ids(MapFilter f) => [for (final p in f.pings(all, now)) p.id];

    test('no filter returns the same list (no copy)', () {
      expect(identical(MapFilter.none.pings(all, now), all), isTrue);
      expect(MapFilter.none.isNone, isTrue);
      expect(MapFilter.none.activeCount, 0);
    });
    test('heard / not heard', () {
      expect(ids(const MapFilter(heard: HeardFilter.heard)), ['heard-new', 'heard-old']);
      expect(ids(const MapFilter(heard: HeardFilter.notHeard)), ['silent-new', 'silent-old']);
    });
    test('age', () {
      expect(ids(const MapFilter(age: AgeFilter.day)), ['heard-new', 'silent-new']);
      expect(ids(const MapFilter(age: AgeFilter.month)), ['heard-new', 'heard-old', 'silent-new']);
    });
    test('repeater matches by hex prefix either way, any case', () {
      expect(ids(const MapFilter(repeater: 'A1')), ['heard-new']);
      expect(ids(const MapFilter(repeater: 'c3d4e5f6')), ['heard-old']);
      expect(ids(const MapFilter(repeater: 'ff')), isEmpty);
      expect(repeaterIdsMatch('', 'a1'), isFalse);
    });
    test('filters combine; activeCount counts each that narrows', () {
      const f = MapFilter(heard: HeardFilter.heard, age: AgeFilter.week);
      expect(ids(f), ['heard-new']);
      expect(f.activeCount, 2);
      expect(f.copyWith(ownOnly: true).activeCount, 3);
      expect(f.copyWith(heard: HeardFilter.any).activeCount, 1);
    });
    test('cells: heard and age use the cell; own-only and a repeater hide them (they carry no repeater list)', () {
      final cells = [
        ncell(cell(heard: 4, age: const Duration(hours: 3))),
        ncell(cell(lat: 41, heard: 0, age: const Duration(hours: 3))),
        ncell(cell(lat: 42, heard: 4, age: const Duration(days: 45))),
      ];
      List<double> lats(MapFilter f) => [for (final n in f.cells(cells, now)) n.cell!.lat];
      expect(lats(MapFilter.none), [40, 41, 42]);
      expect(lats(const MapFilter(heard: HeardFilter.heard)), [40, 42]);
      expect(lats(const MapFilter(heard: HeardFilter.notHeard)), [41]);
      expect(lats(const MapFilter(age: AgeFilter.week)), [40, 41]);
      expect(lats(const MapFilter(ownOnly: true)), isEmpty);
      expect(lats(const MapFilter(repeater: 'a1')), isEmpty);
    });
    test('equality and hash follow the four fields', () {
      expect(const MapFilter(heard: HeardFilter.heard) == const MapFilter(heard: HeardFilter.heard), isTrue);
      expect(const MapFilter(heard: HeardFilter.heard) == const MapFilter(), isFalse);
      expect(const MapFilter(repeater: 'a').hashCode, const MapFilter(repeater: 'a').hashCode);
    });
  });

  group('coverage % of the view', () {
    final cells = [
      ncell(cell(lat: 40.0, lon: -83.0, heard: 4)),
      ncell(cell(lat: 40.1, lon: -83.0, heard: 0)),
      ncell(cell(lat: 40.2, lon: -83.0, heard: 2)),
      ncell(cell(lat: 45.0, lon: -83.0, heard: 9)), // far outside
    ];
    final pings = [
      ping('a', heardBy: ['aa'], lat: 40.0),
      ping('b', lat: 40.1),
      ping('c', heardBy: ['aa'], lat: 40.2),
      ping('d', lat: 40.3),
      ping('rx', kind: PingKind.rx, lat: 40.0, heardBy: ['aa']),
    ];
    test('no bounds counts everything loaded (the region view)', () {
      final s = summariseCoverage(cells: cells, pings: pings);
      expect((s.cells, s.cellsHeard, s.cellPercent), (4, 3, 75));
      expect((s.pings, s.pingsHeard, s.pingPercent), (4, 2, 50)); // the rx sighting is not a ping that reached the mesh
    });
    test('bounds count only what is inside', () {
      final s = summariseCoverage(cells: cells, pings: pings, bounds: const GeoBounds(39.9, -83.5, 40.25, -82.5));
      expect((s.cells, s.cellsHeard, s.cellPercent), (3, 2, 67));
      expect((s.pings, s.pingsHeard), (3, 2));
    });
    test('nothing in view is empty, with no percent (never 0% of nothing)', () {
      final s = summariseCoverage(cells: cells, pings: pings, bounds: const GeoBounds(0, 0, 1, 1));
      expect(s.isEmpty, isTrue);
      expect(s.cellPercent, isNull);
      expect(s.pingPercent, isNull);
    });
    test('cells whose detail is unknown (no cell data) are skipped, not counted as heard', () {
      const bare = NetworkCell(id: 'x', boundary: [], level: CoverageLevel.none);
      expect(summariseCoverage(cells: [bare], pings: const []).cells, 0);
    });
  });
}
