// HTTP client for the MeshSonar endpoints of CMAT (or any server implementing MeshSonar Drive Format v1):
//   <base>/api/cmh/driver-request   POST {name, callsign?, email?}      -> 201 {driverId, key, status, display}
//   <base>/api/cmh/driver-status    GET  x-driver-key                   -> {status, display}
//   <base>/api/cmh/drive-upload     POST x-driver-key, upload body      -> {sessionId, stored, duplicate, rejected, rejections[]}
//   <base>/api/cmh/drive-context    POST x-driver-key, late context     -> {session, pingsUpdated, rejected, rejections[],
//                                                                          samplesStored, samplesDuplicate, samplesRejected,
//                                                                          sampleRejections[]}      (Drive Format v1.2)
//   <base>/api/cmh/drive-context    DELETE ?category=<id>|all           -> {category, sessions, pings, samples}
//   <base>/api/cmh/driver-privacy   GET|POST x-driver-key               -> {privacy: {trimM, privacyZones[{lat,lon,radiusM,label}], scope}}
//   <base>/api/cmh/drive-status     GET  ?session= x-driver-key         -> {pings[{id,status,settled,observers,lowConfidence,via[]}]}
//   <base>/api/cmh/driver-summary   GET  x-driver-key                   -> {v:1, asOf, stats, weeks[], drives[]}  (lib/core/driver_summary.dart)
//   <base>/api/cmh/drive-repeaters  GET  x-driver-key                   -> {repeaters[{key,name,lat,lon}], at}
//   <base>/api/cmh/problem-report   POST x-driver-key, report body      -> 201 {id, status, receivedAt, redacted}
//   <base>/api/cmh/site-config      GET  (public, no driver key)        -> {region:{slug,url}, radioPreset:{name,
//                                                                          freqMHz,bwKHz,sf,cr}|null, ...}
//   <base>/api/cmh/public-coverage  GET  (public, no driver key)        -> {cells[{lat,lon,pings,heard,bestSnr,
//                                                                          medianSnr,repeaters,lastAt,h3?,
//                                                                          noiseFloor?}], asOf, grid?, totals}
//   <base>/api/cmh/regions-index   GET  (public, no driver key)        -> {regions[{code,slug,name,url,
//                                                                          bbox:[w,s,e,n]|null,boundary?}], asOf}
// Errors come back as {error} (403 also carries {status}); they're thrown as CmatException(error, status: http code).
// Network failures and timeouts are thrown as CmatException with status null.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'drive_context_wire.dart';
import 'driver_summary.dart';
import 'model.dart';
import 'region_lookup.dart';
import 'hex_cells.dart' show loadHexEngine;
import 'map_links.dart';
import 'node_claim.dart';
import 'privacy_zones.dart';
import 'repeater_reach.dart';
import 'report_body.dart' show problemReportMaxBytes;
import 'telemetry_uploader.dart';

/// One rejected ping, as reported by the server (only the first 20 are listed).
class PingRejection {
  /// Index of the ping in the uploaded `pings` list.
  final int index;
  final String? id;
  final String reason;
  const PingRejection({required this.index, required this.id, required this.reason});
}

/// [UploadResult] plus the per-ping rejection details the server sends. Returned by [HttpCmatClient.upload].
class DetailedUploadResult extends UploadResult {
  final List<PingRejection> rejections;
  final String? sessionId;

  /// Drive Format v1.2 answers only (0 / empty otherwise): the drive-context samples the server stored, already had,
  /// or refused (`sampleRejections[]`, at most 20 listed; the index is into the `samples` list that was sent).
  final int samplesStored;
  final int samplesDuplicate;
  final int samplesRejected;
  final List<SampleRejection> sampleRejections;
  DetailedUploadResult({
    required super.stored,
    required super.duplicate,
    required super.rejected,
    required this.rejections,
    this.sessionId,
    this.samplesStored = 0,
    this.samplesDuplicate = 0,
    this.samplesRejected = 0,
    this.sampleRejections = const [],
  }) : super(rejectionReasons: rejections.map((r) => r.reason).toList());
}

DriverKeyStatus parseDriverKeyStatus(Object? s) => switch (s) {
      'pending' => DriverKeyStatus.pending,
      'approved' => DriverKeyStatus.approved,
      'rejected' => DriverKeyStatus.rejected,
      'revoked' => DriverKeyStatus.revoked,
      'banned' => DriverKeyStatus.revoked, // a banned driver's key can't upload; shown like a revoked key
      'none' => DriverKeyStatus.none,
      _ => DriverKeyStatus.unknown,
    };

