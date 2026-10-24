// Read-only client + models for a region's public numbers: `public-stats`, `leaderboard`, `public-live` (all no-auth,
// served under /api/cmh/* on every region host), plus the hub's `/v1/regions` (groups) for the All regions list.
// Contract: meshcore-insights `src/lib/platform/types.ts` (PublicStats, LeaderRow, PublicLive) and `src/lib/hub.ts`.
// Unknown/missing values are null, never a fake zero. Pure Dart (no Flutter imports).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

class RegionPublicStats {
  final int? drives, drivers, pings, repeatersHeard;
  final double? km, heardPct, cellsHeardPct;
  final DateTime? lastDriveAt;
  const RegionPublicStats({this.drives, this.drivers, this.pings, this.repeatersHeard, this.km, this.heardPct, this.cellsHeardPct, this.lastDriveAt});

  /// True when nothing has been driven yet (the server sends zeros and a null lastDriveAt).
  bool get isEmpty => (drives ?? 0) == 0 && (pings ?? 0) == 0;

  factory RegionPublicStats.fromJson(Map<String, dynamic> j) => RegionPublicStats(
        drives: _int(j['drives']),
        drivers: _int(j['drivers']),
        pings: _int(j['pings']),
        repeatersHeard: _int(j['repeatersHeard']),
        km: _dbl(j['km']),
        heardPct: _dbl(j['heardPct']),
        cellsHeardPct: _dbl(j['cellsHeardPct']),
        lastDriveAt: _time(j['lastDriveAt']),
      );
}

class LeaderRow {
  final int rank;
  final String callsign;
  final double km;
  final int drives, cells, repeatersHeard;
  const LeaderRow({required this.rank, required this.callsign, required this.km, required this.drives, required this.cells, required this.repeatersHeard});

  static LeaderRow? tryParse(Object? v) {
    if (v is! Map || v['callsign'] is! String) return null;
    return LeaderRow(
      rank: _int(v['rank']) ?? 0,
      callsign: v['callsign'] as String,
      km: _dbl(v['km']) ?? 0,
      drives: _int(v['drives']) ?? 0,
      cells: _int(v['cells']) ?? 0,
      repeatersHeard: _int(v['repeatersHeard']) ?? 0,
    );
  }
}

class Leaderboard {
  final String period;
  final List<LeaderRow> rows;
  const Leaderboard({required this.period, required this.rows});

  factory Leaderboard.fromJson(Map<String, dynamic> j) => Leaderboard(
        period: _str(j['period']) ?? '30d',
        rows: [
          if (j['rows'] is List)
            for (final e in j['rows'] as List)
              ?LeaderRow.tryParse(e),
        ],
      );
}

class RegionLive {
  final int activeDrivers, pings15m;
  final List<String> callsigns; // opted-in drivers only; anonymous ones are not listed
  final DateTime? lastUploadAt;
  const RegionLive({required this.activeDrivers, required this.pings15m, this.callsigns = const [], this.lastUploadAt});

  factory RegionLive.fromJson(Map<String, dynamic> j) => RegionLive(
        activeDrivers: _int(j['activeDrivers']) ?? 0,
        pings15m: _int(j['pings15m']) ?? 0,
        callsigns: [
          if (j['drivers'] is List)
            for (final d in j['drivers'] as List)
              if (d is Map && _str(d['callsign']) != null) d['callsign'] as String,
        ],
        lastUploadAt: _time(j['lastUploadAt']),
      );
}

/// One group from `/v1/regions` (e.g. SWOH with members CVG, DAY).
class RegionGroupInfo {
  final String code, name;
  final List<String> members;
  const RegionGroupInfo({required this.code, required this.name, required this.members});
}

/// `/v1/regions`: region code -> group code, and the groups.
class HubRegions {
  final Map<String, String> groupOf;
  final List<RegionGroupInfo> groups;
  const HubRegions({this.groupOf = const {}, this.groups = const []});

  factory HubRegions.fromJson(Map<String, dynamic> j) {
    final groups = <RegionGroupInfo>[];
    final groupOf = <String, String>{};
    final g = j['groups'];
    if (g is List) {
      for (final e in g) {
        if (e is! Map || e['code'] is! String || e['name'] is! String) continue;
        final members = [if (e['members'] is List) for (final m in e['members'] as List) if (m is String) m];
        groups.add(RegionGroupInfo(code: e['code'] as String, name: e['name'] as String, members: members));
        for (final m in members) {
          groupOf[m] = e['code'] as String;
        }
      }
    }
    return HubRegions(groupOf: groupOf, groups: groups);
  }
}

class RegionStatsException implements Exception {
  final String message;
  const RegionStatsException(this.message);
  @override
  String toString() => message;
}

class RegionStatsApi {
  final String baseUrl;
  final http.Client _client;
  final Duration timeout;
  RegionStatsApi(this.baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 15)}) : _client = client ?? newRegionWireClient();

  Uri _uri(String path, [Map<String, String>? q]) {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$b$path').replace(queryParameters: q);
  }

  Future<RegionPublicStats> stats() async => RegionPublicStats.fromJson(await _get(_uri('/api/cmh/public-stats')));
  Future<Leaderboard> leaderboard({String period = '30d'}) async => Leaderboard.fromJson(await _get(_uri('/api/cmh/leaderboard', {'period': period})));
  Future<RegionLive> live() async => RegionLive.fromJson(await _get(_uri('/api/cmh/public-live')));
  Future<HubRegions> hubRegions() async => HubRegions.fromJson(await _get(_uri('/v1/regions')));

  Future<Map<String, dynamic>> _get(Uri u) async {
    final http.Response res;
    try {
      res = await _client.get(u, headers: const {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      throw const RegionStatsException('The server took too long to answer.');
    } catch (_) {
      throw const RegionStatsException('Could not reach the server. Check your connection.');
    }
    if (res.statusCode != 200) throw RegionStatsException('The server answered ${res.statusCode}.');
    try {
      final b = jsonDecode(utf8.decode(res.bodyBytes));
      if (b is Map<String, dynamic>) return b;
    } catch (_) {}
    throw const RegionStatsException('The server sent something unreadable.');
  }

  void close() => _client.close();
}
