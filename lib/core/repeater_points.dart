// Render-ready repeater points for the map's clustered layers (the global "All MeshCore repeaters" layer `network`
// and the region roster layer `repeaters`). Design: stream-1-maps.md sections 4.3 and 4.4. Pure Dart.
//
// The map does NOT fetch or parse `GET /api/cmh/network-repeaters` itself: the startup-sync work owns the client, the
// parser and the on-disk copy. This file only takes rows the adapter hands over ([MapRepeaterRow], a neutral shape both
// the network list and the region roster convert to), re-checks each position (a row the map cannot place is never
// drawn), drops duplicate keys and packs the rest into typed lists that are cheap to cluster and to send to an isolate.
//
// Age bands match the website (wt-netreps src/lib/network-repeaters.ts `AGE_BANDS`/`ageBand`): last advert within
// 24 h = 0, 7 days = 1, 30 days = 2, older or never reported = 3.
import 'dart:typed_data';

/// One repeater or room server as the map needs it.
class MapRepeaterRow {
  /// Full public key, lower-case hex.
  final String key;
  final String? name;
  final double lat;
  final double lon;

  /// Room server (type 3) rather than repeater (type 2).
  final bool isRoom;

  /// Last advert (global list) or last heard (region roster); null when unknown.
  final DateTime? lastSeen;

  /// Colour bucket for this row when the caller already knows it (roster status ordinal); null = age band.
  final int? band;
  const MapRepeaterRow({
    required this.key,
    required this.lat,
    required this.lon,
    this.name,
    this.isRoom = false,
    this.lastSeen,
    this.band,
  });
}

/// Age band of a last advert at [now] (website parity, see file comment).
int advertAgeBand(DateTime? lastSeen, DateTime now) {
  if (lastSeen == null) return 3;
  final age = now.difference(lastSeen).inMilliseconds / 1000.0;
  if (age <= 86400) return 0;
  if (age <= 7 * 86400) return 1;
  if (age <= 30 * 86400) return 2;
  return 3;
}

/// Labels for the age bands, in band order (the legend).
const List<String> kAdvertAgeBandLabels = ['Advert in the last 24 h', 'Last 7 days', 'Last 30 days', 'Older'];

/// "Last advert 3 h ago (2026-10-24)" (website `advertText`), or "No advert time reported".
String advertText(DateTime? lastSeen, DateTime now, {String verb = 'Last advert'}) {
  if (lastSeen == null) return 'No advert time reported';
  var s = now.difference(lastSeen).inMilliseconds / 1000.0;
  if (s < 0) s = 0;
  final String ago;
  if (s < 3600) {
    final m = (s / 60).round();
    ago = '${m < 1 ? 1 : m} min ago';
  } else if (s < 86400) {
    ago = '${(s / 3600).round()} h ago';
  } else {
    ago = '${(s / 86400).round()} days ago';
  }
  final u = lastSeen.toUtc();
  final day = '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
  return '$verb $ago ($day)';
}

final RegExp _hexKey = RegExp(r'^[0-9a-f]{2,64}$');

/// True when the map can place [r]: finite, in range, not the 0/0 "no position" sentinel, and a hex key.
bool isPlaceable(MapRepeaterRow r) =>
    _hexKey.hasMatch(r.key) &&
    r.lat.isFinite &&
    r.lon.isFinite &&
    r.lat >= -90 &&
    r.lat <= 90 &&
    r.lon >= -180 &&
    r.lon <= 180 &&
    !(r.lat == 0 && r.lon == 0);

/// Index-aligned typed lists, one entry per drawable point.
class RepeaterPoints {
  final Float64List lat, lon;

  /// 2 repeater, 3 room server.
  final Uint8List kind;

  /// Colour bucket: age band 0..3 (global) or the row's own band (roster status ordinal).
  final Uint8List band;

  /// Seconds since the epoch of [MapRepeaterRow.lastSeen], NaN when unknown.
  final Float64List lastSeenS;
  final List<String> key;

  /// Display name: the row's trimmed name, or the first 8 key characters (website rule).
  final List<String> name;

