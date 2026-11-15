// The server calls the Plan tools make, all on the website's own public endpoints (no driver key, no account):
//   POST /api/cmh/score-link   {a,b,haM,hbM}  -> elevation profile + terrain odds   (capability `linkScore`)
//   POST /api/cmh/coverage     {mode:"coverage",lat,lon,antennaFt,...} -> modelled footprint (capability `coveragePainter`)
//   POST /api/cmh/plan-link | plan-verify | plan-suggest (release 0.38 Master Planner, lib/core/plan_contract.dart) through
//        the CmatClient methods, wrapped by [PlanApi] with the same offline fallback ([planClientCall]); plan-link also
//        falls back to the on-device model (link_model.dart localPlanLink) over score-link's profile, so a link is judged
//        on a server without the planner yet, or offline from a stored profile.
// (The airtime-load read left the app in M0, Nov 8 2026: no region served it.)
// Each goes through [planCall]: a good answer is stored (PlanStore) and a network failure or a 5xx serves the stored
// answer for the same request flagged `offline`; a 4xx (bad input, "no boundary") is the server's sentence and never
// falls back. Sent: coordinates the person typed or picked on the tool, never their drive position, never an identifier.
// Pure Dart.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api.dart' show CmatClient, CmatException;
import '../plan_contract.dart';
import 'link_model.dart' show localPlanLink;
import 'plan_store.dart';

/// An answer (or the sentence explaining why not), with the time a stored copy was fetched when it is one.
class PlanResult<T> {
  final T? data;
  final String? error;

  /// Set when [data] is the stored copy because the server could not be reached.
  final DateTime? offlineAsOf;

  /// When the answer was fetched (now for a live one).
  final DateTime? at;

  /// The answer was computed on this phone (link_model.dart) from a terrain profile, not by the planner endpoint.
  final bool onDevice;
  const PlanResult.ok(T this.data, {this.offlineAsOf, this.at, this.onDevice = false})
      : error = null,
        unavailable = false;
  const PlanResult.fail(String this.error, {this.unavailable = false})
      : data = null,
        offlineAsOf = null,
        at = null,
        onDevice = false;

