// Link lines on the map: tap a repeater and a line runs to every cell it was heard in; tap a cell and a line runs to
// every repeater heard there, each labelled with its signal (best SNR). Pure Dart over an injected [H3]; no Flutter.
//
// Repeater -> cells comes from `repeater-reach` (0.0025 degree cells) re-bucketed onto the hexagons currently drawn, so
// a line always ends at the centre of a cell the person can see. Cell -> repeaters comes from `cell-links`
// (`capabilities.cellLinks`). Both answers come from the visible pings of PUBLIC drives only (the server applies each
// drive's start/end trim and privacy zones), so nothing here reveals a private position.
import 'package:h3_flutter/h3_flutter.dart';

import 'hex_cells.dart' show hexCellOf, hexId;
import 'repeater_reach.dart';

num? _num(Object? v) => v is num && v.isFinite ? v : null;

/// One repeater heard in the cell asked about.
class CellLink {
  /// Full repeater key, lower-case hex.
  final String key;
  final int pings;
  final double? bestSnr, medianSnr;
  final DateTime? lastAt;
  const CellLink({required this.key, required this.pings, this.bestSnr, this.medianSnr, this.lastAt});
}

/// The server's answer to `GET cell-links?h3=<id>`.
class CellLinks {
  final String h3;
  final List<CellLink> links;
  final DateTime? asOf;
  const CellLinks({required this.h3, required this.links, this.asOf});

  /// Throws [FormatException] when the body is not a cell-links answer. A bad row is skipped, an unknown number is null.
  static CellLinks parse(Map<String, dynamic> j) {
    final id = j['h3'], raw = j['links'];
    if (id is! String || raw is! List) throw const FormatException('not a cell-links answer');
    final links = <CellLink>[
      for (final r in raw)
        if (r is Map && r['key'] is String && (r['key'] as String).isNotEmpty && _num(r['pings']) != null)
          CellLink(
            key: (r['key'] as String).toLowerCase(),
            pings: _num(r['pings'])!.round(),
            bestSnr: _num(r['bestSnr'])?.toDouble(),
            medianSnr: _num(r['medianSnr'])?.toDouble(),
            lastAt: r['lastAt'] is String ? DateTime.tryParse(r['lastAt'] as String)?.toUtc() : null,
          ),
    ];
    final asOf = j['asOf'];
    return CellLinks(
      h3: id.toLowerCase(),
      links: links,
      asOf: asOf is String ? DateTime.tryParse(asOf)?.toUtc() : null,
    );
  }
}

/// The far end of one line.
class LinkEnd {
  final double lat, lon;

  /// Cell hex id or repeater key, for tests and tap handling.
  final String id;

  /// Repeater name, when the end is a repeater.
  final String? name;
  final int pings;

  /// Best SNR heard on this link (dB); null = unknown (never drawn as 0).
  final double? snr;
  const LinkEnd({required this.lat, required this.lon, required this.id, this.name, required this.pings, this.snr});
}

/// What is drawn: a start point and its ends.
class LinkSet {
  /// `repeater:<key>` or `cell:<id>`; tapping the same thing again clears the lines.
  final String id;
  final double lat, lon;
  final String title;
  final List<LinkEnd> ends;

  /// Links the answer had but that could not be drawn (a repeater whose position is not known).
  final int unplaced;
  const LinkSet({
    required this.id,
    required this.lat,
    required this.lon,
    required this.title,
    required this.ends,
    this.unplaced = 0,
  });
}

/// Most lines drawn at once; the strongest-evidence ones (most pings) win. Keeps a 3,000-cell repeater readable and fast.
const int maxLinkLines = 250;

/// Labels are drawn only up to this many lines, strongest first, so a crowded map stays legible.
const int maxLinkLabels = 24;

/// Rolls a repeater's reach cells up onto the hexagons drawn at [res], one end per hexagon (centre of the hexagon).
/// Pings add up, SNR is the best of the merged cells. Most pings first, capped at [maxLinkLines].
List<LinkEnd> reachEnds(RepeaterReach reach, H3 h3, int res) {
  final pings = <BigInt, int>{};
  final best = <BigInt, double>{};
  for (final c in reach.cells) {
    if (!c.lat.isFinite || !c.lon.isFinite || c.lat.abs() > 90 || c.lon.abs() > 180) continue;
    final BigInt cell;
    try {
      cell = hexCellOf(h3, c.lat, c.lon, res: res);
    } catch (_) {
      continue;
    }
    pings[cell] = (pings[cell] ?? 0) + c.pings;
    final s = c.bestSnr;
    if (s != null && (best[cell] == null || s > best[cell]!)) best[cell] = s;
  }
  final ends = <LinkEnd>[];
  for (final e in pings.entries) {
    try {
      final g = h3.cellToGeo(e.key);
      ends.add(LinkEnd(lat: g.lat, lon: g.lon, id: hexId(e.key), pings: e.value, snr: best[e.key]));
    } catch (_) {}
  }
  ends.sort((a, b) {
    final c = b.pings.compareTo(a.pings);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
  return ends.length > maxLinkLines ? ends.sublist(0, maxLinkLines) : ends;
}

/// Ends for a cell's repeaters. [place] gives a repeater's position and name (null = not on the map). Links without
/// a position are counted, not guessed.
({List<LinkEnd> ends, int unplaced}) cellEnds(
  CellLinks links,
  ({double lat, double lon, String name})? Function(String key) place,
) {
  final ends = <LinkEnd>[];
  var unplaced = 0;
  for (final l in links.links) {
    final p = place(l.key);
    if (p == null) {
      unplaced++;
      continue;
    }
    ends.add(LinkEnd(lat: p.lat, lon: p.lon, id: l.key, name: p.name, pings: l.pings, snr: l.bestSnr));
  }
  return (ends: ends.length > maxLinkLines ? ends.sublist(0, maxLinkLines) : ends, unplaced: unplaced);
}

/// "+6.5 dB" / "-3.0 dB"; null SNR has no label.
String? linkSnrLabel(double? snr) => snr == null ? null : '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)} dB';
