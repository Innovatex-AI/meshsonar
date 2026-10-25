// Read-only client for a region's public report and external-source coverage: `region-report` and `region-sources`
// (shapes: meshcore-insights src/lib/region/types.ts, RegionReport and RegionSources). Both are public GETs on
// `<region host>/api/cmh/...`, no key: the server picks the region from the HOST (day.meshsonar.com answers DAY under
// `/api/cmh/`), like every other region client. `/api/<slug>/` is 404 for every slug but cmh (checked live Oct 24). Parsing is defensive: a missing or oddly typed field becomes null (never a made-up
// zero), and every section keeps the server's own `status` so the UI can say "partial" or "pending" honestly.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

/// The server's per-dataset state (`Sourced.state`), plus [unknown] for a value this app does not know.
enum DataState { ready, partial, pending, unavailable, stale, unknown }

class DataStatus {
  final DataState state;
  final String? reason;
  final String? source;
  const DataStatus(this.state, {this.reason, this.source});

  /// Something other than a clean "ready".
  bool get degraded => state != DataState.ready;

  static DataStatus parse(Object? j) {
    if (j is! Map) return const DataStatus(DataState.unknown);
    final s = j['state'];
    final state = DataState.values.firstWhere((e) => e.name == s && e != DataState.unknown, orElse: () => DataState.unknown);
    return DataStatus(state, reason: _str(j['reason']), source: _str(j['source']));
  }
}

class TimeCount {
  final DateTime at;
  final int n;
  const TimeCount(this.at, this.n);
}

class RegionEvent {
  final String type;
  final String detail;
  final DateTime? at;
  const RegionEvent({required this.type, required this.detail, this.at});
}

class RepeaterCounts {
  final int? active, quiet, fresh, stale;
  const RepeaterCounts({this.active, this.quiet, this.fresh, this.stale});
}

class HashSize {
  final int bytes;
  final int nodes;
  const HashSize(this.bytes, this.nodes);
}

class RegionReportData {
  final String slug, name, code;
  final DateTime? generatedAt;

  // Overview (last 24 h).
  final DataStatus overviewStatus;
  final int? packets24h, observersOnline, observersTotal, repeaters, repeatersHeard24h;
  final DateTime? lastPacketAt;
  final List<TimeCount> packetsPerHour;
  final List<RegionEvent> events;

  // Repeater health.
  final DataStatus repeatersStatus;
  final RepeaterCounts repeaterCounts;

  // Trend: packets per day (or hour) over the last weeks.
  final DataStatus activityStatus;
  final String activityBucket;
  final List<TimeCount> activity;

  // Network: hash sizes, flood share, median noise floor across observers.
  final DataStatus hashStatus;
  final List<HashSize> hashSizes;
  final int? hashCollisions;
  final DataStatus pathsStatus;
  final double? floodShare;
  final DataStatus rfStatus;
  final double? noiseMeanDbm;

  // Coverage (no status of its own: all null means "not measured yet").
  final int? coverageCells, coverageDrives;
  final double? coverageKm, coverageHeardPct;

  const RegionReportData({
    required this.slug,
    required this.name,
    required this.code,
    this.generatedAt,
    this.overviewStatus = const DataStatus(DataState.unknown),
    this.packets24h,
    this.observersOnline,
    this.observersTotal,
    this.repeaters,
    this.repeatersHeard24h,
    this.lastPacketAt,
    this.packetsPerHour = const [],
    this.events = const [],
    this.repeatersStatus = const DataStatus(DataState.unknown),
    this.repeaterCounts = const RepeaterCounts(),
    this.activityStatus = const DataStatus(DataState.unknown),
    this.activityBucket = 'day',
    this.activity = const [],
    this.hashStatus = const DataStatus(DataState.unknown),
    this.hashSizes = const [],
    this.hashCollisions,
    this.pathsStatus = const DataStatus(DataState.unknown),
    this.floodShare,
    this.rfStatus = const DataStatus(DataState.unknown),
    this.noiseMeanDbm,
    this.coverageCells,
    this.coverageDrives,
    this.coverageKm,
    this.coverageHeardPct,
  });

  bool get coverageKnown => coverageCells != null || coverageDrives != null || coverageKm != null || coverageHeardPct != null;

  /// A report with no figures at all: the region exists but has nothing measured yet.
  bool get isEmpty =>
      packets24h == null && repeaters == null && observersTotal == null && activity.isEmpty && events.isEmpty && !coverageKnown;

