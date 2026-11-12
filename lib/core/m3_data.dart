// What the M3-2 layers draw (Estimated positions, Redundancy, Links by SNR), derived from the same two server answers the
// website reads (meshcore-insights src/lib/map/m3-data.ts and estimated.ts; contract meshsonar-infra
// docs/planning/map-definition-contract.md "Changes"): `GET /api/cmh/region-link-graph` (E5) and
// `GET /api/cmh/region-repeater-estimates`. Pure Dart: the same rules as the web, so the two maps agree.
//
//   Redundancy   = per res-11 cell, the number of DISTINCT located repeaters measured there (the graph's `drive` rows
//                  [repeaterIdx, h3, attempts, snrMean]; a row whose repeater is not a located repeater / room of the graph is not
//                  counted); legend steps 1, 2, 3, 4+. Hidden while a time window / source filter looks at the past.
//   Links by SNR = one line per repeater pair with BOTH ends located; SNR from a measured /neighbors report, else the reported
//                  neighbour table; a pair seen only relaying has no SNR (neutral dashed); width by packets, log scale between the
//                  definition's `symbols.snrLink.widthPx`; band = the coverage band of the SNR over the SF floor of the default preset.
//   Estimates    = positions the SERVER computed (weighted mean of located neighbours + a fixed 120-380 m offset, already applied):
//                  the app draws them as given and never computes or moves one. Paler = less sure (`symbols.estimated.opacity`).
import 'dart:convert';
import 'dart:math' as math;

import 'coverage_v2.dart' show coverageBandOf;
import 'map_definition.dart';

const Set<String> _roles = {'repeater', 'room'};

bool _pos(Object? lat, Object? lon) =>
    lat is num && lon is num && lat.isFinite && lon.isFinite && lat.abs() <= 90 && lon.abs() <= 180 && !(lat == 0 && lon == 0);

/// One node of the E5 graph: `[key, name, role, lat, lon]`.
class GraphNode {
  final String key;
  final String? name;
  final String? role;
  final double? lat, lon;
  const GraphNode(this.key, this.name, this.role, this.lat, this.lon);
  bool get located => _roles.contains(role) && _pos(lat, lon);
}

/// One link row: `[aIdx, bIdx, source, width, snrDb, snrN, rssi, n, feeds, mix, lastAt, km]`.
class GraphLink {
  final int a, b;
  final String source;
  final double? snr;
  final int? n;
  final double? km;
  const GraphLink(this.a, this.b, this.source, this.snr, this.n, this.km);
}

/// A parsed `region-link-graph` answer (only what the two layers read).
class LinkGraph {
  final DateTime? builtAt;
  final List<GraphNode> nodes;
  final List<GraphLink> links;

  /// `[repeaterIdx, h3 (lower-case hex), attempts, snrMean]`.
  final List<({int idx, String h3})> drive;

  /// Measured repeater ids the server could not match to exactly one node (not counted in Redundancy; the layer says so).
  final int driveUnresolved;
  const LinkGraph({this.builtAt, this.nodes = const [], this.links = const [], this.drive = const [], this.driveUnresolved = 0});

  /// Parses a decoded body; null when it is not an object. A malformed row is skipped (the server's graph is trusted for shape, a
  /// bad row never breaks the map).
  static LinkGraph? fromJson(Object? j) {
    if (j is! Map) return null;
    final nodes = <GraphNode>[];
    for (final n in (j['nodes'] as List? ?? const [])) {
      if (n is List && n.isNotEmpty && n[0] is String) {
        nodes.add(GraphNode(
          (n[0] as String).toLowerCase(),
          n.length > 1 && n[1] is String ? n[1] as String : null,
          n.length > 2 && n[2] is String ? n[2] as String : null,
          n.length > 3 && n[3] is num ? (n[3] as num).toDouble() : null,
          n.length > 4 && n[4] is num ? (n[4] as num).toDouble() : null,
        ));
      } else {
        nodes.add(const GraphNode('', null, null, null, null)); // keep the indices aligned
      }
    }
    final links = <GraphLink>[];
    for (final l in (j['links'] as List? ?? const [])) {
      if (l is! List || l.length < 3 || l[0] is! int || l[1] is! int) continue;
      double? num_(int i) => l.length > i && l[i] is num && (l[i] as num).isFinite ? (l[i] as num).toDouble() : null;
      links.add(GraphLink(l[0] as int, l[1] as int, '${l[2]}', num_(4), num_(7)?.toInt(), num_(11)));
    }
    final drive = <({int idx, String h3})>[];
    for (final r in (j['drive'] as List? ?? const [])) {
      if (r is List && r.length >= 2 && r[0] is int && r[1] is String) drive.add((idx: r[0] as int, h3: (r[1] as String).toLowerCase()));
    }
    final bt = j['builtAt'];
    return LinkGraph(
      builtAt: bt is String ? DateTime.tryParse(bt)?.toUtc() : null,
      nodes: nodes,
      links: links,
      drive: drive,
      driveUnresolved: (j['driveUnresolved'] as num?)?.toInt() ?? 0,
    );
  }

