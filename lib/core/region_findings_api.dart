// `region-findings`: the findings and recommendations behind the region's plan, as the website's /findings page lists them
// (public GET on the region host, ETag client, last good copy served offline). Server: meshcore-insights
// src/lib/platform/findings-handlers.ts, capability `regionFindings`. A 404 means an older server: "not published here".
//   {status{state,reason,computedAt,source}, asOf, insights[{id,category,severity,headline,finding,evidence[{label,value,ref?}],
//    implication,action,related{sites[],repeaters[]}}], recommendations[{id,title,why,impact{k:n},actions[],insights[],sites[]}],
//    sites{"<id>":"<name>"}}
// Pure Dart.
import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus;

enum FindingSeverity { critical, high, medium, low }

class FindingEvidence {
  final String label, value;
  final String? ref;
  const FindingEvidence(this.label, this.value, this.ref);
}

class Finding {
  final String id, category, headline, finding, implication, action;
  final FindingSeverity severity;
  final List<FindingEvidence> evidence;
  final List<String> sites, repeaters;
  const Finding({
    required this.id,
    required this.category,
    required this.severity,
    required this.headline,
    required this.finding,
    required this.implication,
    required this.action,
    required this.evidence,
    required this.sites,
    required this.repeaters,
  });
}

class FindingRecommendation {
  final String id, title, why;
  final Map<String, num> impact;
  final List<String> actions, insights, sites;
  const FindingRecommendation({required this.id, required this.title, required this.why, required this.impact, required this.actions, required this.insights, required this.sites});
}

const _impactLabels = {
  'liveRepeatersJoined': 'live repeaters joined',
  'newPeopleWithin3km': 'people newly within 3 km',
  'sites': 'sites',
  'repeatersProtected': 'repeaters protected',
  'repeatersMadeVisible': 'repeaters made visible',
};

/// "liveRepeatersJoined" -> "live repeaters joined"; an unknown key is split on capitals and digits.
String impactLabel(String k) =>
    _impactLabels[k] ?? k.replaceAllMapped(RegExp(r'([A-Z])'), (m) => ' ${m[1]}').replaceAllMapped(RegExp(r'(\d+)'), (m) => ' ${m[1]}').toLowerCase().trim();

String impactValue(String k, num v) {
  if (k == 'newPeopleWithin3km' && v >= 10000) return '+${(v / 1000).toStringAsFixed(1)}k';
  return fmtFindingNumber(v);
}

/// At most three decimals, no trailing zeros, thousands separators (the website's fmtValue).
String fmtFindingNumber(num v) {
  var s = v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  final neg = s.startsWith('-');
  if (neg) s = s.substring(1);
  final parts = s.split('.');
  final b = StringBuffer();
  for (var i = 0; i < parts[0].length; i++) {
    if (i > 0 && (parts[0].length - i) % 3 == 0) b.write(',');
    b.write(parts[0][i]);
  }
  return '${neg ? '-' : ''}$b${parts.length > 1 ? '.${parts[1]}' : ''}';
}

class RegionFindings {
  final RegionDataStatus status;
  final DateTime? asOf;
  final List<Finding> insights;
  final List<FindingRecommendation> recommendations;
  final Map<String, String> sites;
  const RegionFindings({required this.status, this.asOf, this.insights = const [], this.recommendations = const [], this.sites = const {}});

  bool get isEmpty => insights.isEmpty && recommendations.isEmpty;
  int count(FindingSeverity s) => insights.where((i) => i.severity == s).length;

  /// Categories in first-appearance order (as the website lists them).
  List<String> get categories => [
        for (final c in {for (final i in insights) i.category}) c,
      ];

  static List<String> _strs(Object? v) => [if (v is List) for (final e in v) if (e is String) e];

  static RegionFindings parse(Map<String, dynamic> j) {
    final names = <String, String>{};
    jMap(j['sites']).forEach((k, v) {
      if (v is String) names[k] = v;
    });
    return RegionFindings(
      status: RegionDataStatus.fromJson(j['status']),
      asOf: jTime(j['asOf']),
      sites: names,
      insights: [
        for (final i in jMaps(j['insights']))
          if (jStr(i['id']) != null)
            Finding(
              id: jStr(i['id'])!,
              category: jStr(i['category']) ?? '',
              severity: FindingSeverity.values.where((s) => s.name == i['severity']).firstOrNull ?? FindingSeverity.low,
              headline: jStr(i['headline']) ?? '',
              finding: jStr(i['finding']) ?? '',
              implication: jStr(i['implication']) ?? '',
              action: jStr(i['action']) ?? '',
              evidence: [
                for (final e in jMaps(i['evidence']))
                  if (jStr(e['label']) != null && e['value'] != null)
                    FindingEvidence(jStr(e['label'])!, e['value'] is num ? fmtFindingNumber(e['value'] as num) : '${e['value']}', jStr(e['ref'])),
              ],
              sites: _strs(jMap(i['related'])['sites']),
              repeaters: _strs(jMap(i['related'])['repeaters']),
            ),
      ],
      recommendations: [
        for (final r in jMaps(j['recommendations']))
          if (jStr(r['id']) != null)
            FindingRecommendation(
              id: jStr(r['id'])!,
              title: jStr(r['title']) ?? '',
              why: jStr(r['why']) ?? '',
              impact: {
                for (final e in jMap(r['impact']).entries)
                  if (e.value is num) e.key: e.value as num,
              },
              actions: _strs(r['actions']),
              insights: _strs(r['insights']),
              sites: _strs(r['sites']),
            ),
      ],
    );
  }
}

class RegionFindingsApi {
  final String baseUrl;
  final http.Client? client;
  RegionFindingsApi(this.baseUrl, {this.client});
  Uri get uri => regionDatasetUri(baseUrl, 'region-findings');
  Future<RegionFetch<RegionFindings>> fetch() => fetchRegionDataset(uri, RegionFindings.parse, client: client);
}
