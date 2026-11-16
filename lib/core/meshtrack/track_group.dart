// MeshTrack groups (meshtrack plan sections 3, 5.1, 6): which channels may be a group, and what one group knows about
// the friends heard on it (positions, short trails, staleness, the jump and spoof rules, the meet-up pin).
//
// Spoof/garbage rules (anyone with the key can send as any name; a channel frame carries only the name prefix):
//   friend identity = sender name within the group; more than one position per 5 s from a name: extra dropped;
//   at most 32 names (oldest heard dropped); a jump implying more than 300 km/h is shown but draws no trail segment
//   and flags "position jumped"; duplicate receipt (same name, sender time, body) dropped with a 256-entry LRU.
// Time: last heard = receive time; for backlog from the radio's offline queue the sender time when plausible (not in
// the future, within 24 h). Staleness: fresh < 5 min, faded 5-15 min, grey 15 min-2 h, list only 2-24 h, gone after.
//
// Pure Dart: no Flutter imports (lib/core layering rule). Trails live in memory only.
import 'dart:collection';

import '../../chat/channel_secret.dart' show classifyChannel, hashtagSecret16;
import '../../chat/models.dart' show Channel, ChannelKind;
import '../privacy_zones.dart' show distanceM;
import 'interop.dart' show MtSource;

/// Most names tracked per group.
const int kMtMaxNames = 32;

/// Duplicate-receipt memory per group.
const int kMtDedupeEntries = 256;

/// One position per name per this long; extras are dropped.
const Duration kMtPerNameMinGap = Duration(seconds: 5);

/// A jump faster than this draws no trail segment.
const double kMtJumpKmh = 300;

/// Trail: last 30 min, at most 20 points.
const Duration kMtTrailAge = Duration(minutes: 30);
const int kMtTrailPoints = 20;

/// Staleness bands.
const Duration kMtFreshFor = Duration(minutes: 5);
const Duration kMtFadedFor = Duration(minutes: 15);
const Duration kMtOnMapFor = Duration(hours: 2);
const Duration kMtOnListFor = Duration(hours: 24);

/// A sender time this far ahead of the receive time still counts as "not in the future" (clock jitter).
const Duration kMtFutureSlack = Duration(seconds: 30);

/// How a friend's pin looks: full colour, faded with "last heard", grey, or list only ("not on the map").
enum MtStaleness { fresh, faded, grey, listOnly }

/// Staleness of something last heard at [lastHeard]; [stopped] (they sent `MT1 x`) greys it at once.
MtStaleness mtStaleness(DateTime lastHeard, DateTime now, {bool stopped = false}) {
  final age = now.difference(lastHeard);
  if (age >= kMtOnMapFor) return MtStaleness.listOnly;
  if (stopped || age >= kMtFadedFor) return MtStaleness.grey;
  if (age >= kMtFreshFor) return MtStaleness.faded;
  return MtStaleness.fresh;
}

/// The time a received message counts as heard: the sender's time for plausible backlog (not in the future, within
/// 24 h of receipt), else the receive time.
DateTime mtEffectiveTime(DateTime? senderTs, DateTime receivedAt) {
  if (senderTs == null) return receivedAt;
  if (senderTs.isAfter(receivedAt.add(kMtFutureSlack))) return receivedAt;
  if (receivedAt.difference(senderTs) > kMtOnListFor) return receivedAt;
  return senderTs.isAfter(receivedAt) ? receivedAt : senderTs;
}

