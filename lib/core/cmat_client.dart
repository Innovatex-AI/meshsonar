// HTTP client for the MeshSonar endpoints of CMAT (or any server implementing MeshSonar Drive Format v1):
//   <base>/api/cmh/driver-request   POST {name, callsign?, email?}      -> 201 {driverId, key, status, display}
//   <base>/api/cmh/driver-status    GET  x-driver-key                   -> {status, display}
//   <base>/api/cmh/drive-upload     POST x-driver-key, upload body      -> {sessionId, stored, duplicate, rejected, rejections[]}
//   <base>/api/cmh/drive-repeaters  GET  x-driver-key                   -> {repeaters[{key,name,lat,lon}], at}
//   <base>/api/cmh/problem-report   POST x-driver-key, report body      -> 201 {id, status, receivedAt, redacted}
//   <base>/api/cmh/site-config      GET  (public, no driver key)        -> {region:{slug,url}, radioPreset:{name,
//                                                                          freqMHz,bwKHz,sf,cr}|null, ...}
// Errors come back as {error} (403 also carries {status}); they're thrown as CmatException(error, status: http code).
// Network failures and timeouts are thrown as CmatException with status null.
// Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'api.dart';
import 'model.dart';
import 'report_body.dart' show problemReportMaxBytes;

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
  DetailedUploadResult({
    required super.stored,
    required super.duplicate,
    required super.rejected,
    required this.rejections,
    this.sessionId,
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

class HttpCmatClient implements CmatClient {
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
  }) async {
    final req = http.Request(method, endpoint(name));
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
      throw CmatException(err ?? 'server answered ${res.statusCode}${res.reasonPhrase == null ? '' : ' ${res.reasonPhrase}'}',
          status: res.statusCode);
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
    );
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

    return SiteConfig(region: regionInfo, radioPreset: preset);
  }
}
