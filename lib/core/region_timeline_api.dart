// `GET <region host>/api/cmh/region-timeline?res=9` -> the days coverage grew (see coverage_timeline.dart).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'coverage_timeline.dart';
import 'etag_client.dart' show newRegionWireClient;

/// Null when the endpoint is missing or fails: the caller shows "couldn't load". A region that answers with no days yet (200,
/// `days: []`) gives an empty [RegionTimeline], which is not a failure (Drive plan 7.3 F10).
Future<RegionTimeline?> fetchRegionTimeline(String baseUrl, {http.Client? client, Duration timeout = const Duration(seconds: 15)}) async {
  final c = client ?? newRegionWireClient(); // shared ETag/304 + disk cache when installed
  try {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final res = await c
        .get(Uri.parse('$b/api/cmh/region-timeline?res=9'), headers: const {'accept': 'application/json'})
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    final tl = RegionTimeline.parse(json);
    if (tl == null && json is Map && json['days'] is List && (json['days'] as List).isEmpty) return const RegionTimeline([]);
    return tl;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