  static RegionReportData parse(Map<String, dynamic> j) {
    final region = _map(j['region']);
    final ov = _map(j['overview']);
    final rep = _map(j['repeaters']);
    final counts = _map(rep['counts']);
    final act = _map(j['activity']);
    final hash = _map(j['hash']);
    final paths = _map(j['paths']);
    final rf = _map(j['rf']);
    final cov = _map(j['coverage']);
    final noise = <double>[
      for (final o in _list(rf['observers'])) if (_num(_map(o)['meanDbm']) != null) _num(_map(o)['meanDbm'])!.toDouble(),
    ];
    return RegionReportData(
      slug: _str(region['slug']) ?? '',
      name: _str(region['name']) ?? _str(region['slug']) ?? '',
      code: _str(region['code']) ?? '',
      generatedAt: _time(j['generatedAt']),
      overviewStatus: DataStatus.parse(ov['status']),
      packets24h: _int(ov['packets24h']),
      observersOnline: _int(ov['observersOnline']),
      observersTotal: _int(ov['observersTotal']),
      repeaters: _int(ov['repeaters']),
      repeatersHeard24h: _int(ov['repeatersHeard24h']),
      lastPacketAt: _time(ov['lastPacketAt']),
      packetsPerHour: _timeCounts(ov['packetsPerHour']),
      events: [
        for (final e in _list(ov['recentEvents']))
          if (_str(_map(e)['detail']) != null)
            RegionEvent(type: _str(_map(e)['type']) ?? '', detail: _str(_map(e)['detail'])!, at: _time(_map(e)['at'])),
      ],
      repeatersStatus: DataStatus.parse(rep['status']),
      repeaterCounts: RepeaterCounts(
          active: _int(counts['active']), quiet: _int(counts['quiet']), fresh: _int(counts['new']), stale: _int(counts['stale'])),
      activityStatus: DataStatus.parse(act['status']),
      activityBucket: _str(act['bucket']) ?? 'day',
      activity: [
        for (final r in _list(act['rows']))
          if (_time(_map(r)['at']) != null && _int(_map(r)['total']) != null) TimeCount(_time(_map(r)['at'])!, _int(_map(r)['total'])!),
      ],
      hashStatus: DataStatus.parse(hash['status']),
      hashSizes: [
        for (final h in _list(hash['sizes']))
          if (_int(_map(h)['bytes']) != null && _int(_map(h)['nodes']) != null) HashSize(_int(_map(h)['bytes'])!, _int(_map(h)['nodes'])!),
      ],
      hashCollisions: hash['collisions'] is List ? (hash['collisions'] as List).length : null,
      pathsStatus: DataStatus.parse(paths['status']),
      floodShare: _num(paths['floodShare'])?.toDouble(),
      rfStatus: DataStatus.parse(rf['status']),
      noiseMeanDbm: noise.isEmpty ? null : noise.reduce((a, b) => a + b) / noise.length,
      coverageCells: _int(cov['cells']),
      coverageDrives: _int(cov['drives']),
      coverageKm: _num(cov['km'])?.toDouble(),
      coverageHeardPct: _num(cov['heardPct'])?.toDouble(),
    );
  }
}

/// One external source (CoreScope instance, MeshCore Map, ...) and what it contributes to THIS region.
class RegionSource {
  final String name, adapter;
  final int nodes, observers, edges;
  final bool enabled, stale, prototypeOnly;
  final DateTime? lastOkAt;
  final String? attribution, attributionUrl, lastError;
  const RegionSource({
    required this.name,
    required this.adapter,
    required this.nodes,
    required this.observers,
    required this.edges,
    required this.enabled,
    required this.stale,
    required this.prototypeOnly,
    this.lastOkAt,
    this.attribution,
    this.attributionUrl,
    this.lastError,
  });

  /// "CoreScope", "MeshCore Map", or the adapter id for one this app has not met.
  String get kindLabel => switch (adapter) {
        'corescope' => 'CoreScope',
        'meshcore-map' => 'MeshCore Map',
        'hub' => 'MeshCore Hub',
        'livemap' => 'Live map',
        _ => adapter.isEmpty ? 'Other' : adapter,
      };

  /// Never pulled successfully: the counts are zeros because nothing has arrived, not because the region is empty.
  bool get neverSucceeded => lastOkAt == null;
}

class RegionSourcesData {
  final DataStatus status;
  final List<RegionSource> sources;
  const RegionSourcesData(this.status, this.sources);

