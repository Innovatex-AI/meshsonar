// Shared, pure-Dart building blocks for "who did we hear": repeater lookup by hex prefix and the live heard
// tracker behind the Drive screen's heard panel and map. No Flutter imports.
//
// RepeaterLookup: resolves an echo's hex key/prefix to a known repeater (name, full key, position) and gives
// distance/bearing from the phone. Built from CMAT's repeater list (drive-repeaters) and, when available,
// public node directories (see RepeaterDirectory in repeater_directory.dart).
//
// HeardTracker: per-drive rolling state, one entry per repeater heard. A repeater is "live" while it was heard
// within the last [holdPings] pings, then "stale" (greyed out) — it never disappears during a drive.
import 'dart:math' as math;

import 'model.dart';

/// Great-circle distance in metres.
double haversineM(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371008.8;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(lat2 - lat1), dLon = rad(lon2 - lon1);
  final a = math.pow(math.sin(dLat / 2), 2) + math.cos(rad(lat1)) * math.cos(rad(lat2)) * math.pow(math.sin(dLon / 2), 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(a)));
}

/// Initial bearing in degrees (0 = north, clockwise).
double bearingDeg(double lat1, double lon1, double lat2, double lon2) {
  double rad(double d) => d * math.pi / 180;
  final y = math.sin(rad(lon2 - lon1)) * math.cos(rad(lat2));
  final x = math.cos(rad(lat1)) * math.sin(rad(lat2)) - math.sin(rad(lat1)) * math.cos(rad(lat2)) * math.cos(rad(lon2 - lon1));
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// "N", "NE", … for a bearing.
String compass(double deg) => const ['N', 'NE', 'E', 'SE', 'S', 'SW', 'W', 'NW'][((deg + 22.5) % 360 ~/ 45)];

/// Where a repeater's identity came from.
enum RepeaterSource { cmat, publicMap, none }

/// Result of looking up an echo's repeater id.
class RepeaterMatch {
  /// The hex key or prefix as heard (lower case).
  final String id;

  /// The single known repeater with that prefix, or null when unknown or ambiguous.
  final RepeaterRef? ref;

  /// Every known repeater whose key starts with [id] (more than one = ambiguous short prefix).
  final List<RepeaterRef> candidates;
  final RepeaterSource source;
  const RepeaterMatch({required this.id, this.ref, this.candidates = const [], this.source = RepeaterSource.none});

  bool get known => ref != null;
  bool get ambiguous => ref == null && candidates.length > 1;

  /// Display name: the repeater's name, else "2 possible" for an ambiguous prefix, else the hex id.
  String get label => ref?.name.isNotEmpty == true ? ref!.name : (ambiguous ? '${id.toUpperCase()} (${candidates.length} possible)' : id.toUpperCase());

  /// Distance in metres from a point, if the repeater's position is known.
  double? distanceFrom(double lat, double lon) => ref == null ? null : haversineM(lat, lon, ref!.lat, ref!.lon);
  double? bearingFrom(double lat, double lon) => ref == null ? null : bearingDeg(lat, lon, ref!.lat, ref!.lon);
}

/// Prefix lookup over one or more repeater lists. Earlier lists win (CMAT before public directories).
class RepeaterLookup {
  final List<(RepeaterSource, List<RepeaterRef>)> _lists;
  final Map<String, RepeaterMatch> _memo = {};
  RepeaterLookup(this._lists);
  static final RepeaterLookup empty = RepeaterLookup(const []);

  int get size => _lists.fold(0, (n, l) => n + l.$2.length);

  RepeaterMatch resolve(String id) {
    final p = id.toLowerCase();
    return _memo.putIfAbsent(p, () {
      for (final (src, list) in _lists) {
        final hits = [for (final r in list) if (r.key.startsWith(p)) r];
        if (hits.length == 1) return RepeaterMatch(id: p, ref: hits.single, candidates: hits, source: src);
        if (hits.length > 1) {
          // Same physical repeater listed twice (same full key) is still one repeater.
          final keys = {for (final h in hits) h.key};
          if (keys.length == 1) return RepeaterMatch(id: p, ref: hits.first, candidates: [hits.first], source: src);
          return RepeaterMatch(id: p, candidates: hits, source: src);
        }
      }
      return RepeaterMatch(id: p);
    });
  }
}

enum HeardState { live, stale }

/// One repeater in the heard panel.
class HeardRepeater {
  final String id; // hex prefix as heard
  final RepeaterMatch match;
  int timesHeard;
  int lastPingIndex; // index (0-based) of the drive's ping in which it was last heard
  DateTime lastHeardAt;
  double? lastSnrDb;
  double? bestSnrDb;
  double? lastRssiDbm;
  int? lastHops;

  /// Distance from the phone when last heard (null when the repeater's position is unknown).
  double? lastDistanceM;
  HeardState state = HeardState.live;
  HeardRepeater({required this.id, required this.match, required this.lastPingIndex, required this.lastHeardAt})
      : timesHeard = 0;
}

/// Rolling "who's in range" state for the current drive.
class HeardTracker {
  int _holdPings;
  RepeaterLookup lookup;
  HeardTracker({int holdPings = 3, RepeaterLookup? lookup})
      : _holdPings = holdPings < 1 ? 1 : holdPings,
        lookup = lookup ?? RepeaterLookup.empty;

  /// Pings a repeater stays "live" after it was last heard. Changing it mid-drive re-applies the rule at once.
  int get holdPings => _holdPings;
  set holdPings(int v) {
    _holdPings = v < 1 ? 1 : v;
    _restate();
  }

  final Map<String, HeardRepeater> _byId = {};
  int _pingIndex = -1;
  int get pingsSeen => _pingIndex + 1;

  void reset() {
    _byId.clear();
    _pingIndex = -1;
  }

  /// Feed every finished ping, in order (tx or rx — a discovery/listen-only drive emits only rx pings, so the live
  /// Heard panel/map needs these too; a normal tx drive never emits rx pings, before or after this, so tx-drive
  /// behaviour is unchanged).
  void addPing(DrivePing ping) {
    _pingIndex++;
    for (final e in ping.echoes) {
      final h = _byId.putIfAbsent(
          e.repeater, () => HeardRepeater(id: e.repeater, match: lookup.resolve(e.repeater), lastPingIndex: _pingIndex, lastHeardAt: ping.ts));
      h.timesHeard++;
      h.lastPingIndex = _pingIndex;
      h.lastHeardAt = ping.ts;
      h.lastSnrDb = e.snrDb;
      h.lastRssiDbm = e.rssiDbm;
      h.lastHops = e.hops;
      if (e.snrDb != null && (h.bestSnrDb == null || e.snrDb! > h.bestSnrDb!)) h.bestSnrDb = e.snrDb;
      h.lastDistanceM = h.match.distanceFrom(ping.lat, ping.lon);
    }
    _restate();
  }

  void _restate() {
    for (final h in _byId.values) {
      h.state = (_pingIndex - h.lastPingIndex) < _holdPings ? HeardState.live : HeardState.stale;
    }
  }

  /// Re-resolve names after the repeater list changes.
  void relookup(RepeaterLookup l) {
    lookup = l;
    for (final k in _byId.keys.toList()) {
      final old = _byId[k]!;
      final h = HeardRepeater(id: old.id, match: l.resolve(old.id), lastPingIndex: old.lastPingIndex, lastHeardAt: old.lastHeardAt)
        ..timesHeard = old.timesHeard
        ..lastSnrDb = old.lastSnrDb
        ..bestSnrDb = old.bestSnrDb
        ..lastRssiDbm = old.lastRssiDbm
        ..lastHops = old.lastHops
        ..lastDistanceM = old.lastDistanceM
        ..state = old.state;
      _byId[k] = h;
    }
  }

  /// Live first (most recently heard first), then stale.
  List<HeardRepeater> get repeaters {
    final l = _byId.values.toList()
      ..sort((a, b) {
        if (a.state != b.state) return a.state == HeardState.live ? -1 : 1;
        final c = b.lastPingIndex.compareTo(a.lastPingIndex);
        return c != 0 ? c : (b.lastSnrDb ?? -99).compareTo(a.lastSnrDb ?? -99);
      });
    return l;
  }

  List<HeardRepeater> get live => repeaters.where((h) => h.state == HeardState.live).toList();
}