  /// Rows given that were not drawable (bad position or key) or repeated a key already taken.
  final int dropped;

  /// Keys left out because [RepeaterPoints.fromRows] was told to skip them (drawn by another layer).
  final int skipped;

  const RepeaterPoints({
    required this.lat,
    required this.lon,
    required this.kind,
    required this.band,
    required this.lastSeenS,
    required this.key,
    required this.name,
    this.dropped = 0,
    this.skipped = 0,
  });

  static final RepeaterPoints empty = RepeaterPoints(
    lat: Float64List(0),
    lon: Float64List(0),
    kind: Uint8List(0),
    band: Uint8List(0),
    lastSeenS: Float64List(0),
    key: const [],
    name: const [],
  );

  int get length => lat.length;
  bool get isEmpty => lat.isEmpty;

  bool isRoom(int i) => kind[i] == 3;

  DateTime? lastSeen(int i) {
    final s = lastSeenS[i];
    return s.isNaN ? null : DateTime.fromMillisecondsSinceEpoch((s * 1000).round(), isUtc: true);
  }

  /// Index of [k] (lower-case hex), or -1. Linear; use for taps and sheets, not per frame.
  int indexOf(String k) => key.indexOf(k.toLowerCase());

  /// Packs [rows]. Undrawable rows are dropped; for a repeated key the row with the newest [MapRepeaterRow.lastSeen]
  /// wins (the website's server-side dedupe rule); keys in [skipKeys] are left out (a key the roster layer already
  /// draws, so the global layer does not draw it twice). Bands come from each row's own [MapRepeaterRow.band] or else
  /// the advert age at [now]. Output order follows the input order of the kept rows (deterministic).
  factory RepeaterPoints.fromRows(Iterable<MapRepeaterRow> rows, {required DateTime now, Set<String> skipKeys = const {}}) {
    final keep = <String, MapRepeaterRow>{};
    final firstPos = <String, int>{};
    var dropped = 0, skipped = 0, pos = 0;
    for (final r0 in rows) {
      final k = r0.key.toLowerCase();
      final r = k == r0.key
          ? r0
          : MapRepeaterRow(key: k, name: r0.name, lat: r0.lat, lon: r0.lon, isRoom: r0.isRoom, lastSeen: r0.lastSeen, band: r0.band);
      if (!isPlaceable(r)) {
        dropped++;
        continue;
      }
      if (skipKeys.contains(k)) {
        skipped++;
        continue;
      }
      final prev = keep[k];
      if (prev == null) {
        keep[k] = r;
        firstPos[k] = pos++;
      } else {
        dropped++;
        final a = r.lastSeen?.millisecondsSinceEpoch ?? -1, b = prev.lastSeen?.millisecondsSinceEpoch ?? -1;
        if (a > b) keep[k] = r;
      }
    }
    final list = keep.values.toList()..sort((a, b) => firstPos[a.key]!.compareTo(firstPos[b.key]!));
    final n = list.length;
    final lat = Float64List(n), lon = Float64List(n), seen = Float64List(n);
    final kind = Uint8List(n), band = Uint8List(n);
    final keys = List<String>.filled(n, ''), names = List<String>.filled(n, '');
    for (var i = 0; i < n; i++) {
      final r = list[i];
      lat[i] = r.lat;
      lon[i] = r.lon;
      kind[i] = r.isRoom ? 3 : 2;
      final b = r.band ?? advertAgeBand(r.lastSeen, now);
      band[i] = b < 0 ? 0 : (b > 255 ? 255 : b);
      seen[i] = r.lastSeen == null ? double.nan : r.lastSeen!.millisecondsSinceEpoch / 1000.0;
      keys[i] = r.key;
      final nm = r.name?.trim();
      names[i] = (nm == null || nm.isEmpty) ? (r.key.length >= 8 ? r.key.substring(0, 8) : r.key) : nm;
    }
    return RepeaterPoints(
      lat: lat,
      lon: lon,
      kind: kind,
      band: band,
      lastSeenS: seen,
      key: List.unmodifiable(keys),
      name: List.unmodifiable(names),
      dropped: dropped,
      skipped: skipped,
    );
  }
}
