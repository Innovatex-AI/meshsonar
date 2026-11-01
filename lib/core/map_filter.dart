// The Map tab's filter drawer and the "coverage % of what you can see" figure. Pure Dart, no Flutter.
//
// A filter narrows what is DRAWN; it never deletes or changes data. Rules (written in the drawer too):
//  - Heard / not heard: your pings by whether any repeater heard them; network cells by whether anything was heard there.
//  - Age: your pings by their time, network cells by the time of their newest measurement.
//  - Repeater: only your pings that this repeater heard. Network cells carry no repeater list, so they are hidden while a
//    repeater is picked (showing them unfiltered would say something untrue).
//  - Own pings only: hides the network-wide cells; what is left is what this phone recorded.
import 'api.dart' show CoverageCell;
import 'model.dart';
import 'network_coverage.dart';

enum HeardFilter { any, heard, notHeard }

/// How far back to look; [days] null = no limit.
enum AgeFilter {
  any(null, 'Any age'),
  day(1, '24 hours'),
  week(7, '7 days'),
  month(30, '30 days');

  final int? days;
  final String label;
  const AgeFilter(this.days, this.label);
}

class MapFilter {
  final HeardFilter heard;
  final AgeFilter age;

  /// Repeater id (lower-case hex prefix or full key) whose hearings to show; null = any.
  final String? repeater;
  final bool ownOnly;
  const MapFilter({this.heard = HeardFilter.any, this.age = AgeFilter.any, this.repeater, this.ownOnly = false});

  static const MapFilter none = MapFilter();

  bool get isNone => heard == HeardFilter.any && age == AgeFilter.any && repeater == null && !ownOnly;

  /// How many of the four filters are narrowing the map (the badge on the filter button).
  int get activeCount =>
      (heard != HeardFilter.any ? 1 : 0) + (age != AgeFilter.any ? 1 : 0) + (repeater != null ? 1 : 0) + (ownOnly ? 1 : 0);

  MapFilter copyWith({HeardFilter? heard, AgeFilter? age, String? repeater, bool clearRepeater = false, bool? ownOnly}) => MapFilter(
    heard: heard ?? this.heard,
    age: age ?? this.age,
    repeater: clearRepeater ? null : (repeater ?? this.repeater),
    ownOnly: ownOnly ?? this.ownOnly,
  );

  @override
  bool operator ==(Object other) =>
      other is MapFilter && other.heard == heard && other.age == age && other.repeater == repeater && other.ownOnly == ownOnly;
  @override
  int get hashCode => Object.hash(heard, age, repeater, ownOnly);

  /// Whether [p] passes. [now] is the clock for the age rule.
  bool allowsPing(DrivePing p, DateTime now) {
    if (isNone) return true;
    switch (heard) {
      case HeardFilter.any:
        break;
      case HeardFilter.heard:
        if (p.heardNothing) return false;
      case HeardFilter.notHeard:
        if (!p.heardNothing) return false;
    }
    final d = age.days;
    if (d != null && now.difference(p.ts) > Duration(days: d)) return false;
    final r = repeater;
    if (r != null && !p.echoes.any((e) => repeaterIdsMatch(e.repeater, r))) return false;
    return true;
  }

  /// Whether the network cell [c] passes (see the header for the repeater and own-only rules).
  bool allowsCell(CoverageCell c, DateTime now) {
    if (isNone) return true;
    if (ownOnly || repeater != null) return false;
    switch (heard) {
      case HeardFilter.any:
        break;
      case HeardFilter.heard:
        if (c.heard <= 0) return false;
      case HeardFilter.notHeard:
        if (c.heard > 0) return false;
    }
    final d = age.days;
    if (d != null) {
      final at = DateTime.tryParse(c.lastAt);
      if (at == null || now.difference(at) > Duration(days: d)) return false;
    }
    return true;
  }

  List<DrivePing> pings(List<DrivePing> all, DateTime now) => isNone ? all : [for (final p in all) if (allowsPing(p, now)) p];

  List<NetworkCell> cells(List<NetworkCell> all, DateTime now) =>
      isNone ? all : [for (final n in all) if (n.cell == null || allowsCell(n.cell!, now)) n];
}

/// Two hex repeater ids name the same repeater when one is a prefix of the other (whole-byte prefixes, any case).
bool repeaterIdsMatch(String a, String b) {
  final x = a.toLowerCase(), y = b.toLowerCase();
  if (x.isEmpty || y.isEmpty) return false;
  return x.startsWith(y) || y.startsWith(x);
}

/// A lat/lon box (no antimeridian wrap: the map's view of one region).
class GeoBounds {
  final double south, west, north, east;
  const GeoBounds(this.south, this.west, this.north, this.east);
  bool contains(double lat, double lon) => lat >= south && lat <= north && lon >= west && lon <= east;
  @override
  bool operator ==(Object other) => other is GeoBounds && other.south == south && other.west == west && other.north == north && other.east == east;
  @override
  int get hashCode => Object.hash(south, west, north, east);
}

/// How much of the drawn map was heard. Cells are the network's measured grid cells; pings are this phone's tx pings.
class CoverageSummary {
  final int cells;
  final int cellsHeard;
  final int pings;
  final int pingsHeard;
  const CoverageSummary({this.cells = 0, this.cellsHeard = 0, this.pings = 0, this.pingsHeard = 0});

  bool get isEmpty => cells == 0 && pings == 0;

  /// Whole percent of mapped cells where something was heard; null with no cells.
  int? get cellPercent => cells == 0 ? null : (100 * cellsHeard / cells).round();
  int? get pingPercent => pings == 0 ? null : (100 * pingsHeard / pings).round();

  @override
  bool operator ==(Object other) =>
      other is CoverageSummary && other.cells == cells && other.cellsHeard == cellsHeard && other.pings == pings && other.pingsHeard == pingsHeard;
  @override
  int get hashCode => Object.hash(cells, cellsHeard, pings, pingsHeard);
}

/// Coverage of what is drawn: [cells] and [pings] (already filtered) inside [bounds] (null = all of them, the region view).
/// Only cells and tx pings count: a listen-only (rx) sighting says nothing about whether a ping reached the mesh.
CoverageSummary summariseCoverage({required List<NetworkCell> cells, required List<DrivePing> pings, GeoBounds? bounds}) {
  var c = 0, ch = 0, p = 0, ph = 0;
  for (final n in cells) {
    final cell = n.cell;
    if (cell == null || (bounds != null && !bounds.contains(cell.lat, cell.lon))) continue;
    c++;
    if (cell.heard > 0) ch++;
  }
  for (final x in pings) {
    if (x.kind != PingKind.tx || (bounds != null && !bounds.contains(x.lat, x.lon))) continue;
    p++;
    if (!x.heardNothing) ph++;
  }
  return CoverageSummary(cells: c, cellsHeard: ch, pings: p, pingsHeard: ph);
}