  /// A failure because the endpoint could not be reached or does not exist there (no stored copy either), as opposed
  /// to the server refusing the input: another source may still answer.
  final bool unavailable;
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
    return PlanResult.fail(why, unavailable: true);
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
  if (res.statusCode == 404) return PlanResult.fail(_sentence(res) ?? 'This server does not offer that tool.', unavailable: true);
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

// ================================================================ Master Planner endpoints (release 0.38)
/// FNV-1a 64-bit of [s], hex: a stable, file-name-safe cache key for a whole request body.
String planKeyHash(String s) {
  var h = 0xcbf29ce484222325;
  for (final c in utf8.encode(s)) {
    h ^= c;
    h *= 0x100000001b3; // wraps at 64 bits
  }
  // Two 32-bit halves: a native int is signed, so the top bit would print as a minus sign.
  String half(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${half(h >> 32)}${half(h)}';
}

/// [planCall] for the typed CmatClient planner methods: a good answer is stored (as its contract JSON, [encode]) and a
/// network failure, a timeout or a 5xx serves the stored answer for the same request flagged `offline`; a 4xx is the
/// server's sentence and never falls back.
Future<PlanResult<T>> planClientCall<T>({
  required PlanStore store,
  required String cacheKey,
  required Future<T> Function() call,
  required Map<String, dynamic> Function(T data) encode,
  required T Function(Map<String, dynamic> json) parse,
  DateTime Function()? clock,
}) async {
  final now = (clock ?? DateTime.now)().toUtc();
  Future<PlanResult<T>> stored(String why) async => await planStored<T>(store, cacheKey, parse) ?? PlanResult.fail(why, unavailable: true);
  final T data;
  try {
    data = await call();
  } on CmatException catch (e) {
    final st = e.status;
    if (st == null) {
      if (e.message.contains('not supported')) return stored('This server does not offer the planner yet.');
      return stored(e.message.startsWith('timed out') ? 'The server took too long to answer.' : 'No connection to the server.');
    }
    if (st == 501) return stored('This server does not offer the planner yet.');
    if (st >= 500) return stored('The server could not answer right now ($st).');
    if (st == 404) return const PlanResult.fail('This server does not offer that tool.', unavailable: true);
    if (st == 429) {
      final wait = e.retryAfterSec;
      return PlanResult.fail(wait == null ? 'Too many requests from this connection. Wait a minute and try again.' : 'Too many requests from this connection. Try again in $wait s.');
    }
    if (st == 200) return const PlanResult.fail('The server sent something unreadable.');
    return PlanResult.fail(e.message);
  } on FormatException {
    return const PlanResult.fail('The server sent something unreadable.');
  } on TypeError {
    return const PlanResult.fail('The server sent something unreadable.');
  }
  try {
    await store.write(cacheKey, jsonEncode(encode(data)));
  } catch (_) {
    // A full disk only costs the offline copy.
  }
  return PlanResult.ok(data, at: now);
}

// ---------------------------------------------------------------- contract JSON of the answers (what is stored)
String? _iso(DateTime? t) => t?.toUtc().toIso8601String();

Map<String, dynamic> provenanceJson(PlanProvenance p) => {
      'model': p.model,
      'terrain': p.terrain,
      'asOf': ?_iso(p.asOf),
      'confidence': {'level': p.confidence.wire, 'note': ?p.confidenceNote},
    };

Map<String, dynamic> planLinkResultJson(PlanLinkResult r) => {
      'km': r.km,
      'profile': {'distanceKm': r.profile.distanceKm, 'groundM': r.profile.groundM},
      'fresnelClearancePct': ?r.fresnelClearancePct,
      if (r.tightest != null) 'tightest': {'km': r.tightest!.km, 'raiseM': r.tightest!.raiseM},
      if (r.ridge != null) 'ridge': {'km': r.ridge!.km, 'lat': ?r.ridge!.at?.lat, 'lon': ?r.ridge!.at?.lon, 'groundM': ?r.ridge!.groundM},
      'odds': ?r.odds,
      'verdict': ?r.verdict?.wire,
      'marginDb': ?r.marginDb,
      if (r.measured != null)
        'measured': {'echoes': r.measured!.echoes, 'meanSnr': ?r.measured!.meanSnr, 'lastAt': ?_iso(r.measured!.lastAt), 'source': r.measured!.source},
      ...provenanceJson(r.provenance),
      'cached': r.cached,
    };

Map<String, dynamic> planVerifyResultJson(PlanVerifyResult r) => r.raw.isNotEmpty
    ? r.raw
    : {
        'coveredKm2': r.coveredKm2,
        'bands': [for (final b in r.bands) {'id': b.id, 'label': b.label, 'areaKm2': b.areaKm2}],
        'links': [for (final l in r.links) {'publicKey': l.publicKey, 'name': l.name, 'km': l.km, 'marginDb': l.marginDb}],
        'newAreaKm2': ?r.newAreaKm2,
        'newPeople': ?r.newPeople,
        ...provenanceJson(r.provenance),
        'cached': r.cached,
      };

Map<String, dynamic> planSuggestResultJson(PlanSuggestResult r) => {
      'pool': r.pool,
      'preparing': r.preparing,
      'notes': r.notes,
      'sites': [
        for (final s in r.sites)
          {
            'id': s.id,
            'lat': s.at.lat,
            'lon': s.at.lon,
            'groundM': ?s.groundM,
            'heightAboveM': ?s.heightAboveM,
            'kind': s.kind,
            'mount': ?s.mount?.wire,
            if (s.osmId != null || s.osmOperator != null) 'osm': {'id': ?s.osmId, 'operator': ?s.osmOperator},
            'score': s.score,
            'reason': s.reason,
            'gain': {
              'newAreaKm2': ?s.gain.newAreaKm2,
              'newPeople': ?s.gain.newPeople,
              'newLinks': [
                for (final l in s.gain.newLinks) {'key': l.key, 'name': l.name, 'km': l.km, 'odds': ?l.odds, 'tier': ?l.tier},
              ],
              'redundancy': s.gain.redundancy.wire,
              'spofName': ?s.gain.spofName,
            },
            'evidence': {'deadZoneDrives': s.deadZoneDrives},
          },
      ],
      ...provenanceJson(r.provenance),
      'cached': r.cached,
    };

/// The Master Planner calls with their offline fallback. plan-link falls back once more, to the on-device model over
/// score-link's terrain profile ([scoreLink], which has its own stored copies), when the planner endpoint cannot answer.
class PlanApi {
  final CmatClient client;
  final PlanStore store;
  final ScoreLinkApi? scoreLink;
  final DateTime Function()? clock;
  PlanApi(this.client, this.store, {this.scoreLink, this.clock});

  static String linkKey(PlanLinkRequest r) => 'plink_${planKeyHash(jsonEncode(r.toJson()))}';
  static String verifyKey(PlanVerifyRequest r) => 'pverify_${planKeyHash(jsonEncode(r.toJson()))}';
  static String suggestKey(PlanSuggestRequest r) => 'psuggest_${planKeyHash(jsonEncode(r.toJson()))}';

  /// One link A-B. Per-end power/gain are for the on-device fallback (the endpoint takes the defaults).
  Future<PlanResult<PlanLinkResult>> link(
    PlanLinkRequest r, {
    double aTxDbm = 22,
    double bTxDbm = 22,
    double aGainDbi = 3,
    double bGainDbi = 3,
  }) async {
    final res = await planClientCall<PlanLinkResult>(
      store: store,
      cacheKey: linkKey(r),
      call: () => client.planLink(r),
      encode: planLinkResultJson,
      parse: PlanLinkResult.parse,
      clock: clock,
    );
    // A 4xx is the server's verdict on the input: do not second-guess it with the phone's model.
    if (res.ok || !res.unavailable || scoreLink == null) return res;
    final p = await scoreLink!.profile(r.a.lat, r.a.lon, r.b.lat, r.b.lon);
    if (!p.ok) return res;
    final prof = p.data!;
    return PlanResult.ok(
      localPlanLink(r, prof.groundM, km: prof.km, aTxDbm: aTxDbm, bTxDbm: bTxDbm, aGainDbi: aGainDbi, bGainDbi: bGainDbi, terrain: prof.source, asOf: p.at),
      at: p.at,
      offlineAsOf: p.offlineAsOf,
      onDevice: true,
    );
  }

  Future<PlanResult<PlanVerifyResult>> verify(PlanVerifyRequest r) => planClientCall<PlanVerifyResult>(
        store: store,
        cacheKey: verifyKey(r),
        call: () => client.planVerify(r),
        encode: planVerifyResultJson,
        parse: PlanVerifyResult.parse,
        clock: clock,
      );

  /// Find sites stage 2: verifies [sites] one after the other (the server runs one verify at a time anyway), at most
  /// [maxVerify] (the plan's top 5).
  Future<List<PlanResult<PlanVerifyResult>>> verifyMany(Iterable<PlanVerifyRequest> sites, {int maxVerify = 5}) async => [
        for (final r in sites.take(maxVerify)) await verify(r),
      ];

  Future<PlanResult<PlanSuggestResult>> suggest(PlanSuggestRequest r) => planClientCall<PlanSuggestResult>(
        store: store,
        cacheKey: suggestKey(r),
        call: () => client.planSuggest(r),
        encode: planSuggestResultJson,
        parse: PlanSuggestResult.parse,
        clock: clock,
      );

  /// The bare-earth profile between two points (score-link when there is one, else plan-link's own profile), for the
  /// on-device link matrix and relay finder.
  Future<PlanResult<ScoredProfile>> profile(PlanPoint a, PlanPoint b) async {
    final s = scoreLink;
    if (s != null) {
      final p = await s.profile(a.lat, a.lon, b.lat, b.lon);
      if (p.ok) return p;
    }
    final l = await link(PlanLinkRequest(a: a, b: b));
    if (!l.ok) return PlanResult.fail(l.error ?? 'No terrain profile.');
    final pr = l.data!.profile;
    return PlanResult.ok(
      ScoredProfile(km: l.data!.km, groundM: pr.groundM, distKm: pr.distanceKm, source: l.data!.provenance.terrain),
      at: l.at,
      offlineAsOf: l.offlineAsOf,
    );
  }
}
