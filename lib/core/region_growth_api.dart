// `region-ext-growth?days=365`: how the region's node list grew, from the external sources merged with MeshSonar's
// observers (public, region host, ETag). Same query as the website's /sources page (hooks-sources.ts useExtGrowth).
//   {status, basis{"<sourceId>": "source"|"observed"}, churn[{week, appeared, gone}], daily[{day, merged, bySource}],
//    roles[{role, n}], before{merged, bySource}, firmware[{firmware, n}], hashSizes[{bytes, n}]}
// Recorded live on cmh Oct 24 2026 (45 days since 2026-06-17, 8 churn weeks, firmware empty). `day`/`week` are UTC
// calendar dates. Cumulative total = before.merged + running sum of daily.merged (website sources-model.ts cumulative).
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus;

class GrowthWeek {
  final String week; // YYYY-MM-DD, Monday (UTC)
  final int appeared, gone;
  const GrowthWeek(this.week, this.appeared, this.gone);
}

class GrowthDay {
  final String day; // YYYY-MM-DD (UTC)
  final int merged;
  const GrowthDay(this.day, this.merged);
  DateTime get at => DateTime.parse('${day}T00:00:00Z');
}

class RegionGrowth {
  final RegionDataStatus status;

  /// Source id -> "source" (the source publishes first-seen dates) or "observed" (counted from when we first saw it).
  final Map<String, String> basis;
  final List<GrowthWeek> churn;
  final List<GrowthDay> daily;
  final int before;
  final List<(String, int)> roles;
  final List<(String, int)> firmware;
  final List<(int, int)> hashSizes;
  const RegionGrowth({
    required this.status,
    this.basis = const {},
    this.churn = const [],
    this.daily = const [],
    this.before = 0,
    this.roles = const [],
    this.firmware = const [],
    this.hashSizes = const [],
  });

  bool get isEmpty => churn.isEmpty && daily.isEmpty && roles.isEmpty && hashSizes.isEmpty && firmware.isEmpty;

  /// Some source is counted from when MeshSonar first saw each node (no first-seen date of its own).
  bool get hasObservedBasis => basis.values.contains('observed');

  /// (day, running total of merged nodes) per daily row.
  List<(GrowthDay, int)> cumulative() {
    var run = before;
    return [
      for (final d in daily) (d, run += d.merged),
    ];
  }

  int get total => cumulative().isEmpty ? before : cumulative().last.$2;

  static RegionGrowth parse(Map<String, dynamic> j) {
    final basis = <String, String>{};
    jMap(j['basis']).forEach((k, v) {
      if (v is String) basis[k] = v;
    });
    return RegionGrowth(
      status: RegionDataStatus.fromJson(j['status']),
      basis: basis,
      churn: [
        for (final c in jMaps(j['churn']))
          if (jStr(c['week']) != null) GrowthWeek(jStr(c['week'])!, jInt(c['appeared']) ?? 0, jInt(c['gone']) ?? 0),
      ]..sort((a, b) => a.week.compareTo(b.week)),
      daily: [
        for (final d in jMaps(j['daily']))
          if (jStr(d['day']) != null && DateTime.tryParse(jStr(d['day'])!) != null && jInt(d['merged']) != null)
            GrowthDay(jStr(d['day'])!, jInt(d['merged'])!),
      ]..sort((a, b) => a.day.compareTo(b.day)),
      before: jInt(jMap(j['before'])['merged']) ?? 0,
      roles: [
        for (final r in jMaps(j['roles']))
          if (jStr(r['role']) != null && jInt(r['n']) != null) (jStr(r['role'])!, jInt(r['n'])!),
      ],
      firmware: [
        for (final r in jMaps(j['firmware']))
          if (jStr(r['firmware']) != null && jInt(r['n']) != null) (jStr(r['firmware'])!, jInt(r['n'])!),
      ],
      hashSizes: [
        for (final r in jMaps(j['hashSizes']))
          if (jInt(r['bytes']) != null && jInt(r['n']) != null) (jInt(r['bytes'])!, jInt(r['n'])!),
      ]..sort((a, b) => a.$1.compareTo(b.$1)),
    );
  }
}

class RegionGrowthApi {
  final String baseUrl;
  final http.Client? client;
  final int days;
  RegionGrowthApi(this.baseUrl, {this.client, this.days = 365});

  Uri get uri => regionDatasetUri(baseUrl, 'region-ext-growth', {'days': '$days'});
  Future<RegionFetch<RegionGrowth>> fetch() => fetchRegionDataset(uri, RegionGrowth.parse, client: client);
}
