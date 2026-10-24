// `GET <region host>/api/cmh/region-timeline?res=9` -> the days coverage grew (see coverage_timeline.dart).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'coverage_timeline.dart';
import 'etag_client.dart' show newRegionWireClient;

/// Null when the endpoint is missing, fails, or has no days: the caller shows "timeline unavailable".
Future<RegionTimeline?> fetchRegionTimeline(String baseUrl, {http.Client? client, Duration timeout = const Duration(seconds: 15)}) async {
  final c = client ?? newRegionWireClient(); // shared ETag/304 + disk cache when installed
  try {
    final b = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    final res = await c
        .get(Uri.parse('$b/api/cmh/region-timeline?res=9'), headers: const {'accept': 'application/json'})
        .timeout(timeout);
    if (res.statusCode != 200) return null;
    return RegionTimeline.parse(jsonDecode(utf8.decode(res.bodyBytes)));
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}