  static LinkGraph? parse(String body) {
    try {
      return fromJson(jsonDecode(body));
    } catch (_) {
      return null;
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------- redundancy

class RedundancyCell {
  final String h3;
  final int n;
  const RedundancyCell(this.h3, this.n);

  /// The legend step: 1, 2, 3, 4 (= four or more).
  int get step => redundancyStep(n);
}

class RedundancyResult {
  final List<RedundancyCell> cells;
  final int unresolved;

  /// Cells with exactly one repeater (a single point of failure).
  final int single;
  const RedundancyResult(this.cells, this.unresolved, this.single);
}

final RegExp _h3Id = RegExp(r'^[0-9a-f]{15}$');

/// Distinct located repeaters per res-11 cell.
RedundancyResult redundancyCells(LinkGraph? g) {
  final nodes = g?.nodes ?? const <GraphNode>[];
  final per = <String, Set<int>>{};
  for (final r in g?.drive ?? const <({int idx, String h3})>[]) {
    if (r.idx < 0 || r.idx >= nodes.length || !nodes[r.idx].located || !_h3Id.hasMatch(r.h3)) continue;
    (per[r.h3] ??= <int>{}).add(r.idx);
  }
  final cells = [for (final e in per.entries) RedundancyCell(e.key, e.value.length)]..sort((a, b) => a.h3.compareTo(b.h3));
  return RedundancyResult(cells, g?.driveUnresolved ?? 0, cells.where((c) => c.n == 1).length);
}

/// The legend step (1, 2, 3, 4 = four or more) of a count.
int redundancyStep(int n) => math.min(4, math.max(1, n));

// ---------------------------------------------------------------------------------------------------------------- SNR links

class SnrLink {
  final String aKey, bKey;
  final String? aName, bName;
  final double aLat, aLon, bLat, bLon;

  /// dB, or null when the pair was only seen relaying.
  final double? snr;

  /// 1-5 (the coverage bands: margin over the SF floor), 0 = no SNR.
  final int band;

  /// Packets seen relaying across it (observed), else the reports behind the SNR; at least 1.
  final int packets;

  /// 'measured' | 'reported' | 'observed'.
  final String source;
  final double? km;

  /// Line width in px from the packets (log scale between the definition's min and max).
  final double width;
  const SnrLink({
    required this.aKey,
    required this.bKey,
    this.aName,
    this.bName,
    required this.aLat,
    required this.aLon,
    required this.bLat,
    required this.bLon,
    required this.snr,
    required this.band,
    required this.packets,
    required this.source,
    this.km,
    required this.width,
  });

  String get aLabel => aName ?? aKey.substring(0, math.min(8, aKey.length));
  String get bLabel => bName ?? bKey.substring(0, math.min(8, bKey.length));
}

/// Line width in px from [packets]: log scale between the definition's `symbols.snrLink.widthPx` over `widthAtPackets`.
double linkWidth(int packets, MapDefinition d) {
  final s = d.symbol('snrLink');
  final px = [for (final v in (s['widthPx'] as List? ?? const [1.2, 5])) (v as num).toDouble()];
  final at = [for (final v in (s['widthAtPackets'] as List? ?? const [1, 500])) (v as num).toDouble()];
  final p0 = at[0], p1 = at[1];
  final t = ((math.log(math.max(p0, packets.toDouble()) / p0)) / math.log(p1 / p0)).clamp(0.0, 1.0);
  return ((px[0] + (px[1] - px[0]) * t) * 100).round() / 100;
}

/// One line per located pair of repeaters / rooms. [sf] picks the band edges (the default preset's spreading factor).
List<SnrLink> snrLinks(LinkGraph? g, MapDefinition d, {int sf = 7}) {
  final nodes = g?.nodes ?? const <GraphNode>[];
  final acc = <String, _Acc>{};
  for (final l in g?.links ?? const <GraphLink>[]) {
    if (l.a == l.b || l.a < 0 || l.b < 0 || l.a >= nodes.length || l.b >= nodes.length) continue;
    if (!nodes[l.a].located || !nodes[l.b].located) continue;
    final lo = math.min(l.a, l.b), hi = math.max(l.a, l.b);
    final c = acc.putIfAbsent('$lo:$hi', () => _Acc(lo, hi));
    final n = (l.n ?? 0) > 0 ? l.n! : 1;
    if (l.source == 'measured' && l.snr != null) {
      c.measured = l.snr;
    } else if (l.source == 'reported' && l.snr != null) {
      c.reported = l.snr;
    } else if (l.source == 'observed') {
      c.observed = (c.observed ?? 0) + n;
    }
    c.reports = math.max(c.reports, l.source == 'observed' ? 0 : n);
    if (l.km != null) c.km = l.km;
  }
  final out = <SnrLink>[];
  for (final c in acc.values) {
    final a = nodes[c.a], b = nodes[c.b];
    final snr = c.measured ?? c.reported;
    final packets = math.max(1, c.observed ?? c.reports);
    out.add(SnrLink(
      aKey: a.key,
      bKey: b.key,
      aName: a.name,
      bName: b.name,
      aLat: a.lat!,
      aLon: a.lon!,
      bLat: b.lat!,
      bLon: b.lon!,
      snr: snr,
      band: snr == null ? 0 : coverageBandOf(snrMean: snr, nOk: 1, nSnr: 1, sf: sf),
      packets: packets,
      source: c.measured != null ? 'measured' : (c.reported != null ? 'reported' : 'observed'),
      km: c.km,
      width: linkWidth(packets, d),
    ));
  }
  out.sort((x, y) {
    final p = y.packets.compareTo(x.packets);
    return p != 0 ? p : '${x.aKey}${x.bKey}'.compareTo('${y.aKey}${y.bKey}');
  });
  return out;
}

class _Acc {
  final int a, b;
  double? measured, reported;
  int? observed;
  int reports = 0;
  double? km;
  _Acc(this.a, this.b);
}

/// The hover / tap text of a link: "A to B: 4.5 dB SNR, 120 packets".
String snrLinkText(SnrLink l) {
  final snr = l.snr == null ? 'SNR not measured' : '${l.snr!.toStringAsFixed(1)} dB SNR';
  return '${l.aLabel} to ${l.bLabel}: $snr, ${l.packets} ${l.packets == 1 ? 'packet' : 'packets'}';
}

// ---------------------------------------------------------------------------------------------------------------- estimates

enum EstimateConfidence { high, medium, low }

/// One server-computed position for a repeater / room that has no public position.
class RepeaterEstimate {
  final String key;
  final String? name;
  final String role;
  final double lat, lon;
  final EstimateConfidence confidence;

  /// Located neighbours it was placed from.
  final int anchors;
  final double? spreadKm;
  const RepeaterEstimate({required this.key, this.name, required this.role, required this.lat, required this.lon, required this.confidence, required this.anchors, this.spreadKm});

  /// The marker opacity from the definition's `symbols.estimated.opacity` (paler = less sure); .8 / .6 / .4 when it has none.
  double opacity(MapDefinition d) {
    final o = d.symbol('estimated')['opacity'];
    final v = o is Map ? o[confidence.name] : null;
    return v is num ? v.toDouble() : switch (confidence) { EstimateConfidence.high => 0.8, EstimateConfidence.medium => 0.6, EstimateConfidence.low => 0.4 };
  }

  /// The words under a tap: how sure the position is, from the definition's `symbols.estimated.confidence`.
  String confidenceText(MapDefinition d) {
    final c = d.symbol('estimated')['confidence'];
    final v = c is Map ? c[confidence.name] : null;
    return v is String ? v : switch (confidence) { EstimateConfidence.high => 'Placed from 3 or more neighbours', EstimateConfidence.medium => 'Placed from 2 or more neighbours', EstimateConfidence.low => 'Placed from 1 neighbour, or neighbours far apart' };
  }
}

class EstimatesAnswer {
  final DateTime? builtAt;
  final List<RepeaterEstimate> estimates;
  const EstimatesAnswer(this.builtAt, this.estimates);

  /// Parses `{builtAt, estimates:[{key,name,role,lat,lon,confidence,anchors,spreadKm}], counts}`; null when it is not that. A row
  /// without a usable position or confidence is skipped: nothing is ever guessed.
  static EstimatesAnswer? fromJson(Object? j) {
    if (j is! Map || j['estimates'] is! List) return null;
    final out = <RepeaterEstimate>[];
    for (final e in j['estimates'] as List) {
      if (e is! Map || e['key'] is! String || !_pos(e['lat'], e['lon'])) continue;
      final c = EstimateConfidence.values.where((v) => v.name == e['confidence']).firstOrNull;
      if (c == null) continue;
      out.add(RepeaterEstimate(
        key: (e['key'] as String).toLowerCase(),
        name: e['name'] is String ? e['name'] as String : null,
        role: e['role'] is String ? e['role'] as String : 'repeater',
        lat: (e['lat'] as num).toDouble(),
        lon: (e['lon'] as num).toDouble(),
        confidence: c,
        anchors: (e['anchors'] as num?)?.toInt() ?? 0,
        spreadKm: (e['spreadKm'] as num?)?.toDouble(),
      ));
    }
    final bt = j['builtAt'];
    return EstimatesAnswer(bt is String ? DateTime.tryParse(bt)?.toUtc() : null, out);
  }
}

/// The estimates to draw: a client keeps only those whose repeater still has no position in `region-repeaters` (the roster is
/// newer than the estimate when the node advertised a position since). [positioned] = lower-case keys that have one.
List<RepeaterEstimate> estimatesToDraw(EstimatesAnswer a, Set<String> positioned) => [for (final e in a.estimates) if (!positioned.contains(e.key)) e];
