// Read-only client + models for the public region data endpoints (`region-overview`, `region-observers`).
// Contract: meshcore-insights `src/lib/region/types.ts`. Pure Dart (no Flutter imports). Every payload carries a
// `status` (ready/partial/pending/unavailable/stale + reason); unknown values are null, never a fake zero.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

enum RegionDataState { ready, partial, pending, unavailable, stale }

RegionDataState _stateFrom(Object? v) => switch (v) {
  'ready' => RegionDataState.ready,
  'partial' => RegionDataState.partial,
  'pending' => RegionDataState.pending,
  'stale' => RegionDataState.stale,
  _ => RegionDataState.unavailable,
};

class RegionDataStatus {
  final RegionDataState state;
  final String? reason;
  final DateTime? computedAt;
  final String? source;
  const RegionDataStatus({
    required this.state,
    this.reason,
    this.computedAt,
    this.source,
  });

  factory RegionDataStatus.fromJson(Object? j) {
    if (j is! Map) {
      return const RegionDataStatus(
        state: RegionDataState.unavailable,
        reason: 'The server sent no status.',
      );
    }
    return RegionDataStatus(
      state: _stateFrom(j['state']),
      reason: _str(j['reason']),
      computedAt: _time(j['computedAt']),
      source: _str(j['source']),
    );
  }
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
int? _int(Object? v) => v is num ? v.toInt() : null;
double? _dbl(Object? v) => v is num ? v.toDouble() : null;
DateTime? _time(Object? v) =>
    v is String ? DateTime.tryParse(v)?.toUtc() : null;

class HourlyCount {
  final DateTime at;
  final int n;
  const HourlyCount(this.at, this.n);
}

class RegionEvent {
  final String type;
  final String? key;
  final String detail;
  final DateTime? at;
  const RegionEvent({
    required this.type,
    this.key,
    required this.detail,
    this.at,
  });
}

class RegionOverview {
  final RegionDataStatus status;
  final int? packets24h;
  final int? observersOnline;
  final int? observersTotal;
  final int? repeaters;
  final int? repeatersHeard24h;
  final List<HourlyCount> packetsPerHour;
  final DateTime? lastPacketAt;
  final List<RegionEvent> recentEvents;
  const RegionOverview({
    required this.status,
    this.packets24h,
    this.observersOnline,
    this.observersTotal,
    this.repeaters,
    this.repeatersHeard24h,
    this.packetsPerHour = const [],
    this.lastPacketAt,
    this.recentEvents = const [],
  });

  factory RegionOverview.fromJson(Map<String, dynamic> j) {
    final hours = <HourlyCount>[];
    final ph = j['packetsPerHour'];
    if (ph is List) {
      for (final e in ph) {
        if (e is Map) {
          final at = _time(e['at']);
          if (at != null) hours.add(HourlyCount(at, _int(e['n']) ?? 0));
        }
      }
    }
    final events = <RegionEvent>[];
    final ev = j['recentEvents'];
    if (ev is List) {
      for (final e in ev) {
        if (e is Map && e['detail'] is String) {
          events.add(
            RegionEvent(
              type: _str(e['type']) ?? '',
              key: _str(e['key']),
              detail: e['detail'] as String,
              at: _time(e['at']),
            ),
          );
        }
      }
    }
    return RegionOverview(
      status: RegionDataStatus.fromJson(j['status']),
      packets24h: _int(j['packets24h']),
      observersOnline: _int(j['observersOnline']),
      observersTotal: _int(j['observersTotal']),
      repeaters: _int(j['repeaters']),
      repeatersHeard24h: _int(j['repeatersHeard24h']),
      packetsPerHour: hours,
      lastPacketAt: _time(j['lastPacketAt']),
      recentEvents: events,
    );
  }
}

class RegionObserver {
  final String key;
  final String? name;
  final bool online;
  final DateTime? lastPacketAt;
  final DateTime? lastStatusAt;
  final int? packetsPerHour;
  final double? noiseFloorDbm;
  final String? model;
  final String? firmware;
  final int? batteryMv;
  final double? lat, lon;
  final int? nodesHeard24h;
  final bool trusted;

