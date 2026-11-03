// The Pings colour mode and the "who's in range" snapshot the map and the heard box draw from.
//
// HeardView is an immutable copy of one HeardTracker entry, taken once per finished ping (see heardSnapshot), so
// the map and the heard box never walk the tracker during a frame and never rebuild between pings.
import 'package:flutter/foundation.dart';

import '../../core/heard.dart';
import '../../core/model.dart';
import 'layers/map_layer.dart';

/// How ping dots are coloured.
enum PingColorMode {
  /// Heard by a repeater (green) or heard nothing (grey): the "did it reach the mesh" view.
  result,

  /// Heard pings by their best SNR (blue → teal → green); heard nothing stays grey.
  snr,
}

/// How the Pings and Your-coverage layers colour in [s] (the `pings` mode: `snr`, the default, or `result`).
PingColorMode pingColorModeOf(MapLayerState s) => s.modeOf('pings') == 'result' ? PingColorMode.result : PingColorMode.snr;

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

/// "+6.5", "-3.0".
String formatSnrShort(double snr) => '${snr > 0 ? '+' : ''}${snr.toStringAsFixed(1)}';
