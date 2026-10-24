// Map view options and the "who's in range" snapshot the map and the heard box draw from.
//
// HeardView is an immutable copy of one HeardTracker entry, taken once per finished ping (see heardSnapshot), so
// the map and the heard box never walk the tracker during a frame and never rebuild between pings.
import 'package:flutter/foundation.dart';

import '../../core/heard.dart';
import '../../core/model.dart';

/// How ping dots are coloured.
enum PingColorMode {
  /// Heard by a repeater (green) or heard nothing (red): the "did it reach the mesh" view.
  result,

  /// Heard pings by their best SNR (blue → teal → green); heard nothing stays red.
  snr,
}

/// Which layers the map draws. Shared by the Drive screen map and the full-screen map.
@immutable
class MapLayers {
  final bool pings;

  /// The drive's pings rolled up onto the website's H3 hexagons (resolution 9).
  final bool hexes;
  final PingColorMode pingColors;
  final bool repeaters;
  final bool links;
  final bool rings;

  /// Network-wide measured coverage (every driver, not just this one) from `GET /api/cmh/public-coverage`, drawn
  /// underneath everything else as a quiet "where hasn't this been driven" background layer. On by default: it's
  /// basic visibility, meant to be there the first time anyone opens the Drive screen, not a layer you have to
  /// find.
  final bool networkCoverage;

  /// The selected region's whole repeater roster (`region-repeaters`), not just the ones this drive heard. Off by default.
  final bool regionRepeaters;
  const MapLayers({
    this.pings = true,
    this.hexes = true,
    this.pingColors = PingColorMode.snr,
    this.repeaters = true,
    this.links = true,
    this.rings = true,
    this.networkCoverage = true,
    this.regionRepeaters = false,
  });

  MapLayers copyWith({
    bool? pings,
    bool? hexes,
    PingColorMode? pingColors,
    bool? repeaters,
    bool? links,
    bool? rings,
    bool? networkCoverage,
    bool? regionRepeaters,
  }) => MapLayers(
    pings: pings ?? this.pings,
    hexes: hexes ?? this.hexes,
    pingColors: pingColors ?? this.pingColors,
    repeaters: repeaters ?? this.repeaters,
    links: links ?? this.links,
    rings: rings ?? this.rings,
    networkCoverage: networkCoverage ?? this.networkCoverage,
    regionRepeaters: regionRepeaters ?? this.regionRepeaters,
  );

  @override
  bool operator ==(Object other) =>
      other is MapLayers &&
      other.pings == pings &&
      other.hexes == hexes &&
      other.pingColors == pingColors &&
      other.repeaters == repeaters &&
      other.links == links &&
      other.rings == rings &&
      other.networkCoverage == networkCoverage &&
      other.regionRepeaters == regionRepeaters;

  @override
  int get hashCode => Object.hash(pings, hexes, pingColors, repeaters, links, rings, networkCoverage, regionRepeaters);
}

/// Where a heard repeater sits in its hold period.
enum HeardPhase {
  /// Heard on the latest ping.
  fresh,

  /// Not heard on the latest ping but still inside the hold (shown dimmed, with the pings it has left).
  holding,

  /// Not heard for the whole hold: greyed out, summarised as "+N earlier".
  stale,
}

/// One repeater in the heard box / on the map, frozen at the last ping.
@immutable
class HeardView {
  /// Hex id as heard (lower case).
  final String id;
  final String label;

  /// Known repeater (position, full key), or null when unknown/ambiguous.
  final RepeaterRef? ref;
  final double? snrDb;
  final double? bestSnrDb;
  final double? rssiDbm;
  final int timesHeard;

  /// Distance from the phone when last heard, if the repeater's position is known.
  final double? distanceM;
  final HeardPhase phase;

  /// Pings since it was last heard (0 = heard on the latest ping).
  final int pingsAgo;

  /// Pings left before it goes stale (0 when stale).
  final int holdLeft;

  /// Index of the drive's ping it was last heard on: changes each time it's heard again (drives the pop-up).
  final int lastPingIndex;
  const HeardView({
    required this.id,
    required this.label,
    this.ref,
    this.snrDb,
    this.bestSnrDb,
    this.rssiDbm,
    this.timesHeard = 1,
    this.distanceM,
    this.phase = HeardPhase.fresh,
    this.pingsAgo = 0,
    this.holdLeft = 0,
    this.lastPingIndex = 0,
  });

  bool get live => phase != HeardPhase.stale;

  /// Key used for the map marker: the full key when known, else the heard id.
  String get mapKey => ref?.key ?? id;
}

/// Freezes the tracker's current state (live first, most recent first; then stale).
List<HeardView> heardSnapshot(HeardTracker t) {
  final latest = t.pingsSeen - 1;
  return [
    for (final h in t.repeaters)
      HeardView(
        id: h.id,
        label: h.match.label,
        ref: h.match.ref,
        snrDb: h.lastSnrDb,
        bestSnrDb: h.bestSnrDb,
        rssiDbm: h.lastRssiDbm,
        timesHeard: h.timesHeard,
        distanceM: h.lastDistanceM,
        phase: h.state == HeardState.stale
            ? HeardPhase.stale
            : (h.lastPingIndex >= latest ? HeardPhase.fresh : HeardPhase.holding),
        pingsAgo: latest - h.lastPingIndex,
        holdLeft: h.state == HeardState.stale ? 0 : (t.holdPings - (latest - h.lastPingIndex)).clamp(0, t.holdPings),
        lastPingIndex: h.lastPingIndex,
      ),
  ];
}

/// "850 m", "2.3 km", "14 km".
String formatDistance(double m) {
  if (m < 950) return '${(m / 10).round() * 10} m';
  final km = m / 1000;
  return km < 10 ? '${km.toStringAsFixed(1)} km' : '${km.round()} km';
}

/// "+6.5", "-3.0".
String formatSnrShort(double snr) => '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)}';
