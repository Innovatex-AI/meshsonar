// Map-tab quick wins, pure logic: base-map styles, the filter drawer's rules, and the coverage % of the view. (The ping-age and
// noise-delta colour modes were removed with the coverage redesign, plan D9.)
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/map_filter.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/network_coverage.dart';

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

NetworkCell ncell(CoverageCell c) => NetworkCell(id: '${c.lat},${c.lon}', boundary: const [], level: levelFor(c), cell: c);

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
      expect(BaseMapStyle.parse('hybrid'), BaseMapStyle.chart, reason: 'an id this build does not know');
      expect(BaseMapStyle.parse(null), BaseMapStyle.chart);
    });
    test('topo and satellite are the ones without an offline pack (the network only); every style credits OpenStreetMap or its imagery', () {
      expect([for (final s in BaseMapStyle.values) if (!s.usesOfflinePack) s], [BaseMapStyle.topo, BaseMapStyle.satellite]);
      expect([for (final s in BaseMapStyle.values) if (s.needsNetwork) s], [BaseMapStyle.topo, BaseMapStyle.satellite]);
      for (final s in BaseMapStyle.values) {
        if (s.isSatellite) {
          expect(s.attribution, isEmpty, reason: 'satellite builds its credit from the definition');
        } else {
          expect(s.attribution, 'Protomaps © OpenStreetMap contributors', reason: s.id);
          expect(s.isVector, isTrue);
        }
      }
    });
    test('looks: chart follows the theme, Light is always light, Dark always dark; nothing is colour-graded any more', () {
      expect(BaseMapStyle.chart.darkLook, isNull);
      expect(BaseMapStyle.street.darkLook, isFalse);
      expect(BaseMapStyle.dark.darkLook, isTrue);
      expect(BaseMapStyle.dark.forcesDark, isTrue);
      expect(BaseMapStyle.chart.forcesDark, isFalse);
      for (final s in BaseMapStyle.values) {
        expect(s.ungraded, isTrue, reason: s.id);
      }
    });
    test('the style is saved in settings only when it is not the default', () {
      expect(const Settings().toJson().containsKey('base_map_style'), isFalse);
      final j = const Settings().copyWith(baseMapStyle: 'topo').toJson();
      expect(j['base_map_style'], 'topo');
      expect(Settings.fromJson(j).baseMapStyle, 'topo');
      expect(Settings.fromJson(const {}).baseMapStyle, 'chart');
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
