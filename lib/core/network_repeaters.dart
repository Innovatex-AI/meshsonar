// The global repeater layer: every repeater and room server of the whole MeshCore network with a public position, as
// MeshSonar's server republishes it from map.meshcore.io. Pure Dart.
//
// Endpoint: GET <server>/api/cmh/network-repeaters (public, no auth, GLOBAL: the same answer on every MeshSonar host).
// Being built in meshcore-insights (branch feat/network-repeaters, migration 0045, not deployed as of Oct 24 2026: the
// live server answers 404, which the app treats as "capability absent"). Contract read from that branch's
// src/lib/network-repeaters.ts and docs/PLATFORM_CONTRACT.md:
//   {"v":1,"asOf":ISO|null,"generatedAt":ISO,"count":n,"hidden":n,
//    "attribution":{"name":"MeshCore Map","url":"https://map.meshcore.io"},
//    "rows":[[publicKey(64 hex), name|null, lat, lon, type(2 repeater|3 room), lastAdvertEpochS|null], ...]}
//   ETag + If-None-Match -> 304, gzip, Cache-Control public max-age=600, 120 req/min/IP.
//
// The parser is tolerant about the envelope (a bare array of rows, or the object above; object rows with named fields)
// and strict about every row: a row that is not a valid key + position + type is dropped, never guessed at. An answer
// that is not recognisably this list at all is an error (so a 200 HTML page never wipes the stored list).
import 'heard.dart' show haversineM;
import 'model.dart';

class NetworkRepeatersFormatException implements Exception {
  final String message;
  const NetworkRepeatersFormatException(this.message);
  @override
  String toString() => 'NetworkRepeatersFormatException: $message';
}

/// One repeater (type 2) or room server (type 3) of the network.
class NetworkRepeater {
  /// Full public key, lower-case hex (64 chars).
  final String key;
  final String? name;
  final double lat;
  final double lon;

  /// 2 = repeater, 3 = room server (map.meshcore.io's node types).
  final int type;

  /// Last advert the network map saw, or null when it never reported one.
  final DateTime? lastAdvert;
  const NetworkRepeater({required this.key, required this.lat, required this.lon, this.name, this.type = 2, this.lastAdvert});

  bool get isRoom => type == 3;

  /// The name, or the first 8 key characters (what the website shows for an unnamed node).
  String get displayName => (name == null || name!.trim().isEmpty) ? key.substring(0, 8) : name!.trim();

  RepeaterRef toRef() => RepeaterRef(key: key, name: name?.trim() ?? '', lat: lat, lon: lon);

  /// The compact on-disk row: `[key, name, lat, lon, type, lastAdvertEpochS]` (positions to 5 decimals, about 1 m).
  List<Object?> toRow() => [key, name, _round5(lat), _round5(lon), type, lastAdvert == null ? null : lastAdvert!.millisecondsSinceEpoch ~/ 1000];

  static double _round5(double v) => (v * 100000).roundToDouble() / 100000;

  static final RegExp _key = RegExp(r'^[0-9a-f]{64}$');

  /// One row, strictly checked; null when it is not a valid row.
  static NetworkRepeater? tryParse(Object? r) {
    Object? k, n, la, lo, t, a;
    if (r is List) {
      if (r.length < 5) return null;
      k = r[0];
      n = r[1];
      la = r[2];
      lo = r[3];
      t = r[4];
      a = r.length > 5 ? r[5] : null;
    } else if (r is Map) {
      k = r['key'] ?? r['publicKey'] ?? r['public_key'];
      n = r['name'];
      la = r['lat'];
      lo = r['lon'];
      t = r['type'];
      a = r['lastAdvert'] ?? r['last_advert'] ?? r['adv'];
    } else {
      return null;
    }
    if (k is! String) return null;
    final key = k.toLowerCase();
    if (!_key.hasMatch(key)) return null;
    if (n != null && n is! String) return null;
    if (la is! num || lo is! num) return null;
    final lat = la.toDouble(), lon = lo.toDouble();
    if (!lat.isFinite || !lon.isFinite || lat < -90 || lat > 90 || lon < -180 || lon > 180 || (lat == 0 && lon == 0)) return null;
    final int type;
    if (t == 2 || t == 'repeater') {
      type = 2;
    } else if (t == 3 || t == 'room') {
      type = 3;
    } else {
      return null;
    }
    DateTime? adv;
    if (a != null) {
      if (a is! num || !a.isFinite) return null;
      // Epoch seconds per the contract; a millisecond value (> year 5138 in seconds) is read as milliseconds.
      final ms = a > 1e11 ? a.toInt() : (a * 1000).toInt();
      adv = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
    }
    final name = (n as String?)?.trim();
    return NetworkRepeater(key: key, name: (name == null || name.isEmpty) ? null : name, lat: lat, lon: lon, type: type, lastAdvert: adv);
  }
}