/// Which channels may be a MeshTrack group (plan 5.1): private channels only. Never Public, never a `#` channel (its
/// key is derivable from the name, and our observer treats `#` traffic as public), never the wardrive/system channel.
abstract final class MeshTrackGroup {
  /// [wardriveChannelName]: the drive's ping channel name from settings (refused even if it is not marked system yet).
  /// [secret]: the channel key when known; refused if it is the Public key or derivable from the name.
  static bool eligible(Channel c, {String? wardriveChannelName, List<int>? secret}) {
    if (c.kind != ChannelKind.private) return false;
    if (c.slot == 0) return false;
    final name = c.name.trim();
    if (name.isEmpty || name.startsWith('#')) return false;
    if (name.toLowerCase() == 'public') return false;
    final w = wardriveChannelName?.trim().toLowerCase();
    if (w != null && w.isNotEmpty && (name.toLowerCase() == w || '#${name.toLowerCase()}' == w)) return false;
    if (secret != null) {
      if (secret.length < 16) return false;
      if (classifyChannel(name, secret) != ChannelKind.private) return false;
      final derived = hashtagSecret16(name);
      var same = true;
      for (var i = 0; i < 16; i++) {
        if (secret[i] != derived[i]) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    return true;
  }
}

/// One point of a friend's trail. [breakBefore]: no line from the previous point (a jump).
class MtTrailPoint {
  final double lat;
  final double lon;
  final DateTime at;
  final bool breakBefore;
  const MtTrailPoint(this.lat, this.lon, this.at, {this.breakBefore = false});
}

/// The meet-up pin of a group.
class MtMeetPin {
  final double lat;
  final double lon;
  final String? label;

  /// Name of who set it (our own name when we did).
  final String? setBy;
  final DateTime at;
  const MtMeetPin({required this.lat, required this.lon, required this.at, this.label, this.setBy});

  Map<String, Object?> toJson() =>
      {'lat': lat, 'lon': lon, 'label': label, 'setBy': setBy, 'at': at.toUtc().toIso8601String()};
  static MtMeetPin? fromJson(Object? j) {
    if (j is! Map) return null;
    final lat = j['lat'], lon = j['lon'], at = DateTime.tryParse('${j['at']}');
    if (lat is! num || lon is! num || at == null) return null;
    return MtMeetPin(
        lat: lat.toDouble(), lon: lon.toDouble(), at: at, label: j['label'] as String?, setBy: j['setBy'] as String?);
  }
}

/// A friend as the UI shows them (snapshot).
class MtFriend {
  final String name;
  final double lat;
  final double lon;

  /// Uncertainty, metres (half the Plus Code area for MT1).
  final double accuracyM;
  final int? speedKmh;
  final int? courseDeg;
  final DateTime lastHeard;
  final MtStaleness staleness;

  /// The last position implied more than 300 km/h: shown, but the row says "position jumped" (no trail segment).
  final bool jumped;

  /// Sent `s0`: parked.
  final bool parked;

  /// Sent `MT1 x`: stopped sharing.
  final bool stopped;
  final MtSource source;
  final double? snr;

  /// 0 = direct, N = via N repeaters; null when unknown.
  final int? pathLen;
  final List<MtTrailPoint> trail;
  const MtFriend({
    required this.name,
    required this.lat,
    required this.lon,
    required this.accuracyM,
    required this.lastHeard,
    required this.staleness,
    this.speedKmh,
    this.courseDeg,
    this.jumped = false,
    this.parked = false,
    this.stopped = false,
    this.source = MtSource.meshTrack,
    this.snr,
    this.pathLen,
    this.trail = const [],
  });

  /// Typed by a person (Plus Code, lat/lon or geo:), shown as "typed".
  bool get typed => source == MtSource.typed;

  /// Pin on the map (less than 2 h old); else list only ("not on the map").
  bool get onMap => staleness != MtStaleness.listOnly;
}

/// Outcome of [TrackGroup.addPosition].
enum MtAccept { accepted, rateLimited, older, tooOld }

class _Friend {
  final String name;
  double lat, lon, accuracyM;
  int? speedKmh, courseDeg;
  DateTime lastHeard;
  bool jumped = false, parked = false, stopped = false;
  MtSource source;
  double? snr;
  int? pathLen;
  final List<MtTrailPoint> trail = [];
  _Friend(this.name, this.lat, this.lon, this.accuracyM, this.lastHeard, this.source);
}

/// What one group knows about its friends. Mutable; [friends] gives snapshots.
class TrackGroup {
  final int channelId;
  final Map<String, _Friend> _friends = {};
  final LinkedHashMap<String, bool> _seen = LinkedHashMap();
  MtMeetPin? meet;
  TrackGroup(this.channelId);

  int get nameCount => _friends.length;

  /// True when (name, sender time, body) was already received (and remembers it otherwise). 256-entry LRU.
  bool isDuplicate(String name, DateTime? senderTs, String body) {
    final k = '$name\u0000${senderTs?.millisecondsSinceEpoch}\u0000$body';
    if (_seen.containsKey(k)) {
      _seen.remove(k);
      _seen[k] = true;
      return true;
    }
    _seen[k] = true;
    if (_seen.length > kMtDedupeEntries) _seen.remove(_seen.keys.first);
    return false;
  }

  /// Adds a position heard at [at] (effective time, see [mtEffectiveTime]) from [name].
  MtAccept addPosition({
    required String name,
    required double lat,
    required double lon,
    required double accuracyM,
    required DateTime at,
    required DateTime now,
    int? speedKmh,
    int? courseDeg,
    bool parked = false,
    MtSource source = MtSource.meshTrack,
    double? snr,
    int? pathLen,
  }) {
    if (now.difference(at) > kMtOnListFor) return MtAccept.tooOld;
    var f = _friends[name];
    if (f != null) {
      if (at.isBefore(f.lastHeard)) return MtAccept.older;
      if (at.difference(f.lastHeard) < kMtPerNameMinGap && !f.stopped) return MtAccept.rateLimited;
    }
    var jumped = false;
    if (f == null) {
      if (_friends.length >= kMtMaxNames) {
        final oldest = _friends.values.reduce((a, b) => a.lastHeard.isBefore(b.lastHeard) ? a : b);
        _friends.remove(oldest.name);
      }
      f = _Friend(name, lat, lon, accuracyM, at, source);
      _friends[name] = f;
    } else {
      final dt = at.difference(f.lastHeard).inMilliseconds / 1000.0;
      final d = distanceM(f.lat, f.lon, lat, lon) - f.accuracyM - accuracyM;
      if (d > 0) {
        final kmh = dt <= 0 ? double.infinity : d / dt * 3.6;
        jumped = kmh > kMtJumpKmh;
      }
      f
        ..lat = lat
        ..lon = lon
        ..accuracyM = accuracyM
        ..lastHeard = at
        ..source = source;
    }
    f
      ..speedKmh = speedKmh
      ..courseDeg = courseDeg
      ..parked = parked
      ..stopped = false
      ..jumped = jumped
      ..snr = snr
      ..pathLen = pathLen;
    f.trail.add(MtTrailPoint(lat, lon, at, breakBefore: jumped));
    _trimTrail(f, now);
    return MtAccept.accepted;
  }

  /// [name] sent `MT1 x` at [at]: greyed out at once (only a name already known).
  void markStopped(String name, DateTime at) {
    final f = _friends[name];
    if (f == null || at.isBefore(f.lastHeard)) return;
    f.stopped = true;
  }

  void _trimTrail(_Friend f, DateTime now) {
    f.trail.removeWhere((p) => now.difference(p.at) > kMtTrailAge);
    while (f.trail.length > kMtTrailPoints) {
      f.trail.removeAt(0);
    }
  }

  /// Drops friends last heard more than 24 h ago and old trail points; true when anything changed.
  bool prune(DateTime now) {
    final before = _friends.length;
    _friends.removeWhere((_, f) => now.difference(f.lastHeard) > kMtOnListFor);
    for (final f in _friends.values) {
      _trimTrail(f, now);
    }
    if (meet != null && now.difference(meet!.at) > kMtOnListFor) meet = null;
    return _friends.length != before;
  }

  /// Snapshots, most recently heard first.
  List<MtFriend> friends(DateTime now) {
    final out = <MtFriend>[];
    for (final f in _friends.values) {
      if (now.difference(f.lastHeard) > kMtOnListFor) continue;
      final st = mtStaleness(f.lastHeard, now, stopped: f.stopped);
      out.add(MtFriend(
        name: f.name,
        lat: f.lat,
        lon: f.lon,
        accuracyM: f.accuracyM,
        speedKmh: f.speedKmh,
        courseDeg: f.courseDeg,
        lastHeard: f.lastHeard,
        staleness: st,
        jumped: f.jumped,
        parked: f.parked,
        stopped: f.stopped,
        source: f.source,
        snr: f.snr,
        pathLen: f.pathLen,
        trail: List.unmodifiable(f.trail.where((p) => now.difference(p.at) <= kMtTrailAge)),
      ));
    }
    out.sort((a, b) => b.lastHeard.compareTo(a.lastHeard));
    return out;
  }

  /// Names heard within [window] of [now] ("3 heard in the last 30 min").
  int heardWithin(Duration window, DateTime now) =>
      _friends.values.where((f) => now.difference(f.lastHeard) <= window).length;

  /// Forget everyone (Leave, Delete my data).
  void clear() {
    _friends.clear();
    _seen.clear();
    meet = null;
  }

  /// Last-known for `meshtrack_last.json`: one entry per friend, no trail.
  Map<String, Object?> toJson() => {
        'friends': [
          for (final f in _friends.values)
            {
              'name': f.name,
              'lat': f.lat,
              'lon': f.lon,
              'acc': f.accuracyM,
              'at': f.lastHeard.toUtc().toIso8601String(),
              if (f.speedKmh != null) 's': f.speedKmh,
              if (f.courseDeg != null) 'c': f.courseDeg,
              if (f.parked) 'parked': true,
              if (f.stopped) 'stopped': true,
              'src': f.source.name,
            }
        ],
        if (meet != null) 'meet': meet!.toJson(),
      };

  /// Restores from [toJson]; entries older than 24 h, or bad, are skipped.
  void restore(Object? j, DateTime now) {
    if (j is! Map) return;
    final list = j['friends'];
    if (list is List) {
      for (final e in list) {
        if (e is! Map) continue;
        final name = e['name'], lat = e['lat'], lon = e['lon'], acc = e['acc'];
        final at = DateTime.tryParse('${e['at']}');
        if (name is! String || lat is! num || lon is! num || at == null) continue;
        if (lat.abs() > 90 || lon.abs() > 180 || now.difference(at) > kMtOnListFor || at.isAfter(now.add(kMtFutureSlack))) continue;
        if (_friends.containsKey(name) || _friends.length >= kMtMaxNames) continue;
        final src = MtSource.values.where((s) => s.name == e['src']).firstOrNull ?? MtSource.meshTrack;
        final f = _Friend(name, lat.toDouble(), lon.toDouble(), acc is num ? acc.toDouble() : 5, at, src)
          ..speedKmh = e['s'] is int ? e['s'] as int : null
          ..courseDeg = e['c'] is int ? e['c'] as int : null
          ..parked = e['parked'] == true
          ..stopped = e['stopped'] == true;
        _friends[name] = f;
      }
    }
    final m = MtMeetPin.fromJson(j['meet']);
    if (m != null && now.difference(m.at) <= kMtOnListFor) meet ??= m;
  }
}
