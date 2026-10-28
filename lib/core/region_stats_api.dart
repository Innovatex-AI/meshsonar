// Read-only client + models for a region's public numbers: `public-stats`, `leaderboard`, `public-live` (all no-auth,
// served under /api/cmh/* on every region host), plus the hub's `/v1/regions` (groups) for the All regions list.
// Contract: meshcore-insights `src/lib/platform/types.ts` (PublicStats, LeaderRow, PublicLive) and `src/lib/hub.ts`.
// Unknown/missing values are null, never a fake zero. Pure Dart (no Flutter imports).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'api.dart' show PresetNone, RadioPreset;
import 'etag_client.dart';

int? _int(Object? v) => v is num ? v.toInt() : null;
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
DateTime? _time(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;

class RegionPublicStats {
  final int? drives, drivers, pings, repeatersHeard;
  final double? km, heardPct, cellsHeardPct;
  final DateTime? lastDriveAt;

  /// Set when this is the copy stored on the phone, served because the network failed: when it was fetched.
  final DateTime? offlineAsOf;
  const RegionPublicStats(
      {this.drives, this.drivers, this.pings, this.repeatersHeard, this.km, this.heardPct, this.cellsHeardPct, this.lastDriveAt, this.offlineAsOf});

  /// True when nothing has been driven yet (the server sends zeros and a null lastDriveAt).
  bool get isEmpty => (drives ?? 0) == 0 && (pings ?? 0) == 0;

  factory RegionPublicStats.fromJson(Map<String, dynamic> j, {DateTime? offlineAsOf}) => RegionPublicStats(
        drives: _int(j['drives']),
        drivers: _int(j['drivers']),
        pings: _int(j['pings']),
        repeatersHeard: _int(j['repeatersHeard']),
        km: _dbl(j['km']),
        heardPct: _dbl(j['heardPct']),
        cellsHeardPct: _dbl(j['cellsHeardPct']),
        lastDriveAt: _time(j['lastDriveAt']),
        offlineAsOf: offlineAsOf,
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

  /// Set when this is the copy stored on the phone, served because the network failed: when it was fetched.
  final DateTime? offlineAsOf;
  const Leaderboard({required this.period, required this.rows, this.offlineAsOf});

  factory Leaderboard.fromJson(Map<String, dynamic> j, {DateTime? offlineAsOf}) => Leaderboard(
        period: _str(j['period']) ?? '30d',
        rows: [
          if (j['rows'] is List)
            for (final e in j['rows'] as List)
              ?LeaderRow.tryParse(e),
        ],
        offlineAsOf: offlineAsOf,
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

/// One region's row of `/v1/regions`: the numbers the app needs about a region that `regions-index` does not carry.
class RegionCatalogEntry {
  final String code;
  final String? group;

  /// `default_preset` with its provenance (`basis`, `source`, `note`); null when the region has none on file.
  final RadioPreset? preset;

  /// Why there is none, when the server says (`preset_none`); see [PresetNone].
  final PresetNone? presetNone;

  /// IANA time zone, when the server sends it.
  final String? timezone;
  const RegionCatalogEntry({required this.code, this.group, this.preset, this.presetNone, this.timezone});

  static RegionCatalogEntry? tryParse(Object? e) {
    if (e is! Map || e['code'] is! String) return null;
    RadioPreset? preset;
    final p = e['default_preset'];
    if (p is Map) {
      final f = p['freq_mhz'], bw = p['bw_khz'], sf = p['sf'], cr = p['cr'], name = p['name'];
      if (name is String && f is num && bw is num && sf is num && cr is num) {
        String? str(Object? v) => v is String && v.trim().isNotEmpty ? v.trim() : null;
        preset = RadioPreset(
            name: name, freqMhz: f.toDouble(), bwKhz: bw.toDouble(), sf: sf.toInt(), cr: cr.toInt(), basis: str(p['basis']), source: str(p['source']), note: str(p['note']));
      }
    }
    final tz = e['timezone'];
    return RegionCatalogEntry(
      code: e['code'] as String,
      group: e['group'] is String ? e['group'] as String : null,
      preset: preset,
      presetNone: preset == null ? PresetNone.tryParse(e['preset_none']) : null,
      timezone: tz is String && tz.isNotEmpty ? tz : null,
    );
  }
}

/// `/v1/regions`: region code -> group code, the groups, and each region's catalogue row.
class HubRegions {
  final Map<String, String> groupOf;
  final List<RegionGroupInfo> groups;
  final Map<String, RegionCatalogEntry> byCode;
  const HubRegions({this.groupOf = const {}, this.groups = const [], this.byCode = const {}});

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
    final byCode = <String, RegionCatalogEntry>{};
    final r = j['regions'];
    if (r is List) {
      for (final e in r) {
        final c = RegionCatalogEntry.tryParse(e);
        if (c != null) byCode[c.code] = c;
      }
    }
    return HubRegions(groupOf: groupOf, groups: groups, byCode: byCode);
  }
}

class RegionStatsException implements Exception {
  final String message;

  /// True when the server could not be reached at all (no connection, timeout), not an error answer.
  final bool offline;

  /// The HTTP status of an error answer (429 = the server asked for a pause), null when there was no answer.
  final int? status;
  const RegionStatsException(this.message, {this.offline = false, this.status});
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

  Future<RegionPublicStats> stats() async {
    final (j, asOf) = await _getWithAsOf(_uri('/api/cmh/public-stats'));
    return RegionPublicStats.fromJson(j, offlineAsOf: asOf);
  }

  Future<Leaderboard> leaderboard({String period = '30d'}) async {
    final (j, asOf) = await _getWithAsOf(_uri('/api/cmh/leaderboard', {'period': period}));
    return Leaderboard.fromJson(j, offlineAsOf: asOf);
  }

  /// Never cached (live counts from a disk copy would lie), so offline this throws with `offline: true`.
  Future<RegionLive> live() async => RegionLive.fromJson(await _get(_uri('/api/cmh/public-live')));
  Future<HubRegions> hubRegions() async => HubRegions.fromJson(await _get(_uri('/v1/regions')));

  Future<Map<String, dynamic>> _get(Uri u) async => (await _getWithAsOf(u)).$1;

  /// The decoded body and, when it is the stored copy served offline, its fetch time.
  Future<(Map<String, dynamic>, DateTime?)> _getWithAsOf(Uri u) async {
    final http.Response res;
    try {
      res = await _client.get(u, headers: const {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      throw const RegionStatsException('The server took too long to answer.', offline: true);
    } catch (_) {
      throw const RegionStatsException('Could not reach the server. Check your connection.', offline: true);
    }
    if (res.statusCode != 200) throw RegionStatsException('The server answered ${res.statusCode}.', status: res.statusCode);
    try {
      final b = jsonDecode(utf8.decode(res.bodyBytes));
      if (b is Map<String, dynamic>) return (b, offlineAsOfOf(res));
    } catch (_) {}
    throw const RegionStatsException('The server sent something unreadable.');
  }

  void close() => _client.close();
}
