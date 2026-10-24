// Typed client for the per-region repeater roster: `GET <regionHost>/api/cmh/region-repeaters` (public, no auth,
// region hosts only; contract `RepeaterList` in meshcore-insights src/lib/region/types.ts, handler
// src/server/region/handlers.ts). Verified live on cmh/day/cvg.meshsonar.com 2026-10-23:
//   {"status":{"state":"ready|partial|pending|unavailable|stale","reason":str|null,"computedAt":ISO,"source":str},
//    "rows":[{"key":64hex,"hashPrefix":"da5d","name":str|null,"role":"repeater|room|companion|sensor|unknown",
//             "lat":num|null,"lon":num|null,"firstSeenAt":ISO|null,"lastHeardAt":ISO|null,"relays24h":int|null,
//             "adverts24h":int|null,"neighbours":int|null,"observers24h":int|null,"heardHoursPct":num|null,
//             "snrMeanDb":num|null,"signalGrade":"A".."D"|null,"hashSizeBytes":1|2|3|null,"ambiguous":bool,
//             "status":"active|quiet|new|stale"}],
//    "counts":{"active":n,"quiet":n,"new":n,"stale":n}}
// The roster carries no RSSI; SNR is the mean over the last day. Unknown is null, never zero. Pure Dart.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

/// Thrown for a non-200 answer, a network failure or a body that is not a valid roster.
class RegionRepeatersException implements Exception {
  final String message;
  const RegionRepeatersException(this.message);
  @override
  String toString() => 'RegionRepeatersException: $message';
}

/// Activity bucket the server assigns each repeater.
enum RepeaterActivity { active, quiet, fresh, stale }

/// One repeater (or room server) in a region's roster.
class RegionRepeater {
  /// Full public key, lower-case hex.
  final String key;

  /// First byte(s) as shown on the radio, lower-case hex.
  final String hashPrefix;
  final String? name;

  /// "repeater", "room", "companion", "sensor" or "unknown".
  final String role;
  final double? lat;
  final double? lon;
  final DateTime? firstSeenAt;
  final DateTime? lastHeardAt;
  final int? relays24h;
  final int? adverts24h;
  final int? neighbours;
  final int? observers24h;
  final double? heardHoursPct;
  final double? snrMeanDb;
  final String? signalGrade;
  final int? hashSizeBytes;

  /// Another node in the region shares this hash prefix.
  final bool ambiguous;
  final RepeaterActivity status;

  const RegionRepeater({
    required this.key,
    required this.hashPrefix,
    this.name,
    this.role = 'repeater',
    this.lat,
    this.lon,
    this.firstSeenAt,
    this.lastHeardAt,
    this.relays24h,
    this.adverts24h,
    this.neighbours,
    this.observers24h,
    this.heardHoursPct,
    this.snrMeanDb,
    this.signalGrade,
    this.hashSizeBytes,
    this.ambiguous = false,
    this.status = RepeaterActivity.stale,
  });

  /// The name, or the hash prefix when the node never advertised one.
  String get displayName =>
      (name == null || name!.trim().isEmpty) ? hashPrefix : name!.trim();

  bool get hasPosition => lat != null && lon != null;

  factory RegionRepeater.fromJson(Object? j) {
    if (j is! Map) {
      throw const RegionRepeatersException('repeater row is not an object');
    }
    final key = j['key'];
    if (key is! String || key.isEmpty) {
      throw const RegionRepeatersException('repeater row has no key');
    }
    final prefix = j['hashPrefix'];
    return RegionRepeater(
      key: key.toLowerCase(),
      hashPrefix:
          (prefix is String && prefix.isNotEmpty
                  ? prefix
                  : key.substring(0, key.length < 2 ? key.length : 2))
              .toLowerCase(),
      name: j['name'] is String ? j['name'] as String : null,
      role: j['role'] is String ? j['role'] as String : 'unknown',
      lat: _num(j['lat'])?.toDouble(),
      lon: _num(j['lon'])?.toDouble(),
      firstSeenAt: _time(j['firstSeenAt']),
      lastHeardAt: _time(j['lastHeardAt']),
      relays24h: _num(j['relays24h'])?.toInt(),
      adverts24h: _num(j['adverts24h'])?.toInt(),
      neighbours: _num(j['neighbours'])?.toInt(),
      observers24h: _num(j['observers24h'])?.toInt(),
      heardHoursPct: _num(j['heardHoursPct'])?.toDouble(),
      snrMeanDb: _num(j['snrMeanDb'])?.toDouble(),
      signalGrade: j['signalGrade'] is String
          ? j['signalGrade'] as String
          : null,
      hashSizeBytes: _num(j['hashSizeBytes'])?.toInt(),
      ambiguous: j['ambiguous'] == true,
      status: switch (j['status']) {
        'active' => RepeaterActivity.active,
        'quiet' => RepeaterActivity.quiet,
        'new' => RepeaterActivity.fresh,
        _ => RepeaterActivity.stale,
      },
    );
  }
}

