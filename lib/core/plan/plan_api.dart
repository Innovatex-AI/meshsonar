// The three server calls the Plan tools make, all on the website's own public endpoints (no driver key, no account):
//   POST /api/cmh/score-link   {a,b,haM,hbM}  -> elevation profile + terrain odds   (capability `linkScore`)
//   POST /api/cmh/coverage     {mode:"coverage",lat,lon,antennaFt,...} -> modelled footprint (capability `coveragePainter`)
//   GET  /api/cmh/airtime-load ?hours=        -> the region's observed channel load (capability `airtimeLoad`)
// Each goes through [planCall]: a good answer is stored (PlanStore) and a network failure or a 5xx serves the stored
// answer for the same request flagged `offline`; a 4xx (bad input, "no boundary") is the server's sentence and never
// falls back. Sent: coordinates the person typed or picked on the tool, never their drive position, never an identifier.
// Pure Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'airtime_calc.dart' show LoadMix;
import 'plan_store.dart';

/// An answer (or the sentence explaining why not), with the time a stored copy was fetched when it is one.
class PlanResult<T> {
  final T? data;
  final String? error;

  /// Set when [data] is the stored copy because the server could not be reached.
  final DateTime? offlineAsOf;

  /// When the answer was fetched (now for a live one).
  final DateTime? at;
  const PlanResult.ok(T this.data, {this.offlineAsOf, this.at}) : error = null;
  const PlanResult.fail(String this.error)
      : data = null,
        offlineAsOf = null,
        at = null;
  bool get ok => data != null;
}

/// The stored answer for [cacheKey] without asking the server (null when none or unreadable): shown at once while a fresh
/// ask is in flight, so a tool never opens on an empty screen when it has something to show.
Future<PlanResult<T>?> planStored<T>(PlanStore store, String cacheKey, T Function(Map<String, dynamic> json) parse) async {
  final s = await store.read(cacheKey);
  if (s == null) return null;
  try {
    final j = jsonDecode(s.body);
    if (j is Map<String, dynamic>) return PlanResult.ok(parse(j), offlineAsOf: s.at, at: s.at);
  } catch (_) {}
  return null;
}

Uri planEndpoint(String baseUrl, String name, [Map<String, String>? query]) {
  final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final u = Uri.parse('$b/api/cmh/$name');
  return query == null || query.isEmpty ? u : u.replace(queryParameters: query);
}

/// Runs [send] (a request returning the raw response), parses and stores a 200, falls back to the stored copy for
/// [cacheKey] on a network failure or 5xx.
Future<PlanResult<T>> planCall<T>({
  required PlanStore store,
  required String cacheKey,
  required Future<http.Response> Function() send,
  required T Function(Map<String, dynamic> json) parse,
  DateTime Function()? clock,
}) async {
  final now = (clock ?? DateTime.now)().toUtc();
  Future<PlanResult<T>> stored(String why) async {
    final s = await store.read(cacheKey);
    if (s != null) {
      try {
        final j = jsonDecode(s.body);
        if (j is Map<String, dynamic>) return PlanResult.ok(parse(j), offlineAsOf: s.at, at: s.at);
      } catch (_) {}
    }
    return PlanResult.fail(why);
  }

  final http.Response res;
  try {
    res = await send();
  } on TimeoutException {
    return stored('The server took too long to answer.');
  } on SocketException {
    return stored('No connection to the server.');
  } on http.ClientException {
    return stored('No connection to the server.');
  } on HandshakeException {
    return stored('The secure connection to the server failed.');
  }
  if (res.statusCode >= 500) {
    return stored(_sentence(res) ?? 'The server could not answer right now (${res.statusCode}).');
  }
  if (res.statusCode == 404) return PlanResult.fail(_sentence(res) ?? 'This server does not offer that tool.');
  if (res.statusCode == 429) return const PlanResult.fail('Too many requests from this connection. Wait a minute and try again.');
  if (res.statusCode != 200) return PlanResult.fail(_sentence(res) ?? 'The server answered ${res.statusCode}.');
  try {
    final body = utf8.decode(res.bodyBytes);
    final j = jsonDecode(body);
    if (j is! Map<String, dynamic>) return const PlanResult.fail('The server sent something unreadable.');
    final data = parse(j);
    await store.write(cacheKey, body);
    return PlanResult.ok(data, at: now);
  } catch (_) {
    return const PlanResult.fail('The server sent something unreadable.');
  }
}

String? _sentence(http.Response r) {
  try {
    final b = jsonDecode(utf8.decode(r.bodyBytes));
    if (b is Map && b['error'] is String && (b['error'] as String).isNotEmpty) return b['error'] as String;
  } catch (_) {}
  return null;
}

