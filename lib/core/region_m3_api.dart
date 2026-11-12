// The two region answers behind the M3-2 layers: `GET <regionHost>/api/cmh/region-repeater-estimates` (Estimated positions) and
// `GET <regionHost>/api/cmh/region-link-graph` (Redundancy and Links by SNR; Redundancy alone asks `sources=measured&drive=1`
// to keep the answer small, Links by SNR asks every source). Public, no auth, no identifier, region hosts only
// (same host rule as region-repeaters). Parsing is in core/m3_data.dart. Throws [RegionRepeatersException] on any failure so
// callers share one error type with the roster fetch. Pure Dart.
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'etag_client.dart';
import 'm3_data.dart';
import 'region_repeaters_api.dart' show RegionRepeatersException, regionRepeatersUri;

Uri _regionUri(String baseUrl, String slug, String endpoint, [Map<String, String>? query]) {
  final u = regionRepeatersUri(baseUrl, slug);
  return u.replace(path: '/api/cmh/$endpoint', queryParameters: query == null || query.isEmpty ? null : query);
}

Uri regionEstimatesUri(String baseUrl, String slug) => _regionUri(baseUrl, slug, 'region-repeater-estimates');

/// [allSources] (Links by SNR) reads every link source, otherwise only the small measured set (Redundancy alone); [drive] adds the
/// per-cell drive rows (Redundancy). Same two parameters the website sends, so both ride the server's 2 minute cache.
Uri regionLinkGraphUri(String baseUrl, String slug, {required bool allSources, required bool drive}) =>
    _regionUri(baseUrl, slug, 'region-link-graph', {if (!allSources) 'sources': 'measured', 'drive': drive ? '1' : '0'});

Future<Object?> _getJson(Uri uri, String what, http.Client? client, Duration timeout) async {
  final c = client ?? newRegionWireClient();
  try {
    final res = await c.get(uri, headers: const {'accept': 'application/json'}).timeout(timeout);
    if (res.statusCode != 200) throw RegionRepeatersException('$what answered HTTP ${res.statusCode}');
    try {
      return jsonDecode(utf8.decode(res.bodyBytes));
    } on FormatException {
      throw RegionRepeatersException('$what returned invalid JSON');
    }
  } on RegionRepeatersException {
    rethrow;
  } on TimeoutException {
    throw RegionRepeatersException('$what timed out');
  } catch (e) {
    throw RegionRepeatersException('$what failed: $e');
  } finally {
    if (client == null) c.close();
  }
}

Future<EstimatesAnswer> fetchRegionEstimates(String baseUrl, String slug, {http.Client? client, Duration timeout = const Duration(seconds: 20)}) async {
  final body = await _getJson(regionEstimatesUri(baseUrl, slug), 'region-repeater-estimates', client, timeout);
  return EstimatesAnswer.fromJson(body) ?? (throw const RegionRepeatersException('region-repeater-estimates is not an estimates answer'));
}

Future<LinkGraph> fetchRegionLinkGraph(String baseUrl, String slug, {required bool allSources, required bool drive, http.Client? client, Duration timeout = const Duration(seconds: 30)}) async {
  final body = await _getJson(regionLinkGraphUri(baseUrl, slug, allSources: allSources, drive: drive), 'region-link-graph', client, timeout);
  return LinkGraph.fromJson(body) ?? (throw const RegionRepeatersException('region-link-graph is not a link graph'));
}
