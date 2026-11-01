// The planning engine's endpoints for the app, all on the region's own host (the host picks the region):
//   <host>/api/cmh/plan-native?view=overview|sites|link|planner|scenario|tracker   (src/lib/platform/plan-native.ts on the website)
//   <host>/api/cmh/candidates?ids=<osm id>                                           (the website's own public endpoint)
// They go through the shared ETag client (lib/core/etag_client.dart): a 304 is cheap and, when the network fails, the last stored
// answer is served with an "Offline - as of" time, so the last Planner result, build and site list work offline.
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import '../region_dataset_fetch.dart';
import 'link_profile.dart';
import 'plan_candidate.dart';
import 'plan_overview.dart';
import 'plan_scenario.dart';
import 'plan_sites.dart';
import 'plan_tracker.dart';
import 'planner_query.dart';

class PlanNativeApi {
  final String baseUrl;
  final http.Client? client;
  const PlanNativeApi(this.baseUrl, {this.client});

  Uri _uri(Map<String, String> q) => regionDatasetUri(baseUrl, 'plan-native', q);

  Future<RegionFetch<PlanOverview>> overview() => fetchRegionDataset(_uri({'view': 'overview'}), PlanOverview.parse, client: client, timeout: const Duration(seconds: 40));
  Future<RegionFetch<PlanSites>> sites() => fetchRegionDataset(_uri({'view': 'sites'}), PlanSites.parse, client: client, timeout: const Duration(seconds: 40));
  Future<RegionFetch<PlanTracker>> tracker() => fetchRegionDataset(_uri({'view': 'tracker'}), PlanTracker.parse, client: client);
  Future<RegionFetch<LinkProfile>> link(String a, String b) => fetchRegionDataset(_uri({'view': 'link', 'a': a, 'b': b}), LinkProfile.parse, client: client);

  /// Runs a Planner query on the server (the website's own engine). Slow queries can take most of a minute.
  Future<RegionFetch<PlannerResult>> planner(PlannerQuery q) =>
      fetchRegionDataset(_uri(q.toParams()), PlannerResult.parse, client: client, timeout: const Duration(seconds: 70));

  Future<RegionFetch<ScenarioResult>> scenario({required List<String>? sites, required int h, required String tier, required double r, bool live = false}) => fetchRegionDataset(
        _uri({
          'view': 'scenario',
          if (sites != null) 'sites': sites.isEmpty ? 'none' : sites.join(','),
          'h': '$h',
          'tier': tier,
          'r': r == r.roundToDouble() ? '${r.round()}' : '$r',
          if (live) 'net': 'live',
        }),
        ScenarioResult.parse,
        client: client,
        timeout: const Duration(seconds: 40),
      );

  /// The full row of one OSM candidate (links to live repeaters). Null when the id is unknown.
  Future<RegionFetch<CandidateDetail?>> candidate(String id) async {
    final r = await fetchRegionDataset<_Box>(regionDatasetUri(baseUrl, 'candidates', {'ids': id}), (j) {
      final items = jMaps(j['items']);
      return _Box(items.isEmpty ? null : CandidateDetail.parse(items.first));
    }, client: client);
    if (!r.ok) return RegionFetch.fail(r.error ?? 'Could not load the site.', notFound: r.notFound, status: r.status);
    return RegionFetch.ok(r.data!.v, body: r.body, offlineAsOf: r.offlineAsOf);
  }
}

class _Box {
  final CandidateDetail? v;
  const _Box(this.v);
}
