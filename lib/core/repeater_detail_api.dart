// Client + model for `GET <region host>/api/cmh/region-repeater?key=<64 hex>` (public, no auth): everything the website's
// repeater page shows for one node. Contract: meshcore-insights `src/lib/region/types.ts` (`RepeaterDetail`) plus the
// `heatmapEnd` field the server sends (verified live on cmh.meshsonar.com, 2026-10-23).
//   {status{state,reason,computedAt,source}, row{...}|null, neighbours[], heatmap[7][24]|null, heatmapEnd:"YYYY-MM-DD",
//    snrHourly[{at,mean|null,n}], rssiHourly[...], packetTypes[{type,n}], observers[...], adverts[...], events[...], reach}
// Unknown is null, never zero. An unknown key answers HTTP 404 with the same shape and status.state "not_found";
// a malformed key is 400. Parsing is tolerant: a malformed element is skipped, never fatal.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

enum RepeaterDetailFailure { badKey, notFound, network, server, unreadable }

class RepeaterDetailException implements Exception {
  final RepeaterDetailFailure kind;
  final String message;
  const RepeaterDetailException(this.kind, this.message);
  @override
  String toString() => message;
}

/// The website's `Sourced` block: ready | partial | pending | unavailable | stale | not_found.
class SourcedStatus {
  final String state;
  final String? reason;
  final DateTime? computedAt;
  final String? source;
  const SourcedStatus({
    required this.state,
    this.reason,
    this.computedAt,
    this.source,
  });
  bool get isReady => state == 'ready';
}

class RepeaterRowInfo {
  final String key, hashPrefix;
  final String? name;
  final String role; // repeater | room | companion | sensor | unknown
  final double? lat, lon;
  final DateTime? firstSeenAt, lastHeardAt;
  final int? relays24h, adverts24h, neighbours, observers24h, hashSizeBytes;
  final double? heardHoursPct, snrMeanDb;
  final String? signalGrade;
  final bool ambiguous;
  final String status; // active | quiet | new | stale
  const RepeaterRowInfo({
    required this.key,
    required this.hashPrefix,
    required this.name,
    required this.role,
    this.lat,
    this.lon,
    this.firstSeenAt,
    this.lastHeardAt,
    this.relays24h,
    this.adverts24h,
    this.neighbours,
    this.observers24h,
    this.hashSizeBytes,
    this.heardHoursPct,
    this.snrMeanDb,
    this.signalGrade,
    this.ambiguous = false,
    this.status = 'stale',
  });
  bool get hasPosition => lat != null && lon != null;
  String get displayName => (name?.trim().isNotEmpty ?? false)
      ? name!.trim()
      : 'Repeater $hashPrefix';
}

class RepeaterNeighbourInfo {
  final String key;
  final String? name;
  final String kind; // reported | observed | inferred
  final double? snrDb, rssiDbm, distanceKm;
  final DateTime? lastAt;
  final int? packets;
  const RepeaterNeighbourInfo({
    required this.key,
    this.name,
    required this.kind,
    this.snrDb,
    this.rssiDbm,
    this.distanceKm,
    this.lastAt,
    this.packets,
  });
}

class HourlyPoint {
  final DateTime at;
  final double? mean;
  final int n;
  const HourlyPoint(this.at, this.mean, this.n);
}

class PacketTypeCount {
  final int type, n;
  const PacketTypeCount(this.type, this.n);
}

class RepeaterObserverInfo {
  final String key;
  final String? name;
  final int packets;
  final double? bestSnrDb;
  final DateTime? lastAt;
  const RepeaterObserverInfo({
    required this.key,
    this.name,
    required this.packets,
    this.bestSnrDb,
    this.lastAt,
  });
}

class RepeaterEventInfo {
  final String type, detail;
  final DateTime? at;
  const RepeaterEventInfo(this.type, this.detail, this.at);
}

class RepeaterDetailData {
  final SourcedStatus status;
  final RepeaterRowInfo? row;
  final List<RepeaterNeighbourInfo> neighbours;

  /// 7 days x 24 hours of packet counts, `[0]` = oldest day, ending on [heatmapEnd]. Null when the server has none.
  final List<List<int>>? heatmap;