num? _num(Object? v) => v is num && v.isFinite ? v : null;
DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toUtc() : null;

/// The server's honesty flag: how complete the data behind a response is.
class RosterStatus {
  /// "ready", "partial", "pending", "unavailable" or "stale".
  final String state;
  final String? reason;
  final DateTime? computedAt;
  const RosterStatus({required this.state, this.reason, this.computedAt});
}

/// A parsed `region-repeaters` response.
class RegionRepeaters {
  final String regionSlug;
  final RosterStatus status;
  final List<RegionRepeater> rows;

  /// Rows per activity bucket as the server counted them (may differ from [rows] if filtered).
  final Map<RepeaterActivity, int> counts;
  const RegionRepeaters({
    required this.regionSlug,
    required this.status,
    required this.rows,
    required this.counts,
  });

  /// Rows that can be drawn on a map.
  List<RegionRepeater> get positioned => [
    for (final r in rows)
      if (r.hasPosition) r,
  ];

  /// Parses a decoded response body; throws [RegionRepeatersException] when it is not a roster.
  factory RegionRepeaters.fromJson(Object? j, {String regionSlug = ''}) {
    if (j is! Map) {
      throw const RegionRepeatersException('response is not a JSON object');
    }
    final rows = j['rows'];
    if (rows is! List) {
      throw const RegionRepeatersException('response has no "rows" list');
    }
    final st = j['status'];
    final status = st is Map && st['state'] is String
        ? RosterStatus(
            state: st['state'] as String,
            reason: st['reason'] is String ? st['reason'] as String : null,
            computedAt: _time(st['computedAt']),
          )
        : throw const RegionRepeatersException('response has no "status"');
    final c = j['counts'];
    int count(String k) => c is Map ? (_num(c[k])?.toInt() ?? 0) : 0;
    return RegionRepeaters(
      regionSlug: regionSlug,
      status: status,
      rows: [for (final r in rows) RegionRepeater.fromJson(r)],
      counts: {
        RepeaterActivity.active: count('active'),
        RepeaterActivity.quiet: count('quiet'),
        RepeaterActivity.fresh: count('new'),
        RepeaterActivity.stale: count('stale'),
      },
    );
  }
}

/// The address of the region's own host. A bare hub address (meshsonar.com, a group host that answers 400
/// "per region") plus a [regionSlug] resolves to `https://<slug>.meshsonar.com`; a region host is used as given.
Uri regionRepeatersUri(String baseUrl, String regionSlug) {
  final base = Uri.tryParse(baseUrl.trim());
  if (base == null || base.host.isEmpty) {
    throw RegionRepeatersException('bad base URL "$baseUrl"');
  }
  var host = base.host;
  if (regionSlug.isNotEmpty &&
      (host == 'meshsonar.com' || host == 'www.meshsonar.com')) {
    host = '$regionSlug.meshsonar.com';
  }
  return Uri(
    scheme: base.scheme.isEmpty ? 'https' : base.scheme,
    host: host,
    port: base.hasPort ? base.port : null,
    path: '/api/cmh/region-repeaters',
  );
}

/// Fetches a region's repeater roster. Throws [RegionRepeatersException] on any failure.
Future<RegionRepeaters> fetchRegionRepeaters(
  String baseUrl,
  String regionSlug, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final uri = regionRepeatersUri(baseUrl, regionSlug);
  final c = client ?? newRegionWireClient();
  try {
    final res = await c
        .get(uri, headers: const {'accept': 'application/json'})
        .timeout(timeout);
    if (res.statusCode != 200) {
      throw RegionRepeatersException(
        'region-repeaters answered HTTP ${res.statusCode}',
      );
    }
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw const RegionRepeatersException(
        'region-repeaters returned invalid JSON',
      );
    }
    return RegionRepeaters.fromJson(body, regionSlug: regionSlug);
  } on RegionRepeatersException {
    rethrow;
  } on TimeoutException {
    throw const RegionRepeatersException('region-repeaters timed out');
  } catch (e) {
    throw RegionRepeatersException('region-repeaters failed: $e');
  } finally {
    if (client == null) c.close();
  }
}
