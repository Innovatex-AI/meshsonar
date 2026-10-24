// One GET for a public, region-scoped dataset on the region's own host: `<region host>/api/cmh/<name>` (the server
// picks the region by HOST; verified live Oct 24 2026: day.meshsonar.com/api/cmh/region-report answers DAY, while
// /api/day/... is 404). Goes through the shared ETag client (lib/core/etag_client.dart, newRegionWireClient), so a 304
// is cheap and, when the network fails, the last stored body is served: [RegionFetch.offlineAsOf] then says when it was
// fetched, for the "Offline - as of 3h ago" label (asOfLabel in region_cache.dart).
// Used by region_rf_api.dart, region_growth_api.dart and the region report export. Pure Dart: no Flutter imports.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'etag_client.dart';

/// Either [data] (with the raw [body]) or an [error] sentence; [notFound] for a 404 ("not published here").
class RegionFetch<T> {
  final T? data;
  final String? body;
  final String? error;
  final bool notFound;

  /// Set when the answer is the stored copy because the network failed.
  final DateTime? offlineAsOf;
  const RegionFetch.ok(T this.data, {this.body, this.offlineAsOf})
      : error = null,
        notFound = false;
  const RegionFetch.fail(String this.error, {this.notFound = false})
      : data = null,
        body = null,
        offlineAsOf = null;
  bool get ok => data != null;
}

/// `<baseUrl>/api/cmh/<name>?<query>`.
Uri regionDatasetUri(String baseUrl, String name, [Map<String, String>? query]) {
  final b = baseUrl.trim().replaceAll(RegExp(r'/+$'), '');
  final u = Uri.parse('$b/api/cmh/$name');
  return query == null || query.isEmpty ? u : u.replace(queryParameters: query);
}

/// GETs [url] with [client] (default: the shared region wire client, closed after) and parses a JSON object.
Future<RegionFetch<T>> fetchRegionDataset<T extends Object>(
  Uri url,
  T Function(Map<String, dynamic> json) parse, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 20),
}) async {
  final c = client ?? newRegionWireClient();
  try {
    final http.Response res;
    try {
      res = await c.get(url, headers: const {'accept': 'application/json'}).timeout(timeout);
    } on TimeoutException {
      return const RegionFetch.fail('The server took too long to answer.');
    } on SocketException {
      return const RegionFetch.fail('No connection to the server.');
    } on http.ClientException {
      return const RegionFetch.fail('No connection to the server.');
    } on HandshakeException {
      return const RegionFetch.fail('The secure connection to the server failed.');
    }
    if (res.statusCode == 404) return const RegionFetch.fail('Not published for this region.', notFound: true);
    if (res.statusCode != 200) {
      String? msg;
      try {
        final b = jsonDecode(res.body);
        if (b is Map && b['error'] is String) msg = b['error'] as String;
      } catch (_) {}
      return RegionFetch.fail(msg ?? 'The server answered ${res.statusCode}.');
    }
    final String body;
    final Object? decoded;
    try {
      body = utf8.decode(res.bodyBytes);
      decoded = jsonDecode(body);
    } on FormatException {
      return const RegionFetch.fail('The server sent something unreadable.');
    }
    if (decoded is! Map<String, dynamic>) return const RegionFetch.fail('The server sent something unreadable.');
    final offline = res.headers['x-meshsonar-cache'] == 'offline';
    final asOf = offline ? DateTime.tryParse(res.headers['x-meshsonar-as-of'] ?? '')?.toUtc() : null;
    try {
      return RegionFetch.ok(parse(decoded), body: body, offlineAsOf: asOf);
    } catch (_) {
      return const RegionFetch.fail('The server sent something unreadable.');
    }
  } finally {
    if (client == null) c.close();
  }
}

// ---- tolerant readers shared by the dataset parsers
String? jStr(Object? v) => v is String && v.isNotEmpty ? v : null;
num? jNum(Object? v) => v is num && v.isFinite ? v : null;
double? jDbl(Object? v) => jNum(v)?.toDouble();
int? jInt(Object? v) => jNum(v)?.round();
DateTime? jTime(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
List<Map<String, dynamic>> jMaps(Object? v) => v is List ? [for (final e in v) if (e is Map<String, dynamic>) e] : const [];
Map<String, dynamic> jMap(Object? v) => v is Map<String, dynamic> ? v : const {};
