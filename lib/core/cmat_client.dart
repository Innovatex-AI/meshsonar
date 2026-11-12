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
//   <base>/api/cmh/photo-config | photo-upload | photo-upload-enc | photo-delete | photo-report   (lib/core/photo_api.dart, contract v1)
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
import 'driver_account.dart';
import 'driver_summary.dart';
import 'model.dart';
import 'region_lookup.dart';
import 'hex_cells.dart' show loadHexEngine;
import 'map_links.dart';
import 'node_claim.dart';
import 'photo_api.dart';
import 'photo_wire.dart';
import 'privacy_zones.dart';
import 'repeater_reach.dart';
import 'report_body.dart' show problemReportMaxBytes;
import 'drive_end.dart';
import 'home_observer.dart';
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

class HttpCmatClient implements CmatClient, TelemetryTransport, HomeObserverTransport, DriveEndTransport, PhotoTransport {
  @override
  final Uri baseUrl;
  final http.Client _http;
  final Duration timeout;
  final Duration uploadTimeout;

  /// The socket under photo uploads (real per-chunk progress; see lib/core/photo_wire.dart) and when they give up.
  final PhotoWire photoWire;
  final PhotoUploadTimeouts photoTimeouts;

  /// Size of one photo body write: small enough that the bar moves every half second at ~14 KB/s.
  static const int photoChunkBytes = 8 * 1024;

  HttpCmatClient(
    this.baseUrl, {
    http.Client? client,
    this.timeout = const Duration(seconds: 30),
    this.uploadTimeout = const Duration(seconds: 120),
    PhotoWire? photoWire,
    this.photoTimeouts = const PhotoUploadTimeouts(),
  })  : _http = client ?? http.Client(),
        photoWire = photoWire ?? const IoPhotoWire();

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
    // An empty key means "none": repeater-reach and cell-links are public reads (Drive plan 7.3 F8), the header is not sent.
    if (driverKey != null && driverKey.isNotEmpty) req.headers['x-driver-key'] = driverKey;
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

  // ---------- home observer (lib/core/home_observer.dart; contract section 4) ----------
  @override
  Future<HomeObserverHttpResult> putHome(String driverKey, Map<String, dynamic> body) =>
      _observer('PUT', endpoint('observer/home'), driverKey, homeObserverJson(body));