  /// `meshsonar` (our own observer) or `corescope` (third-party view).
  final String source;
  const RegionObserver({
    required this.key,
    this.name,
    required this.online,
    this.lastPacketAt,
    this.lastStatusAt,
    this.packetsPerHour,
    this.noiseFloorDbm,
    this.model,
    this.firmware,
    this.batteryMv,
    this.lat,
    this.lon,
    this.nodesHeard24h,
    this.trusted = false,
    this.source = 'corescope',
  });

  /// Most recent sign of life (packet or status report).
  DateTime? get lastSeen {
    final a = lastPacketAt, b = lastStatusAt;
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String get displayName =>
      name ?? '${key.substring(0, key.length < 8 ? key.length : 8)}…';

  static RegionObserver? tryParse(Object? v) {
    if (v is! Map || v['key'] is! String) return null;
    return RegionObserver(
      key: v['key'] as String,
      name: _str(v['name']),
      online: v['online'] == true,
      lastPacketAt: _time(v['lastPacketAt']),
      lastStatusAt: _time(v['lastStatusAt']),
      packetsPerHour: _int(v['packetsPerHour']),
      noiseFloorDbm: _dbl(v['noiseFloorDbm']),
      model: _str(v['model']),
      firmware: _str(v['firmware']),
      batteryMv: _int(v['batteryMv']),
      lat: _dbl(v['lat']),
      lon: _dbl(v['lon']),
      nodesHeard24h: _int(v['nodesHeard24h']),
      trusted: v['trusted'] == true,
      source: _str(v['source']) ?? 'corescope',
    );
  }
}

class RegionObservers {
  final RegionDataStatus status;
  final List<RegionObserver> rows;
  const RegionObservers({required this.status, required this.rows});

  factory RegionObservers.fromJson(Map<String, dynamic> j) {
    final rows = <RegionObserver>[];
    final r = j['rows'];
    if (r is List) {
      for (final e in r) {
        final o = RegionObserver.tryParse(e);
        if (o != null) rows.add(o);
      }
    }
    return RegionObservers(
      status: RegionDataStatus.fromJson(j['status']),
      rows: rows,
    );
  }
}

class RegionApiException implements Exception {
  final String message;
  const RegionApiException(this.message);
  @override
  String toString() => message;
}

class RegionOverviewApi {
  final String baseUrl;
  final http.Client _client;
  final Duration timeout;
  RegionOverviewApi(
    this.baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 15),
  }) : _client = client ?? newRegionWireClient();

  Uri endpoint(String name) {
    final b = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$b/api/cmh/$name');
  }

  Future<RegionOverview> overview() async =>
      RegionOverview.fromJson(await _get('region-overview'));

  Future<RegionObservers> observers() async =>
      RegionObservers.fromJson(await _get('region-observers'));

  Future<Map<String, dynamic>> _get(String name) async {
    final http.Response res;
    try {
      res = await _client
          .get(endpoint(name), headers: const {'accept': 'application/json'})
          .timeout(timeout);
    } on TimeoutException {
      throw const RegionApiException('The server took too long to answer.');
    } catch (_) {
      throw const RegionApiException(
        'Could not reach the server. Check your connection.',
      );
    }
    if (res.statusCode != 200) {
      String? msg;
      try {
        final b = jsonDecode(res.body);
        if (b is Map && b['error'] is String) msg = b['error'] as String;
      } catch (_) {}
      throw RegionApiException(msg ?? 'The server answered ${res.statusCode}.');
    }
    try {
      final b = jsonDecode(utf8.decode(res.bodyBytes));
      if (b is Map<String, dynamic>) return b;
    } catch (_) {}
    throw const RegionApiException('The server sent something unreadable.');
  }

  void close() => _client.close();
}
