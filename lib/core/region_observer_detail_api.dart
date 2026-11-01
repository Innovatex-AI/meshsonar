// `region-observer?key=<hex>`: one observer of the region, as the website's /observers/$key shows it (public GET on the region
// host, ETag client, last good copy served offline). Contract: meshcore-insights src/lib/region/types.ts `ObserverDetail`.
//   {status{state,reason,computedAt,source}, row{key,name,online,lastPacketAt,lastStatusAt,staleSince?,packetsPerHour,noiseFloorDbm,
//    radio,firmware,model,batteryMv,lat,lon,nodesHeard24h,trusted,source} | null,
//    noiseFloor[{at,dbm|null}], airtime[{at,txPct|null,rxPct|null}], battery[{at,mv|null}], packetsPerHour[{at,n}],
//    packetTypes[{type,n}], topNodes[{key,name,packets,bestSnrDb|null}]}   (hourly, last 7 days, oldest first)
// An unknown key is HTTP 404 (fetchRegionDataset reports notFound).
//
// HEALTH: website migration 0100 (capability `observerHealth`) adds an optional `row.health` =
//   {state: ok|quiet|deaf|offline, reason, lastStatusAt, flatSince, flatSinceExact, flatMinutes,
//    battery{mv, low, trend: falling|steady|rising|unknown, slopeMvPerH}}
// (absent on a group host, for CoreScope observers, or when status rows could not be read). [ObserverHealth.notice] ports the
// website's healthNotice (src/lib/observers/health-text.ts): a line only for a deaf radio or a low battery. Pure Dart.
import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus, RegionObserver;

class ObserverHealth {
  final String state; // ok | quiet | deaf | offline (free text from the server; unknown words are shown as is)
  final String? reason;
  final DateTime? flatSince;
  final bool flatSinceExact;
  final int? batteryMv;
  final bool batteryLow;
  final String batteryTrend;
  const ObserverHealth({required this.state, this.reason, this.flatSince, this.flatSinceExact = true, this.batteryMv, this.batteryLow = false, this.batteryTrend = 'unknown'});

  static ObserverHealth? tryParse(Map<String, dynamic> row) {
    final h = row['health'];
    if (h is! Map<String, dynamic>) return null;
    final s = jStr(h['state']);
    if (s == null) return null;
    final b = jMap(h['battery']);
    return ObserverHealth(
      state: s,
      reason: jStr(h['reason']),
      flatSince: jTime(h['flatSince']),
      flatSinceExact: h['flatSinceExact'] != false,
      batteryMv: jInt(b['mv']),
      batteryLow: b['low'] == true && jInt(b['mv']) != null,
      batteryTrend: jStr(b['trend']) ?? 'unknown',
    );
  }

  static String _volts(int mv) => '${(mv / 1000).toStringAsFixed(2)} V';
  String get _battery => '${_volts(batteryMv!)}${batteryTrend == 'falling' ? ' and falling' : ''}';

  /// null = nothing to flag (ok, quiet, offline with a good battery). [clock] formats a local HH:MM.
  ({bool bad, String headline})? notice(String Function(DateTime) clock) {
    if (state == 'deaf') {
      final since = flatSince == null ? '' : (flatSinceExact ? 'since ${clock(flatSince!)}' : 'for more than 12 h (since ${clock(flatSince!)} at least)');
      final deaf = 'Not hearing packets${since.isEmpty ? '' : ' $since'}, check the radio';
      return (bad: true, headline: batteryLow ? 'Battery low: $_battery, the likely cause. $deaf' : deaf);
    }
    if (batteryLow) {
      return (bad: false, headline: 'Battery low: $_battery${state == 'ok' ? ', likely cause if it stops hearing packets' : ', likely cause if it stopped hearing packets'}');
    }
    return null;
  }
}

class HourPoint {
  final DateTime at;
  final double? a, b;
  const HourPoint(this.at, this.a, [this.b]);
}

class ObserverNode {
  final String key;
  final String? name;
  final int packets;
  final double? bestSnrDb;
  const ObserverNode(this.key, this.name, this.packets, this.bestSnrDb);
  String get displayName => name ?? '${key.substring(0, key.length < 8 ? key.length : 8)}…';
}

class ObserverDetailData {
  final RegionDataStatus status;
  final RegionObserver? row;
  final String? radio;
  final DateTime? staleSince;
  final ObserverHealth? health;
  final List<HourPoint> noiseFloor; // a = dBm
  final List<HourPoint> airtime; // a = tx %, b = rx %
  final List<HourPoint> battery; // a = mV
  final List<HourPoint> packetsPerHour; // a = n
  final List<(int type, int n)> packetTypes;
  final List<ObserverNode> topNodes;
  const ObserverDetailData({
    required this.status,
    this.row,
    this.radio,
    this.staleSince,
    this.health,
    this.noiseFloor = const [],
    this.airtime = const [],
    this.battery = const [],
    this.packetsPerHour = const [],
    this.packetTypes = const [],
    this.topNodes = const [],
  });

  bool get hasCharts => noiseFloor.isNotEmpty || airtime.isNotEmpty || battery.isNotEmpty || packetsPerHour.isNotEmpty;

  static List<HourPoint> _series(Object? v, String a, [String? b]) => [
        for (final m in jMaps(v))
          if (jTime(m['at']) != null) HourPoint(jTime(m['at'])!, jDbl(m[a]), b == null ? null : jDbl(m[b])),
      ]..sort((x, y) => x.at.compareTo(y.at));

  static ObserverDetailData parse(Map<String, dynamic> j) {
    final rowJson = j['row'] is Map<String, dynamic> ? j['row'] as Map<String, dynamic> : null;
    return ObserverDetailData(
      status: RegionDataStatus.fromJson(j['status']),
      row: RegionObserver.tryParse(rowJson),
      radio: rowJson == null ? null : jStr(rowJson['radio']),
      staleSince: rowJson == null ? null : jTime(rowJson['staleSince']),
      health: rowJson == null ? null : ObserverHealth.tryParse(rowJson),
      noiseFloor: _series(j['noiseFloor'], 'dbm'),
      airtime: _series(j['airtime'], 'txPct', 'rxPct'),
      battery: _series(j['battery'], 'mv'),
      packetsPerHour: _series(j['packetsPerHour'], 'n'),
      packetTypes: [
        for (final m in jMaps(j['packetTypes']))
          if (jInt(m['type']) != null && jInt(m['n']) != null) (jInt(m['type'])!, jInt(m['n'])!),
      ],
      topNodes: [
        for (final m in jMaps(j['topNodes']))
          if (jStr(m['key']) != null) ObserverNode(jStr(m['key'])!, jStr(m['name']), jInt(m['packets']) ?? 0, jDbl(m['bestSnrDb'])),
      ],
    );
  }
}

class ObserverDetailApi {
  final String baseUrl;
  final http.Client? client;
  ObserverDetailApi(this.baseUrl, {this.client});
  Uri uriFor(String key) => regionDatasetUri(baseUrl, 'region-observer', {'key': key.toLowerCase()});
  Future<RegionFetch<ObserverDetailData>> fetch(String key) => fetchRegionDataset(uriFor(key), ObserverDetailData.parse, client: client);
}
