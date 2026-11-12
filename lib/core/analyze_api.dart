// The Analyze tab's reads (AN-1): the six GETs of docs/analyze-contract.md on the REGION host (the host picks the region; no region
// parameter). Pure Dart. Each read is independent: one that fails is that section's own error and never hides the others.
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'analyze_model.dart';
import 'etag_client.dart';
import 'region_dataset_fetch.dart';

/// One read's outcome: [data] or an [error] sentence (null both while not yet loaded).
class AnalyzeRead<T> {
  final T? data;
  final String? error;
  const AnalyzeRead.ok(T this.data) : error = null;
  const AnalyzeRead.failed(String this.error) : data = null;
  bool get failed => data == null;
}

class AnalyzeApi {
  final String baseUrl;
  final http.Client? client;
  const AnalyzeApi(this.baseUrl, {this.client});

  Future<AnalyzeRead<T>> _get<T extends Object>(
    String fn,
    T Function(Map<String, dynamic>) parse, [
    Map<String, String>? q,
  ]) async {
    final r = await fetchRegionDataset<T>(regionDatasetUri(baseUrl, fn, q), parse, client: client);
    final d = r.data;
    return d != null ? AnalyzeRead.ok(d) : AnalyzeRead.failed(r.error ?? 'The server did not answer.');
  }

  Future<AnalyzeRead<InsightsRead>> insights() => _get('region-insights', InsightsRead.parse);
  Future<AnalyzeRead<RepeaterHealthRead>> health() => _get('region-repeater-health', RepeaterHealthRead.parse);
  Future<AnalyzeRead<List<AnalyzeEvent>>> events() => _get('region-overview', parseRecentEvents);
  Future<AnalyzeRead<TrafficRead>> traffic() => _get('region-traffic', TrafficRead.parse, {'hours': '24'});
  Future<AnalyzeRead<NodeGateRead>> gate() => _get('region-node-gate', NodeGateRead.parse, {'days': '30'});

  /// region-status answers a JSON ARRAY, so it is read here (the shared fetch only accepts objects).
  Future<AnalyzeRead<List<DatasetStatus>>> statuses() async {
    final c = client ?? newRegionWireClient();
    try {
      final res = await c
          .get(regionDatasetUri(baseUrl, 'region-status'), headers: const {'accept': 'application/json'})
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return AnalyzeRead.failed('The server answered ${res.statusCode}.');
      return AnalyzeRead.ok(parseRegionStatus(jsonDecode(utf8.decode(res.bodyBytes))));
    } on FormatException {
      return const AnalyzeRead.failed('The server sent something unreadable.');
    } catch (_) {
      return const AnalyzeRead.failed('No connection to the server.');
    } finally {
      if (client == null) c.close();
    }
  }
}