  static RegionSourcesData parse(Map<String, dynamic> j) => RegionSourcesData(
        DataStatus.parse(j['status']),
        [
          for (final s in _list(j['sources']))
            if (_str(_map(s)['name']) != null)
              RegionSource(
                name: _str(_map(s)['name'])!,
                adapter: _str(_map(s)['adapter']) ?? '',
                nodes: _int(_map(s)['nodes']) ?? 0,
                observers: _int(_map(s)['observers']) ?? 0,
                edges: _int(_map(s)['edges']) ?? 0,
                enabled: _map(s)['enabled'] != false,
                stale: _map(s)['stale'] == true,
                prototypeOnly: _map(s)['prototypeOnly'] == true,
                lastOkAt: _time(_map(s)['lastOkAt']),
                attribution: _str(_map(s)['attribution']),
                attributionUrl: _str(_map(s)['attributionUrl']),
                lastError: _str(_map(s)['lastError']),
              ),
        ],
      );
}

enum FetchErrorKind { notFound, network, server, badResponse }

class RegionFetchError {
  final FetchErrorKind kind;
  final String message;
  final int? status;
  const RegionFetchError(this.kind, this.message, {this.status});
  @override
  String toString() => message;
}

/// Either [data] or [error], never both.
class FetchResult<T> {
  final T? data;
  final RegionFetchError? error;

  /// Set when [data] is the copy stored on the phone, served because the network failed: when it was fetched.
  final DateTime? offlineAsOf;
  const FetchResult.ok(T this.data, {this.offlineAsOf}) : error = null;
  const FetchResult.fail(RegionFetchError this.error)
      : data = null,
        offlineAsOf = null;
  bool get ok => data != null;
}

class RegionReportsApi {
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;

  RegionReportsApi(String baseUrl, {http.Client? client, this.timeout = const Duration(seconds: 25)})
      : baseUrl = Uri.parse(baseUrl.trim()),
        _http = client ?? newRegionWireClient();

  /// `<baseUrl>/api/cmh/<name>`. The path segment is the API namespace, not the region: [baseUrl] is the region's own
  /// host and the server scopes by host.
  Uri endpoint(String name) {
    var path = baseUrl.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return baseUrl.replace(path: '$path/api/cmh/$name', query: null, fragment: null);
  }

  Future<FetchResult<RegionReportData>> fetchReport(String slug) =>
      _get(slug, 'region-report', (m) => RegionReportData.parse(m));

  Future<FetchResult<RegionSourcesData>> fetchSources(String slug) =>
      _get(slug, 'region-sources', (m) => RegionSourcesData.parse(m));

  Future<FetchResult<T>> _get<T extends Object>(String slug, String name, T Function(Map<String, dynamic>) parse) async {
    http.Response res;
    try {
      res = await _http.get(endpoint(name), headers: {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.network, 'timed out talking to ${baseUrl.host}'));
    } on SocketException catch (e) {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.network, 'network error: ${e.message}'));
    } on http.ClientException catch (e) {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.network, 'network error: ${e.message}'));
    } on HandshakeException catch (e) {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.network, 'secure connection failed: ${e.message}'));
    }
    if (res.statusCode == 404) {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.notFound, 'not published for this region', status: 404));
    }
    if (res.statusCode != 200) {
      return FetchResult.fail(RegionFetchError(FetchErrorKind.server, 'server answered ${res.statusCode}', status: res.statusCode));
    }
    try {
      final decoded = jsonDecode(utf8.decode(res.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw const FormatException('not an object');
      return FetchResult.ok(parse(decoded), offlineAsOf: offlineAsOfOf(res));
    } catch (_) {
      return const FetchResult.fail(RegionFetchError(FetchErrorKind.badResponse, 'the server sent something unreadable'));
    }
  }

  void close() => _http.close();
}

// ---------------------------------------------------------------- tolerant readers
Map<String, dynamic> _map(Object? o) => o is Map<String, dynamic> ? o : const {};
List<Object?> _list(Object? o) => o is List ? o : const [];
String? _str(Object? o) => o is String && o.isNotEmpty ? o : null;
num? _num(Object? o) => o is num && o.isFinite ? o : null;
int? _int(Object? o) => _num(o)?.round();
DateTime? _time(Object? o) => o is String ? DateTime.tryParse(o)?.toUtc() : null;
List<TimeCount> _timeCounts(Object? o) => [
      for (final r in _list(o))
        if (_time(_map(r)['at']) != null && _int(_map(r)['n']) != null) TimeCount(_time(_map(r)['at'])!, _int(_map(r)['n'])!),
    ];