  @override
  Future<HomeObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) =>
      _observer('POST', endpoint('observer/heartbeat'), driverKey, homeObserverJson(body));

  @override
  Future<HomeObserverHttpResult> deleteHome(String driverKey, String observerId) =>
      _observer('DELETE', endpoint('observer/home').replace(queryParameters: {'id': observerId}), driverKey, null);

  /// `POST /api/cmh/observer/drive-end` (contract section 8.7, lib/core/drive_end.dart).
  @override
  Future<int> driveEnd(String driverKey, Map<String, dynamic> body) async =>
      (await _raw('POST', endpoint('observer/drive-end'), driverKey, homeObserverJson(body))).status;

  @override
  Future<HomeObserverHttpResult> me(String driverKey) => _observer('GET', endpoint('observer/me'), driverKey, null);

  Future<HomeObserverHttpResult> _observer(String method, Uri url, String driverKey, List<int>? body) async {
    final r = await _raw(method, url, driverKey, body);
    return HomeObserverHttpResult(r.status, body: r.body);
  }

  Future<TelemetryHttpResult> _telemetry(String method, String driverKey, List<int>? body) =>
      _raw(method, endpoint('telemetry'), driverKey, body);

  /// One request with `x-driver-key` that returns the status (and JSON body) instead of throwing on a refusal; network
  /// failures throw [CmatException].
  Future<TelemetryHttpResult> _raw(String method, Uri url, String driverKey, List<int>? body) async {
    final req = http.Request(method, url);
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
        if (d is List) j = {'observers': d};
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
  Future<DriverDevices> driverDevices(String driverKey) async {
    final j = await _send('GET', 'driver-devices', driverKey: driverKey);
    return DriverDevices.tryParse(j) ?? (throw const CmatException('server sent an unreadable answer', status: 200));
  }

  @override
  Future<RevealedKey> revealKey(String driverKey, {required String kind, required String id}) async {
    final j = await _send('POST', 'driver-key-reveal', driverKey: driverKey, body: {'kind': kind, 'id': id});
    final key = j['key'];
    if (j['revealable'] != true || key is! String || key.isEmpty) return const RevealedKey();
    final link = j['configLink'];
    return RevealedKey(key: key, configLink: link is String && link.isNotEmpty ? link : null);
  }

  @override
  Future<String> rotateKey(String driverKey, String newKey) async {
    final j = await _send('POST', 'driver-key-rotate', driverKey: driverKey, body: {'newKey': newKey});
    return j['keyHint'] is String ? j['keyHint'] as String : newKey.substring(newKey.length - 4);
  }

  @override
  Future<ServerDriveDetail> driverDrive(String driverKey, String sessionId) async {
    final j = await _send('GET', 'driver-drive', driverKey: driverKey, query: {'id': sessionId}, timeout: const Duration(seconds: 90));
    return ServerDriveDetail.tryParse(j) ?? (throw const CmatException('server sent an unreadable answer', status: 200));
  }

  @override
  Future<void> updateServerDrive(String driverKey, String sessionId, {String? label, bool clearLabel = false, bool? hidden}) async {
    await _send('POST', 'driver-drive-update',
        driverKey: driverKey, body: {'id': sessionId, if (label != null || clearLabel) 'label': clearLabel ? null : label, 'hidden': ?hidden});
  }

  @override
  Future<void> deleteServerDrive(String driverKey, String sessionId) async {
    await _send('POST', 'driver-drive-delete', driverKey: driverKey, body: {'id': sessionId});
  }

  @override
  Future<List<ReportRow>> driverReports(String driverKey) async => ReportRow.parseList(await _send('GET', 'driver-reports', driverKey: driverKey));

  @override
  Future<List<int>> exportAccount(String driverKey) async {
    final req = http.Request('GET', endpoint('driver-export'))
      ..headers['accept'] = 'application/json'
      ..headers['x-driver-key'] = driverKey;
    http.Response res;
    try {
      res = await _http.send(req).then(http.Response.fromStream).timeout(const Duration(minutes: 5));
    } on TimeoutException {
      throw CmatException('timed out talking to ${baseUrl.host}');
    } on SocketException catch (e) {
      throw CmatException('network error: ${e.message}');
    } on http.ClientException catch (e) {
      throw CmatException('network error: ${e.message}');
    }
    if (res.statusCode != 200) {
      Object? d;
      try {
        d = jsonDecode(res.body);
      } catch (_) {}
      throw CmatException(d is Map && d['error'] is String ? d['error'] as String : 'server answered ${res.statusCode}',
          status: res.statusCode, retryAfterSec: int.tryParse(res.headers['retry-after'] ?? ''));
    }
    return res.bodyBytes;
  }

  @override
  Future<DriverDeleteCounts> deleteDriver(String driverKey) async =>
      DriverDeleteCounts.parse(await _send('DELETE', 'driver-delete', driverKey: driverKey));

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
  Future<PublicCoverage> publicCoverage({int? res, DateTime? since, DateTime? until, String? source, String? metric}) async {
    // Public endpoint: no x-driver-key. Params are the website's own layer filters; omitted = server defaults. metric=mean
    // (coverage v2, res 11 only) adds snrMean / nOk / nFail / band per cell.
    final q = <String, String>{
      'metric': ?metric,
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
        snrMean: asNum(c['snrMean'])?.toDouble(),
        nOk: asNum(c['nOk'])?.toInt(),
        nFail: asNum(c['nFail'])?.toInt(),
        band: asNum(c['band'])?.toInt(),
      ));
    }
    return PublicCoverage(cells: cells, asOf: asOf, grid: grid);
  }

  // ---------- photo messages (lib/core/photo_api.dart, contract v1) ----------

  @override
  Future<PhotoConfig> photoConfig() async {
    try {
      return PhotoConfig.parse(await _send('GET', 'photo-config', timeout: const Duration(seconds: 10)));
    } on CmatException catch (e) {
      throw _photoError(e);
    }
  }

  @override
  Future<PhotoUploadResult> uploadPhoto(String driverKey, List<int> bytes,
      {String contentType = 'image/jpeg', void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) =>
      _uploadPhotoBody('photo-upload', driverKey, bytes, contentType, const {}, PhotoUploadResult.parse, onProgress, cancel);

  @override
  Future<PhotoUploadResult> uploadPrivatePhoto(String driverKey, List<int> body,
          {required int width, required int height, void Function(int sent, int total)? onProgress, PhotoCancel? cancel}) =>
      _uploadPhotoBody('photo-upload-enc', driverKey, body, 'application/octet-stream', {'x-photo-w': '$width', 'x-photo-h': '$height'}, parsePrivateUploadResult,
          onProgress, cancel);

  Future<PhotoUploadResult> _uploadPhotoBody(String fn, String driverKey, List<int> bytes, String contentType, Map<String, String> extraHeaders,
      PhotoUploadResult Function(Map<String, dynamic>) parse, void Function(int sent, int total)? onProgress, PhotoCancel? cancel) async {
    if (driverKey.isEmpty) throw const PhotoError(PhotoErrorKind.noKey);
    if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    final total = bytes.length;
    final t = photoTimeouts;
    final done = Completer<PhotoWireResponse>();
    PhotoWireRequest? req;
    Timer? watchdog;
    void fail(PhotoError e) {
      if (done.isCompleted) return;
      done.completeError(e);
      req?.abort();
    }

    // One watchdog, re-armed on every byte the socket takes: [t.stall] while sending (and connecting), [t.response] once the
    // last byte is out. A slow but steady link never trips it; only the hard cap bounds the whole upload.
    void arm(Duration d, String why) {
      watchdog?.cancel();
      watchdog = Timer(d, () => fail(PhotoError(PhotoErrorKind.stalled, detail: why)));
    }

    final cap = Timer(t.cap, () => fail(PhotoError(PhotoErrorKind.stalled, detail: 'not done after ${t.cap.inMinutes} min')));
    unawaited(cancel?.whenCancelled.then((_) => fail(const PhotoError(PhotoErrorKind.cancelled))));
    unawaited(() async {
      try {
        arm(t.stall, 'could not connect within ${t.stall.inSeconds} s');
        final r = await photoWire.open('POST', endpoint(fn),
            {'accept': 'application/json', 'content-type': contentType, 'x-driver-key': driverKey, ...extraHeaders}, total);
        if (done.isCompleted) {
          r.abort();
          return;
        }
        req = r;
        var sent = 0;
        onProgress?.call(0, total);
        while (sent < total) {
          final end = sent + photoChunkBytes < total ? sent + photoChunkBytes : total;
          await r.write(bytes.sublist(sent, end));
          if (done.isCompleted) return;
          sent = end;
          arm(sent < total ? t.stall : t.response,
              sent < total ? 'no progress for ${t.stall.inSeconds} s' : 'no answer ${t.response.inSeconds} s after the last byte');
          onProgress?.call(sent, total);
        }
        if (total == 0) arm(t.response, 'no answer');
        final res = await r.finish();
        if (!done.isCompleted) done.complete(res);
      } on PhotoError catch (e) {
        fail(e);
      } catch (e) {
        if (cancel?.cancelled ?? false) return fail(const PhotoError(PhotoErrorKind.cancelled));
        fail(PhotoError(PhotoErrorKind.network, detail: switch (e) {
          SocketException() => e.message,
          HandshakeException() => e.message,
          HttpException() => e.message,
          _ => '$e',
        }));
      }
    }());
    final PhotoWireResponse wres;
    try {
      wres = await done.future;
    } finally {
      watchdog?.cancel();
      cap.cancel();
    }
    final res = http.Response.bytes(wres.body, wres.status, headers: wres.headers);
    if (cancel?.cancelled ?? false) throw const PhotoError(PhotoErrorKind.cancelled);
    Object? decoded;
    try {
      decoded = res.body.isEmpty ? null : jsonDecode(res.body);
    } catch (_) {
      decoded = null;
    }
    final body = decoded is Map ? decoded.cast<String, dynamic>() : null;
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw PhotoError.fromStatus(res.statusCode, body: body, retryAfterHeader: int.tryParse(res.headers['retry-after'] ?? ''));
    }
    if (body == null) throw PhotoError(PhotoErrorKind.server, status: res.statusCode, detail: 'unreadable answer');
    try {
      return parse(body);
    } on FormatException catch (e) {
      throw PhotoError(PhotoErrorKind.server, status: res.statusCode, detail: e.message);
    }
  }

  @override
  Future<void> deletePhoto(String driverKey, String id) async {
    if (driverKey.isEmpty) throw const PhotoError(PhotoErrorKind.noKey);
    try {
      await _send('POST', 'photo-delete', driverKey: driverKey, body: {'id': id});
    } on CmatException catch (e) {
      throw _photoError(e);
    }
  }

  @override
  Future<void> reportPhoto(String id, PhotoReportReason reason, {String? driverKey, String? key}) async {
    try {
      await _send('POST', 'photo-report', driverKey: driverKey, body: {'id': id, 'reason': reason.slug, 'key': ?key}, ok: const {200, 202});
    } on CmatException catch (e) {
      throw _photoError(e);
    }
  }

  static PhotoError _photoError(CmatException e) {
    final s = e.status;
    if (s == null) return PhotoError(PhotoErrorKind.network, detail: e.message);
    return PhotoError.fromStatus(s, body: e.body, retryAfterHeader: e.retryAfterSec);
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