double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
int? _i(Object? v) => v is num && v.isFinite ? v.round() : null;
String? _s(Object? v) => v is String && v.isNotEmpty ? v : null;
Map<String, dynamic> _m(Object? v) => v is Map<String, dynamic> ? v : const {};
List<Map<String, dynamic>> _ms(Object? v) => v is List ? [for (final e in v) if (e is Map<String, dynamic>) e] : const [];

// ================================================================ score-link
class ScoredProfile {
  final double km;

  /// Ground elevation (m above sea level) at evenly spaced points from A to B, and each point's distance from A (km).
  final List<double> groundM, distKm;
  final String source;

  /// What the server itself computed for the heights asked (the app recomputes locally from the profile).
  final double? serverOdds, serverBullDb;
  const ScoredProfile({required this.km, required this.groundM, required this.distKm, required this.source, this.serverOdds, this.serverBullDb});

  static ScoredProfile parse(Map<String, dynamic> j) {
    final p = _m(j['profile']);
    final g = [for (final v in (p['groundM'] as List)) (v as num).toDouble()];
    final d = [for (final v in (p['distanceKm'] as List)) (v as num).toDouble()];
    if (g.length < 3 || g.length != d.length) throw const FormatException('profile');
    final km = _n(j['km']) ?? d.last;
    return ScoredProfile(
      km: km,
      groundM: g,
      distKm: d,
      source: _s(j['source']) ?? 'terrain profile',
      serverOdds: _n(_m(j['terrainModel'])['odds']),
      serverBullDb: _n(j['bullingtonDb']),
    );
  }
}

class ScoreLinkApi {
  final String baseUrl;
  final PlanStore store;
  final http.Client Function() newClient;
  final Duration timeout;
  ScoreLinkApi(this.baseUrl, this.store, {http.Client Function()? client, this.timeout = const Duration(seconds: 45)}) : newClient = client ?? http.Client.new;

  /// Coordinates are rounded to 5 places (about a metre) in the request and the cache key. Heights are not sent for the
  /// profile: the app computes odds and clearance for any height from the same profile.
  static String keyFor(double aLat, double aLon, double bLat, double bLon) =>
      'link_${aLat.toStringAsFixed(5)}_${aLon.toStringAsFixed(5)}_${bLat.toStringAsFixed(5)}_${bLon.toStringAsFixed(5)}';

  Future<PlanResult<ScoredProfile>> profile(double aLat, double aLon, double bLat, double bLon) {
    String r5(double v) => v.toStringAsFixed(5);
    final c = newClient();
    return planCall<ScoredProfile>(
      store: store,
      cacheKey: keyFor(aLat, aLon, bLat, bLon),
      send: () => c
          .post(planEndpoint(baseUrl, 'score-link'),
              headers: const {'content-type': 'application/json', 'accept': 'application/json'},
              body: jsonEncode({
                'a': {'lat': double.parse(r5(aLat)), 'lon': double.parse(r5(aLon))},
                'b': {'lat': double.parse(r5(bLat)), 'lon': double.parse(r5(bLon))},
                'haM': 6,
                'hbM': 6,
              }))
          .timeout(timeout),
      parse: ScoredProfile.parse,
    ).whenComplete(c.close);
  }
}

// ================================================================ coverage painter
class BandArea {
  final String id, label;
  final double areaKm2;
  const BandArea(this.id, this.label, this.areaKm2);
}

/// One band of the modelled footprint: closed rings in lat/lon (the server sends GeoJSON MultiPolygon, lon/lat order).
class FootprintBand {
  final String id, label;
  final List<List<(double lat, double lon)>> rings;
  const FootprintBand(this.id, this.label, this.rings);
}

class PredictedLinkRow {
  final String publicKey, keyShort, name;
  final double km, marginDb;
  const PredictedLinkRow(this.publicKey, this.keyShort, this.name, this.km, this.marginDb);
}

class PainterParams {
  final double lat, lon, antennaFt, txDbm, gainDbi, radiusKm;
  final String receiver;
  const PainterParams({required this.lat, required this.lon, this.antennaFt = 33, this.txDbm = 22, this.gainDbi = 3, this.receiver = 'handheld', this.radiusKm = 10});

  Map<String, dynamic> toJson() => {
        'mode': 'coverage',
        'lat': double.parse(lat.toStringAsFixed(5)),
        'lon': double.parse(lon.toStringAsFixed(5)),
        'antennaFt': antennaFt,
        'txDbm': txDbm,
        'gainDbi': gainDbi,
        'receiver': receiver,
        'radiusKm': radiusKm,
      };

  String get cacheKey => 'paint_${lat.toStringAsFixed(5)}_${lon.toStringAsFixed(5)}_${antennaFt}_${txDbm}_${gainDbi}_${receiver}_$radiusKm';
}