  /// `YYYY-MM-DD` (UTC) of the last heatmap row; falls back to `status.computedAt` when the server omits it.
  final String? heatmapEnd;
  final List<HourlyPoint> snrHourly, rssiHourly;
  final List<PacketTypeCount> packetTypes;
  final List<RepeaterObserverInfo> observers;
  final List<RepeaterEventInfo> events;
  final double? reachMaxKm;
  const RepeaterDetailData({
    required this.status,
    required this.row,
    this.neighbours = const [],
    this.heatmap,
    this.heatmapEnd,
    this.snrHourly = const [],
    this.rssiHourly = const [],
    this.packetTypes = const [],
    this.observers = const [],
    this.events = const [],
    this.reachMaxKm,
  });

  /// Calendar day (UTC) of heatmap row [dayIndex], or null when there is no anchor.
  DateTime? heatmapDay(int dayIndex) {
    final rows = heatmap?.length ?? 0;
    final end = heatmapEnd != null
        ? DateTime.tryParse(heatmapEnd!)
        : status.computedAt;
    if (end == null || rows == 0) return null;
    final endDay = DateTime.utc(
      end.toUtc().year,
      end.toUtc().month,
      end.toUtc().day,
    );
    return endDay.subtract(Duration(days: rows - 1 - dayIndex));
  }

  static RepeaterDetailData parse(Object? j) {
    if (j is! Map) {
      throw const RepeaterDetailException(
        RepeaterDetailFailure.unreadable,
        'The server sent an unreadable answer.',
      );
    }
    final st = j['status'];
    final status = st is Map
        ? SourcedStatus(
            state: st['state'] is String
                ? st['state'] as String
                : 'unavailable',
            reason: _s(st['reason']),
            computedAt: _t(st['computedAt']),
            source: _s(st['source']),
          )
        : const SourcedStatus(state: 'unavailable');
    return RepeaterDetailData(
      status: status,
      row: _row(j['row']),
      neighbours: _list(j['neighbours'], _neighbour),
      heatmap: _heatmap(j['heatmap']),
      heatmapEnd: _s(j['heatmapEnd']),
      snrHourly: _list(j['snrHourly'], _hourly),
      rssiHourly: _list(j['rssiHourly'], _hourly),
      packetTypes: _list(j['packetTypes'], (e) {
        final t = _i(e['type']), n = _i(e['n']);
        return t == null || n == null ? null : PacketTypeCount(t, n);
      }),
      observers: _list(j['observers'], (e) {
        final k = _s(e['key']);
        return k == null
            ? null
            : RepeaterObserverInfo(
                key: k,
                name: _s(e['name']),
                packets: _i(e['packets']) ?? 0,
                bestSnrDb: _d(e['bestSnrDb']),
                lastAt: _t(e['lastAt']),
              );
      }),
      events: _list(j['events'], (e) {
        final t = _s(e['type']);
        return t == null
            ? null
            : RepeaterEventInfo(t, _s(e['detail']) ?? '', _t(e['at']));
      }),
      reachMaxKm: j['reach'] is Map ? _d((j['reach'] as Map)['maxKm']) : null,
    );
  }
}

String? _s(Object? v) => v is String ? v : null;
double? _d(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _i(Object? v) => v is num && v.isFinite ? v.toInt() : null;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v) : null;

List<T> _list<T>(Object? v, T? Function(Map e) f) {
  final out = <T>[];
  if (v is! List) return out;
  for (final e in v) {
    if (e is Map) {
      final x = f(e);
      if (x != null) out.add(x);
    }
  }
  return out;
}

HourlyPoint? _hourly(Map e) {
  final at = _t(e['at']);
  return at == null ? null : HourlyPoint(at, _d(e['mean']), _i(e['n']) ?? 0);
}

RepeaterNeighbourInfo? _neighbour(Map e) {
  final k = _s(e['key']);
  if (k == null) return null;
  return RepeaterNeighbourInfo(
    key: k,
    name: _s(e['name']),
    kind: _s(e['kind']) ?? 'observed',
    snrDb: _d(e['snrDb']),
    rssiDbm: _d(e['rssiDbm']),
    distanceKm: _d(e['distanceKm']),
    lastAt: _t(e['lastAt']),
    packets: _i(e['packets']),
  );
}

List<List<int>>? _heatmap(Object? v) {
  if (v is! List || v.isEmpty) return null;
  final out = <List<int>>[];
  for (final r in v) {
    if (r is! List) return null;
    out.add([for (final c in r) _i(c) ?? 0]);
  }
  return out;
}