/// A parsed network-repeaters answer (or the stored copy of one).
class NetworkRepeaters {
  /// When the server's collector last pulled the list (null when the server did not say).
  final DateTime? asOf;

  /// Positioned repeaters/rooms, one per key.
  final List<NetworkRepeater> rows;

  /// Repeaters whose owners hide the position: counted by the server, never listed.
  final int hidden;

  /// Rows the server sent that failed validation and were dropped.
  final int dropped;
  const NetworkRepeaters({required this.rows, this.asOf, this.hidden = 0, this.dropped = 0});

  static const empty = NetworkRepeaters(rows: []);

  /// Parses a decoded body. Throws [NetworkRepeatersFormatException] when it is not this list; drops bad rows.
  /// [maxRows] bounds memory and disk: rows beyond it are dropped (newest adverts kept).
  factory NetworkRepeaters.parse(Object? decoded, {int maxRows = 100000}) {
    List<dynamic>? rows;
    DateTime? asOf;
    var hidden = 0;
    if (decoded is List) {
      rows = decoded;
    } else if (decoded is Map) {
      final v = decoded['v'];
      if (v != null && v != 1) throw NetworkRepeatersFormatException('unsupported version $v');
      final r = decoded['rows'] ?? decoded['repeaters'];
      if (r is! List) throw const NetworkRepeatersFormatException('no "rows" list');
      rows = r;
      final a = decoded['asOf'];
      if (a is String) asOf = DateTime.tryParse(a)?.toUtc();
      final h = decoded['hidden'];
      if (h is num && h.isFinite && h >= 0) hidden = h.toInt();
    } else {
      throw const NetworkRepeatersFormatException('not a JSON object or array');
    }
    final byKey = <String, NetworkRepeater>{};
    var dropped = 0;
    for (final r in rows) {
      final p = NetworkRepeater.tryParse(r);
      if (p == null) {
        dropped++;
        continue;
      }
      final prev = byKey[p.key];
      if (prev == null || _newer(p, prev)) byKey[p.key] = p;
    }
    var list = byKey.values.toList();
    if (list.length > maxRows) {
      list.sort((a, b) => (b.lastAdvert?.millisecondsSinceEpoch ?? 0).compareTo(a.lastAdvert?.millisecondsSinceEpoch ?? 0));
      dropped += list.length - maxRows;
      list = list.sublist(0, maxRows);
    }
    return NetworkRepeaters(rows: List.unmodifiable(list), asOf: asOf, hidden: hidden, dropped: dropped);
  }

  static bool _newer(NetworkRepeater a, NetworkRepeater b) =>
      (a.lastAdvert?.millisecondsSinceEpoch ?? -1) > (b.lastAdvert?.millisecondsSinceEpoch ?? -1);

  /// The repeaters within [radiusKm] of a point, nearest first, at most [max], skipping ones whose last advert is
  /// older than [maxAdvertAge] (never-reported adverts are kept). Same rules the map.meshcore.io directory uses, so
  /// the name lookup sees the same neighbourhood whichever source feeds it.
  List<RepeaterRef> nearby(double lat, double lon,
      {double radiusKm = 150, int max = 3000, Duration maxAdvertAge = const Duration(days: 180), required DateTime now}) {
    final out = <(RepeaterRef, double)>[];
    final limit = radiusKm * 1000;
    // Cheap prefilter: a degree of latitude is ~111 km.
    final dLat = radiusKm / 110.0;
    for (final r in rows) {
      if ((r.lat - lat).abs() > dLat) continue;
      final adv = r.lastAdvert;
      if (adv != null && now.difference(adv) > maxAdvertAge) continue;
      final d = haversineM(lat, lon, r.lat, r.lon);
      if (d <= limit) out.add((r.toRef(), d));
    }
    out.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final e in out.take(max)) e.$1];
  }
}