class PainterResult {
  final PainterParams params;
  final List<BandArea> bands;
  final double coveredKm2;
  final List<FootprintBand> footprint;
  final List<PredictedLinkRow> links;
  final int? peopleInRadius, peopleCovered, peopleNew, liveRepeaters;
  final String terrainSource, note;
  final double groundM;
  final double sensitivityDbm;
  final bool serverCached;
  final DateTime? computedAt;
  const PainterResult({
    required this.params,
    required this.bands,
    required this.coveredKm2,
    required this.footprint,
    required this.links,
    required this.terrainSource,
    required this.note,
    required this.groundM,
    required this.sensitivityDbm,
    required this.serverCached,
    this.computedAt,
    this.peopleInRadius,
    this.peopleCovered,
    this.peopleNew,
    this.liveRepeaters,
  });

  static PainterResult parse(Map<String, dynamic> j) {
    if (j['mode'] != 'coverage') throw const FormatException('mode');
    final p = _m(j['params']);
    final params = PainterParams(
      lat: _n(p['lat'])!,
      lon: _n(p['lon'])!,
      antennaFt: _n(p['antennaFt']) ?? 33,
      txDbm: _n(p['txDbm']) ?? 22,
      gainDbi: _n(p['gainDbi']) ?? 3,
      receiver: _s(p['receiver']) ?? 'handheld',
      radiusKm: _n(p['radiusKm']) ?? 10,
    );
    final bands = [for (final b in _ms(j['bands'])) BandArea(_s(b['id']) ?? '', _s(b['label']) ?? '', _n(b['areaKm2']) ?? 0)];
    final fp = <FootprintBand>[];
    for (final f in _ms(_m(j['footprint'])['features'])) {
      final props = _m(f['properties']);
      final geom = _m(f['geometry']);
      final rings = <List<(double, double)>>[];
      if (geom['type'] == 'MultiPolygon') {
        for (final poly in (geom['coordinates'] as List)) {
          for (final ring in (poly as List)) {
            rings.add([for (final c in (ring as List)) ((c[1] as num).toDouble(), (c[0] as num).toDouble())]);
          }
        }
      }
      fp.add(FootprintBand(_s(props['band']) ?? '', _s(props['label']) ?? '', rings));
    }
    final pop = _m(j['population']);
    final model = _m(j['model']);
    return PainterResult(
      params: params,
      bands: bands,
      coveredKm2: _n(j['coveredKm2']) ?? 0,
      footprint: fp,
      links: [
        for (final l in _ms(j['links']))
          PredictedLinkRow(_s(l['publicKey']) ?? '', _s(l['keyShort']) ?? '', _s(l['name']) ?? 'Repeater', _n(l['km']) ?? 0, _n(l['marginDb']) ?? 0),
      ],
      terrainSource: _s(_m(j['terrain'])['source']) ?? 'terrain tiles',
      note: _s(model['note']) ?? 'Estimate from terrain, diffraction and clutter.',
      groundM: _n(_m(j['sweep'])['groundM']) ?? 0,
      sensitivityDbm: _n(model['sensitivityDbm']) ?? -127.5,
      serverCached: j['cached'] == true,
      computedAt: DateTime.tryParse('${j['computedAt']}')?.toUtc(),
      peopleInRadius: _i(pop['inRadius']),
      peopleCovered: _i(pop['covered']),
      peopleNew: _i(pop['newlyCovered']),
      liveRepeaters: _i(pop['liveRepeaters']),
    );
  }
}

class CoveragePainterApi {
  final String baseUrl;
  final PlanStore store;
  final http.Client Function() newClient;
  final Duration timeout;
  CoveragePainterApi(this.baseUrl, this.store, {http.Client Function()? client, this.timeout = const Duration(seconds: 90)}) : newClient = client ?? http.Client.new;

  Future<PlanResult<PainterResult>> paint(PainterParams p) {
    final c = newClient();
    return planCall<PainterResult>(
      store: store,
      cacheKey: p.cacheKey,
      send: () => c
          .post(planEndpoint(baseUrl, 'coverage'),
              headers: const {'content-type': 'application/json', 'accept': 'application/json'}, body: jsonEncode(p.toJson()))
          .timeout(timeout),
      parse: PainterResult.parse,
    ).whenComplete(c.close);
  }
}

// ================================================================ airtime load
class ObserverLoadRow {
  final String id, name;
  final int observations;
  final double airtimeS, meanPct, peakPct;
  final int hoursOver;
  final String? peakHour;

  /// The observer's airtime split the what-if scales (null when an older server sends none).
  final LoadMix? mix;
  const ObserverLoadRow(this.id, this.name, this.observations, this.airtimeS, this.meanPct, this.peakPct, this.hoursOver, this.peakHour, [this.mix]);
}