RepeaterRowInfo? _row(Object? v) {
  if (v is! Map) return null;
  final key = _s(v['key']);
  if (key == null) return null;
  return RepeaterRowInfo(
    key: key,
    hashPrefix:
        _s(v['hashPrefix']) ?? (key.length >= 2 ? key.substring(0, 2) : key),
    name: _s(v['name']),
    role: _s(v['role']) ?? 'unknown',
    lat: _d(v['lat']),
    lon: _d(v['lon']),
    firstSeenAt: _t(v['firstSeenAt']),
    lastHeardAt: _t(v['lastHeardAt']),
    relays24h: _i(v['relays24h']),
    adverts24h: _i(v['adverts24h']),
    neighbours: _i(v['neighbours']),
    observers24h: _i(v['observers24h']),
    hashSizeBytes: _i(v['hashSizeBytes']),
    heardHoursPct: _d(v['heardHoursPct']),
    snrMeanDb: _d(v['snrMeanDb']),
    signalGrade: _s(v['signalGrade']),
    ambiguous: v['ambiguous'] == true,
    status: _s(v['status']) ?? 'stale',
  );
}

final _keyRe = RegExp(r'^[0-9a-fA-F]{64}$');

/// Fetches one repeater from the region host at [baseUrl]. Throws [RepeaterDetailException].
Future<RepeaterDetailData> fetchRepeaterDetail(
  String baseUrl,
  String repeaterKey, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (!_keyRe.hasMatch(repeaterKey)) {
    throw const RepeaterDetailException(
      RepeaterDetailFailure.badKey,
      'That is not a valid repeater key.',
    );
  }
  final base = Uri.tryParse(baseUrl.trim());
  if (base == null || !base.hasScheme || base.host.isEmpty) {
    throw const RepeaterDetailException(
      RepeaterDetailFailure.network,
      'No server address is set.',
    );
  }
  var path = base.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final uri = base.replace(
    path: '$path/api/cmh/region-repeater',
    queryParameters: {'key': repeaterKey.toLowerCase()},
    fragment: null,
  );
  final c = client ?? http.Client();
  try {
    final res = await c
        .get(uri, headers: {'accept': 'application/json'})
        .timeout(timeout);
    Object? body;
    try {
      body = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      body = null;
    }
    if (res.statusCode == 404) {
      throw const RepeaterDetailException(
        RepeaterDetailFailure.notFound,
        'This region does not know that repeater.',
      );
    }
    if (res.statusCode == 400) {
      throw const RepeaterDetailException(
        RepeaterDetailFailure.badKey,
        'The server rejected the repeater key.',
      );
    }
    if (res.statusCode != 200) {
      throw RepeaterDetailException(
        RepeaterDetailFailure.server,
        'The server answered ${res.statusCode}.',
      );
    }
    final d = RepeaterDetailData.parse(body);
    if (d.status.state == 'not_found') {
      throw const RepeaterDetailException(
        RepeaterDetailFailure.notFound,
        'This region does not know that repeater.',
      );
    }
    return d;
  } on TimeoutException {
    throw const RepeaterDetailException(
      RepeaterDetailFailure.network,
      'Timed out talking to the server.',
    );
  } on SocketException catch (e) {
    throw RepeaterDetailException(
      RepeaterDetailFailure.network,
      'Network error: ${e.message}',
    );
  } on http.ClientException catch (e) {
    throw RepeaterDetailException(
      RepeaterDetailFailure.network,
      'Network error: ${e.message}',
    );
  } on HandshakeException {
    throw const RepeaterDetailException(
      RepeaterDetailFailure.network,
      'Secure connection failed.',
    );
  } finally {
    if (client == null) c.close();
  }
}

/// MeshCore payload type names (same table as the website's `packet-types.ts`).
String packetTypeName(int t) =>
    const {
      0: 'Request',
      1: 'Response',
      2: 'Direct message',
      3: 'Ack',
      4: 'Advert',
      5: 'Group text',
      6: 'Group data',
      7: 'Anonymous request',
      8: 'Path',
      9: 'Trace',
      10: 'Multipart',
      11: 'Control',
      15: 'Raw custom',
    }[t] ??
    'Type $t';