class HttpCmatClient implements CmatClient, TelemetryTransport {
  @override
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;
  final Duration uploadTimeout;

  HttpCmatClient(
    this.baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(seconds: 120),
  }) : _http = client ?? http.Client();

  Uri endpoint(String name) {
    var path = baseUrl.path;
    while (path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return baseUrl.replace(path: '$path/api/cmh/$name', query: null, fragment: null);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String name, {
    String? driverKey,
    Object? body,
    List<int>? bodyBytes,
    Duration? timeout,
    Set<int> ok = const {200},
    Map<String, String>? query,
  }) async {
    final ep = endpoint(name);
    final req = http.Request(method, query == null || query.isEmpty ? ep : ep.replace(queryParameters: query));
    req.headers['accept'] = 'application/json';
    if (driverKey != null) req.headers['x-driver-key'] = driverKey;
    final bytes = bodyBytes ?? (body == null ? null : utf8.encode(jsonEncode(body)));
    if (bytes != null) {
      req.headers['content-type'] = 'application/json';
      req.bodyBytes = bytes;
    }
    http.Response res;
    try {
      res = await _http.send(req).then(http.Response.fromStream).timeout(timeout ?? this.timeout);
    } on TimeoutException {
      throw CmatException('timed out talking to ${baseUrl.host}');
    } on SocketException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on HandshakeException catch (e) {
      throw CmatException('secure connection failed: ${e.message}');
    }
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    if (!ok.contains(res.statusCode)) {
      final err = decoded is Map && decoded['error'] is String ? decoded['error'] as String : null;
      final word = decoded is Map && decoded['status'] is String && (decoded['status'] as String).length <= 24 ? decoded['status'] as String : null;
      throw CmatException(err ?? 'server answered ${res.statusCode}${res.reasonPhrase == null ? '' : ' ${res.reasonPhrase}'}',
          status: res.statusCode,
          serverStatus: word,
          retryAfterSec: int.tryParse(res.headers['retry-after'] ?? ''),
          code: decoded is Map && decoded['code'] is String && (decoded['code'] as String).length <= 40 ? decoded['code'] as String : null,
          body: decoded is Map ? decoded.cast<String, dynamic>() : null);
    }
    if (decoded is! Map) throw CmatException('server sent an unreadable answer', status: res.statusCode);
    return decoded.cast<String, dynamic>();
  }

  @override
  Future<KeyRequestResult> requestKey({required String name, String? callsign, String? email}) async {
    final j = await _send('POST', 'driver-request',
        body: {'name': name, 'callsign': ?callsign, 'email': ?email}, ok: const {200, 201});
    final key = j['key'];
    if (key is! String || key.isEmpty) throw const CmatException('server did not return a driver key');
    return KeyRequestResult(
      driverId: j['driverId'] as String? ?? '',
      key: key,
      status: parseDriverKeyStatus(j['status']),
      display: j['display'] as String? ?? '',
    );
  }

  @override
  Future<({DriverKeyStatus status, String display})> status(String driverKey) async {
    final j = await _send('GET', 'driver-status', driverKey: driverKey);
    return (status: parseDriverKeyStatus(j['status']), display: j['display'] as String? ?? '');
  }

  /// `POST /api/cmh/telemetry` (lib/core/telemetry_uploader.dart). Returns the status instead of throwing on a refusal, so the
  /// uploader can tell 429/401/400 apart; network failures throw [CmatException].
  @override
  Future<TelemetryHttpResult> postTelemetry(String driverKey, List<int> body) => _telemetry('POST', driverKey, body);

  /// `DELETE /api/cmh/telemetry`: erases everything this driver sent.
  @override
  Future<TelemetryHttpResult> deleteTelemetry(String driverKey) => _telemetry('DELETE', driverKey, null);

  Future<TelemetryHttpResult> _telemetry(String method, String driverKey, List<int>? body) async {
    final req = http.Request(method, endpoint('telemetry'));
    req.headers['accept'] = 'application/json';
    req.headers['x-driver-key'] = driverKey;
    if (body != null) {
      req.headers['content-type'] = 'application/json';
      req.bodyBytes = body;
    }
    try {
      final res = await _http.send(req).then(http.Response.fromStream).timeout(timeout);
      Map<String, dynamic>? j;
      try {
        final d = res.body.isEmpty ? null : jsonDecode(res.body);
        if (d is Map) j = d.cast<String, dynamic>();
      } catch (_) {}
      return TelemetryHttpResult(res.statusCode, retryAfterSec: int.tryParse(res.headers['retry-after'] ?? ''), body: j);
    } on TimeoutException {
      throw CmatException('timed out talking to ${baseUrl.host}');
    } on SocketException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on HandshakeException catch (e) {
      throw CmatException('secure connection failed: ${e.message}');
    }
  }

  @override
  Future<UploadResult> upload(String driverKey, DriveBatch batch) async {
    final j = await _send('POST', 'drive-upload', driverKey: driverKey, body: batch.toJson(), timeout: uploadTimeout);
    int n(Object? v) => v is num ? v.toInt() : 0;
    final rejections = <PingRejection>[];
    for (final r in (j['rejections'] as List?) ?? const []) {
      if (r is! Map) continue;
      rejections.add(PingRejection(
        index: n(r['index']),
        id: r['id'] as String?,
        reason: r['reason'] as String? ?? 'rejected',
      ));
    }
    return DetailedUploadResult(
      stored: n(j['stored']),
      duplicate: n(j['duplicate']),
      rejected: n(j['rejected']),
      rejections: rejections,
      sessionId: j['sessionId'] as String?,
      samplesStored: n(j['samplesStored']),
      samplesDuplicate: n(j['samplesDuplicate']),
      samplesRejected: n(j['samplesRejected']),
      sampleRejections: _sampleRejections(j['sampleRejections']),
    );
  }

  static List<SampleRejection> _sampleRejections(Object? raw) => [
        for (final r in (raw as List?) ?? const [])
          if (r is Map)
            SampleRejection(index: r['index'] is num ? (r['index'] as num).toInt() : -1, reason: r['reason'] as String? ?? 'rejected'),
      ];

  @override
  Future<ContextUploadResult> uploadDriveContext(String driverKey, DriveContextBatch batch) async {
    final j = await _send('POST', 'drive-context', driverKey: driverKey, body: batch.toJson(), timeout: uploadTimeout);
    int n(Object? v) => v is num ? v.toInt() : 0;
    final rejections = <ContextRejection>[];
    for (final r in (j['rejections'] as List?) ?? const []) {
      if (r is! Map) continue;
      rejections.add(ContextRejection(index: n(r['index']), id: r['id'] as String?, reason: r['reason'] as String? ?? 'rejected'));
    }
    return ContextUploadResult(
      pingsUpdated: n(j['pingsUpdated']),
      rejected: n(j['rejected']),
      rejections: rejections,
      samplesStored: n(j['samplesStored']),
      samplesDuplicate: n(j['samplesDuplicate']),
      samplesRejected: n(j['samplesRejected']),
      sampleRejections: _sampleRejections(j['sampleRejections']),
    );
  }

  @override
  Future<ContextEraseResult> deleteDriveContext(String driverKey, String category) async {
    final j = await _send('DELETE', 'drive-context', driverKey: driverKey, query: {'category': category});
    int n(Object? v) => v is num ? v.toInt() : 0;
    return ContextEraseResult(category: j['category'] as String? ?? category, sessions: n(j['sessions']), pings: n(j['pings']), samples: n(j['samples']));
  }

  @override
  Future<DriveEnv> driveEnv(String driverKey, String sessionId) async {
    final j = await _send('GET', 'drive-env', driverKey: driverKey, query: {'session': sessionId});
    final status = switch (j['status']) {
      'ready' => DriveEnvStatus.ready,
      'pending' => DriveEnvStatus.pending,
      'disabled' => DriveEnvStatus.disabled,
      _ => DriveEnvStatus.unavailable,
    };
    double? d(Object? v) => v is num && v.toDouble().isFinite ? v.toDouble() : null;
    final snaps = <WeatherSnapshot>[];
    for (final e in (j['snapshots'] as List?) ?? const []) {
      if (e is! Map) continue;
      final at = e['at'] is String ? DateTime.tryParse(e['at'] as String) : null;
      if (at == null) continue;
      snaps.add(WeatherSnapshot(
        at: at.toUtc(),
        temperatureC: d(e['temperatureC']),
        humidityPct: d(e['humidityPct']),
        dewPointC: d(e['dewPointC']),
        pressureHpa: d(e['pressureHpa']),
        precipMm: d(e['precipMm']),
        cloudPct: d(e['cloudPct']),
        windMs: d(e['windMs']),
        windDirDeg: d(e['windDirDeg']),
      ));
    }
    snaps.sort((a, b) => a.at.compareTo(b.at));
    // The licence needs this exact line wherever the values are shown; never display a server-edited one in its place.
    return DriveEnv(session: j['session'] as String? ?? sessionId, status: status, attribution: openMeteoCredit, snapshots: snaps);
  }

  @override
  Future<DriverPrivacy> driverPrivacy(String driverKey) async =>
      _privacyOf(await _send('GET', 'driver-privacy', driverKey: driverKey));

  @override
  Future<DriverPrivacy> setDriverPrivacy(String driverKey, {List<PrivacyZone>? zones, int? trimM}) async => _privacyOf(await _send(
      'POST', 'driver-privacy',
      driverKey: driverKey,
      body: {if (zones != null) 'privacyZones': [for (final z in zones) z.toJson()], 'trimM': ?trimM}));

  DriverPrivacy _privacyOf(Map<String, dynamic> j) =>
      DriverPrivacy.tryParse(j) ?? (throw const CmatException('server sent an unreadable answer', status: 200));

  @override
  Future<List<PingObservation>> driveStatus(String driverKey, String sessionId) async {
    final j = await _send('GET', 'drive-status', driverKey: driverKey, query: {'session': sessionId});
    final list = j['pings'];
    if (list is! List) throw const CmatException('server sent an unreadable answer', status: 200);
    return [for (final e in list) ?PingObservation.tryParse(e)];
  }

  @override
  Future<DriverSummary> driverSummary(String driverKey) async {
    final j = await _send('GET', 'driver-summary', driverKey: driverKey);
    try {
      return DriverSummary.parse(j);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon, bool h3 = false}) async {
    final q = <String, String>{'key': repeaterKey.trim().toLowerCase(), if (h3) 'res': '11'};
    if (lat != null && lon != null && lat.isFinite && lon.isFinite) {
      q['lat'] = lat.toStringAsFixed(5);
      q['lon'] = lon.toStringAsFixed(5);
    }
    final j = await _send('GET', 'repeater-reach', driverKey: driverKey, query: q);
    try {
      return RepeaterReach.parse(j, engine: h3 ? loadHexEngine() : null);
    } on FormatException {
      throw CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<CellLinks> cellLinks(String driverKey, String h3) async {
    final j = await _send('GET', 'cell-links', driverKey: driverKey, query: {'h3': h3.trim().toLowerCase()});
    try {
      return CellLinks.parse(j);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<ClaimChallenge> claimStart(String driverKey, String pubkey, ClaimKind kind) async {
    final Map<String, dynamic> j;
    try {
      j = await _send('POST', 'claim-start',
          driverKey: driverKey, body: {'pubkey': pubkey.trim().toLowerCase(), 'kind': kind.name}, ok: const {200, 201});
    } on CmatException catch (e) {
      // 409 {owner: "you", claim}: the caller already owns this key. Not a failure: show the existing claim.
      if (e.status == 409 && e.body?['owner'] == 'you') {
        NodeClaim? c;
        try {
          c = NodeClaim.parse(e.body?['claim']);
        } on FormatException {
          c = null;
        }
        throw ClaimAlreadyYours(c);
      }
      rethrow;
    }
    try {
      return ClaimChallenge.parse(j, asked: kind);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 201);
    }
  }

  @override
  Future<NodeClaim> claimComplete(String driverKey, String challengeId, String signatureHex) async {
    final j = await _send('POST', 'claim-complete',
        driverKey: driverKey, body: {'challengeId': challengeId, 'signature': signatureHex.toLowerCase()});
    try {
      return NodeClaim.parse(j['claim']);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<NodeClaim> claimCompleteLogin(String driverKey, String challengeId,
      {required bool isAdmin, int? firmwareLevel, required DateTime loginAt, required String radioPubKey}) async {
    final j = await _send('POST', 'claim-complete', driverKey: driverKey, body: {
      'challengeId': challengeId,
      'attest': {
        'isAdmin': isAdmin,
        'firmwareLevel': firmwareLevel,
        'loginAt': loginAt.toUtc().toIso8601String(),
        'radioPubKey': radioPubKey.toLowerCase(),
      },
    });
    try {
      return NodeClaim.parse(j['claim']);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<ClaimStatus> claimStatus(String driverKey, String challengeId) async {
    final j = await _send('GET', 'claim-status', driverKey: driverKey, query: {'challengeId': challengeId});
    try {
      return ClaimStatus.parse(j);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<List<NodeClaim>> myRadios(String driverKey) async {
    final j = await _send('GET', 'my-radios', driverKey: driverKey);
    final out = <NodeClaim>[];
    for (final c in (j['claims'] as List?) ?? const []) {
      try {
        out.add(NodeClaim.parse(c));
      } on FormatException {
        // skip a row we cannot read
      }
    }
    return out;
  }

  @override
  Future<void> releaseClaim(String driverKey, String pubkey) async {
    await _send('DELETE', 'claim', driverKey: driverKey, query: {'pubkey': pubkey.trim().toLowerCase()});
  }

  @override
  Future<NodeClaim> updateClaim(String driverKey, String pubkey, Map<String, Object?> changes) async {
    final j = await _send('PATCH', 'claim',
        driverKey: driverKey, body: {'pubkey': pubkey.trim().toLowerCase(), ...changes});
    try {
      return NodeClaim.parse(j['claim']);
    } on FormatException {
      throw const CmatException('server sent an unreadable answer', status: 200);
    }
  }

  @override
  Future<ProblemReportResult> reportProblem(String driverKey, String body) async {
    final bytes = utf8.encode(body);
    if (bytes.length > problemReportMaxBytes) {
      // Refused here exactly as the server would refuse it, so nothing over the cap ever leaves the phone.
      throw const CmatException('Report is larger than 5 MB.', status: 413);
    }
    final j = await _send('POST', 'problem-report', driverKey: driverKey, bodyBytes: bytes, ok: const {201});
    final id = j['id'];
    if (id is! String || id.isEmpty) throw const CmatException('server did not return a report id');
    return ProblemReportResult(id: id, status: j['status'] as String?);
  }

  @override
  Future<List<RepeaterRef>> repeaters(String driverKey) async {
    final j = await _send('GET', 'drive-repeaters', driverKey: driverKey);
    final out = <RepeaterRef>[];
    for (final r in (j['repeaters'] as List?) ?? const []) {
      try {
        out.add(RepeaterRef.fromJson((r as Map).cast<String, dynamic>()));
      } catch (_) {
        // Skip a malformed entry rather than lose the whole list.
      }
    }
    return out;
  }

  @override
  Future<SiteConfig> siteConfig() async {
    // Public endpoint: no x-driver-key.
    final j = await _send('GET', 'site-config');
    final region = j['region'];
    if (region is! Map || region['slug'] is! String || region['url'] is! String) {
      throw const CmatException('server sent a site-config answer without a region');
    }
    final regionInfo = RegionInfo(slug: region['slug'] as String, url: region['url'] as String);

    final rawPreset = j['radioPreset'];
    RadioPreset? preset;
    if (rawPreset is Map) {
      final name = rawPreset['name'];
      final freq = rawPreset['freqMHz'];
      final bw = rawPreset['bwKHz'];
      final sf = rawPreset['sf'];
      final cr = rawPreset['cr'];
      if (name is! String || freq is! num || bw is! num || sf is! num || cr is! num) {
        throw const CmatException('server sent a malformed radio preset');
      }
      preset = RadioPreset(name: name, freqMhz: freq.toDouble(), bwKhz: bw.toDouble(), sf: sf.toInt(), cr: cr.toInt());
    } else if (rawPreset != null) {
      throw const CmatException('server sent a malformed radio preset');
    }

    final tz = j['timezone'];
    return SiteConfig(
        region: regionInfo,
        radioPreset: preset,
        radioPresetNone: preset == null ? PresetNone.tryParse(j['radioPresetNone']) : null,
        timezone: tz is String && tz.isNotEmpty ? tz : null,
        capabilities: parseCapabilities(j['capabilities']),
        driveFormats: parseCapabilityList(j['capabilities'], 'driveFormats'),
        telemetryFormats: parseCapabilityList(j['capabilities'], 'telemetryFormats'));
  }

  @override
  Future<PublicCoverage> publicCoverage({int? res, DateTime? since, DateTime? until, String? source}) async {
    // Public endpoint: no x-driver-key. Params are the website's own layer filters; omitted = server defaults.
    final q = <String, String>{
      if (res != null) 'res': '$res',
      if (since != null) 'since': since.toUtc().toIso8601String(),
      if (until != null) 'until': until.toUtc().toIso8601String(),
      if (source != null && source != 'all') 'source': source,
    };
    final j = await _send('GET', 'public-coverage', query: q);
    final rawCells = j['cells'];
    if (rawCells is! List) throw const CmatException('server sent a public-coverage answer without cells');
    final asOf = j['asOf'];
    if (asOf is! String) throw const CmatException('server sent a public-coverage answer without asOf');
    final cellDegRaw = j['cellDeg'];
    final cellDeg = cellDegRaw is num ? cellDegRaw.toDouble() : 0.005;

    CoverageGrid grid;
    final rawGrid = j['grid'];
    if (rawGrid is Map && rawGrid['kind'] == 'h3') {
      final res = rawGrid['res'];
      if (res is! num) throw const CmatException('server sent a malformed h3 grid');
      final pending = rawGrid['pending'];
      grid = CoverageGrid.h3(res: res.toInt(), cellDeg: cellDeg, pending: pending is num ? pending.toInt() : 0);
    } else if (rawGrid is Map && rawGrid['kind'] == 'square') {
      final deg = rawGrid['cellDeg'];
      grid = CoverageGrid.square(cellDeg: deg is num ? deg.toDouble() : cellDeg);
    } else {
      // No grid field at all: an older server, squares (the website's own handler falls back the same way).
      grid = CoverageGrid.square(cellDeg: cellDeg);
    }

    final cells = <CoverageCell>[];
    for (final c in rawCells) {
      if (c is! Map) continue;
      final lat = c['lat'], lon = c['lon'];
      if (lat is! num || lon is! num) continue; // skip an unusable cell rather than lose the whole map
      num? asNum(Object? v) => v is num ? v : null;
      cells.add(CoverageCell(
        lat: lat.toDouble(),
        lon: lon.toDouble(),
        pings: asNum(c['pings'])?.toInt() ?? 0,
        heard: asNum(c['heard'])?.toInt() ?? 0,
        bestSnr: asNum(c['bestSnr'])?.toDouble(),
        medianSnr: asNum(c['medianSnr'])?.toDouble(),
        repeaters: asNum(c['repeaters'])?.toInt() ?? 0,
        lastAt: c['lastAt'] as String? ?? '',
        h3: c['h3'] as String?,
        noiseFloor: asNum(c['noiseFloor'])?.toDouble(),
      ));
    }
    return PublicCoverage(cells: cells, asOf: asOf, grid: grid);
  }

  @override
  Future<List<RegionIndexEntry>> regionsIndex({List<String>? slugs}) async {
    // Public endpoint: no x-driver-key. The whole index is 3.4 MB at 559 regions, so it is read as text and parsed off
    // the main isolate; a 429 keeps its Retry-After so the caller can back off.
    final ep = endpoint('regions-index');
    final q = slugs == null || slugs.isEmpty ? null : {'slug': slugs.join(',')};
    final req = http.Request('GET', q == null ? ep : ep.replace(queryParameters: q));
    req.headers['accept'] = 'application/json';
    final http.Response res;
    try {
      res = await _http.send(req).then(http.Response.fromStream).timeout(slugs == null ? uploadTimeout : timeout);
    } on TimeoutException {
      throw CmatException('timed out talking to ${baseUrl.host}');
    } on SocketException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on HandshakeException catch (e) {
      throw CmatException('secure connection failed: ${e.message}');
    }
    if (res.statusCode != 200) {
      throw CmatException('server answered ${res.statusCode}${res.reasonPhrase == null ? '' : ' ${res.reasonPhrase}'}',
          status: res.statusCode, retryAfterSec: int.tryParse(res.headers['retry-after'] ?? ''));
    }
    try {
      return await parseRegionsIndexBodyOffMain(utf8.decode(res.bodyBytes));
    } on FormatException catch (e) {
      throw CmatException(e.message, status: 200);
    }
  }
}