LoadMix? _mix(Object? v) {
  if (v is! Map<String, dynamic>) return null;
  List<double> arr(Object? a) => a is List ? [for (final x in a) x is num ? x.toDouble() : 0.0] : const [];
  final fixed = _n(v['fixedS']);
  if (fixed == null) return null;
  return LoadMix(fixedS: fixed, floodByHopS: arr(v['floodByHopS']), advertByHopS: arr(v['advertByHopS']));
}

class TypeLoadRow {
  final String type;
  final int transmissions;
  final double airtimeS;
  const TypeLoadRow(this.type, this.transmissions, this.airtimeS);
}

class TalkerRow {
  final String key;
  final String? name;
  final int transmissions;
  final double airtimeS, originatedS, relayedS;
  const TalkerRow(this.key, this.name, this.transmissions, this.airtimeS, this.originatedS, this.relayedS);
}

class FloodHopRow {
  final int hops, transmissions;
  final double airtimeS;
  const FloodHopRow(this.hops, this.transmissions, this.airtimeS);
}

class AirtimeLoad {
  final String region;
  final int hours;
  final double flagPct;
  final int sf, cr, packets, observations, transmissions, lastHourTransmissions;
  final double bwKHz;
  final List<ObserverLoadRow> observers;
  final List<TypeLoadRow> byType;
  final List<TalkerRow> talkers;
  final List<FloodHopRow> floodHops;
  final DateTime? generatedAt;
  final bool truncated;
  const AirtimeLoad({
    required this.region,
    required this.hours,
    required this.flagPct,
    required this.sf,
    required this.bwKHz,
    required this.cr,
    required this.packets,
    required this.observations,
    required this.transmissions,
    required this.lastHourTransmissions,
    required this.observers,
    required this.byType,
    required this.talkers,
    required this.floodHops,
    required this.truncated,
    this.generatedAt,
  });

  static AirtimeLoad parse(Map<String, dynamic> j) {
    final r = _m(j['radio']);
    final c = _m(j['counts']);
    return AirtimeLoad(
      region: _s(j['region']) ?? '',
      hours: _i(j['hours']) ?? 24,
      flagPct: _n(j['flagPct']) ?? 10,
      sf: _i(r['sf'])!,
      bwKHz: _n(r['bwKHz'])!,
      cr: _i(r['cr'])!,
      packets: _i(c['packets']) ?? 0,
      observations: _i(c['observations']) ?? 0,
      transmissions: _i(c['transmissions']) ?? 0,
      lastHourTransmissions: _i(j['lastHourTransmissions']) ?? 0,
      observers: [
        for (final o in _ms(j['observers']))
          ObserverLoadRow(_s(o['id']) ?? '', _s(o['name']) ?? 'Observer', _i(o['observations']) ?? 0, _n(o['airtimeS']) ?? 0, _n(o['meanPct']) ?? 0,
              _n(o['peakPct']) ?? 0, _i(o['hoursOver']) ?? 0, _s(o['peakHour']), _mix(o['mix'])),
      ],
      byType: [for (final t in _ms(j['byType'])) TypeLoadRow(_s(t['type']) ?? '?', _i(t['transmissions']) ?? 0, _n(t['airtimeS']) ?? 0)],
      talkers: [
        for (final t in _ms(j['talkers']))
          TalkerRow(_s(t['key']) ?? '', _s(t['name']), _i(t['transmissions']) ?? 0, _n(t['airtimeS']) ?? 0, _n(t['originatedS']) ?? 0, _n(t['relayedS']) ?? 0),
      ],
      floodHops: [for (final h in _ms(j['floodHops'])) FloodHopRow(_i(h['hops']) ?? 0, _i(h['transmissions']) ?? 0, _n(h['airtimeS']) ?? 0)],
      generatedAt: DateTime.tryParse('${j['generatedAt']}')?.toUtc(),
      truncated: _m(j['fetch'])['truncated'] == true,
    );
  }
}

class AirtimeLoadApi {
  final String baseUrl;
  final PlanStore store;
  final http.Client Function() newClient;
  final Duration timeout;
  AirtimeLoadApi(this.baseUrl, this.store, {http.Client Function()? client, this.timeout = const Duration(seconds: 75)}) : newClient = client ?? http.Client.new;

  String keyFor(int hours) => 'airtimeload_${Uri.tryParse(baseUrl)?.host ?? ''}_$hours';

  Future<PlanResult<AirtimeLoad>?> stored({int hours = 24}) => planStored(store, keyFor(hours), AirtimeLoad.parse);

  Future<PlanResult<AirtimeLoad>> load({int hours = 24}) {
    final c = newClient();
    return planCall<AirtimeLoad>(
      store: store,
      cacheKey: keyFor(hours),
      send: () => c.get(planEndpoint(baseUrl, 'airtime-load', {'hours': '$hours'}), headers: const {'accept': 'application/json'}).timeout(timeout),
      parse: AirtimeLoad.parse,
    ).whenComplete(c.close);
  }
}
