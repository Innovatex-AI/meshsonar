// `region-packet?hash=<16 hex>`: one packet as the region's own observers heard it (public GET on the region host, ETag client).
// Contract: meshcore-insights src/lib/region/types.ts `PacketDetail`.
//   {status, row{hash,type,route,firstAt,observers,minHops,bestSnrDb,originKey,originName} | null,
//    observations[{observer,observerName,at,snrDb,rssiDbm,hops,path[hex hop codes],via?}],
//    tree{hop,key,name,lat,lon,ambiguous,confidence?,outside?,children[],observers[]} | null, nodeList?{trusted..}}
// Pure Dart.
import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';
import 'region_overview_api.dart' show RegionDataStatus;

class PacketObservationRow {
  final String observer;
  final String? observerName;
  final DateTime? at;
  final double? snrDb, rssiDbm;
  final int hops;
  final List<String> path;

  /// Heard through an outside feed (its name), not by one of our observers.
  final String? via;
  const PacketObservationRow({required this.observer, this.observerName, this.at, this.snrDb, this.rssiDbm, this.hops = 0, this.path = const [], this.via});
  String get who => observerName ?? (observer.length > 8 ? '${observer.substring(0, 8)}…' : observer);
}

class PacketTreeNodeData {
  final String hop;
  final String? key, name, confidence;
  final bool ambiguous, outside;
  final List<PacketTreeNodeData> children;
  final List<String> observers;
  const PacketTreeNodeData({required this.hop, this.key, this.name, this.confidence, this.ambiguous = false, this.outside = false, this.children = const [], this.observers = const []});

  String get label => name ?? (outside ? 'Outside this region ($hop)' : (ambiguous ? 'Several repeaters share $hop' : 'Unknown $hop'));

  static PacketTreeNodeData? parse(Object? v, [int depth = 0]) {
    if (v is! Map<String, dynamic> || depth > 24) return null;
    return PacketTreeNodeData(
      hop: jStr(v['hop']) ?? '',
      key: jStr(v['key']),
      name: jStr(v['name']),
      confidence: jStr(v['confidence']),
      ambiguous: v['ambiguous'] == true,
      outside: v['outside'] == true,
      children: [for (final c in (v['children'] is List ? v['children'] as List : const [])) ?parse(c, depth + 1)],
      observers: [for (final o in (v['observers'] is List ? v['observers'] as List : const [])) if (o is String) o],
    );
  }
}

class PacketDetailData {
  final RegionDataStatus status;
  final String? hash;
  final int type, route, observers, minHops;
  final DateTime? firstAt;
  final double? bestSnrDb;
  final String? originName, originKey;
  final List<PacketObservationRow> observations;
  final PacketTreeNodeData? tree;
  final bool hasRow;
  const PacketDetailData({
    required this.status,
    this.hash,
    this.type = -1,
    this.route = -1,
    this.observers = 0,
    this.minHops = 0,
    this.firstAt,
    this.bestSnrDb,
    this.originName,
    this.originKey,
    this.observations = const [],
    this.tree,
    this.hasRow = false,
  });

  static PacketDetailData parse(Map<String, dynamic> j) {
    final row = j['row'] is Map<String, dynamic> ? j['row'] as Map<String, dynamic> : null;
    return PacketDetailData(
      status: RegionDataStatus.fromJson(j['status']),
      hasRow: row != null,
      hash: row == null ? null : jStr(row['hash']),
      type: row == null ? -1 : jInt(row['type']) ?? -1,
      route: row == null ? -1 : jInt(row['route']) ?? -1,
      observers: row == null ? 0 : jInt(row['observers']) ?? 0,
      minHops: row == null ? 0 : jInt(row['minHops']) ?? 0,
      firstAt: row == null ? null : jTime(row['firstAt']),
      bestSnrDb: row == null ? null : jDbl(row['bestSnrDb']),
      originName: row == null ? null : jStr(row['originName']),
      originKey: row == null ? null : jStr(row['originKey']),
      observations: [
        for (final o in jMaps(j['observations']))
          if (jStr(o['observer']) != null)
            PacketObservationRow(
              observer: jStr(o['observer'])!,
              observerName: jStr(o['observerName']),
              at: jTime(o['at']),
              snrDb: jDbl(o['snrDb']),
              rssiDbm: jDbl(o['rssiDbm']),
              hops: jInt(o['hops']) ?? 0,
              path: [if (o['path'] is List) for (final p in o['path'] as List) if (p is String) p],
              via: jStr(jMap(o['via'])['name']),
            ),
      ]..sort((a, b) => (a.at ?? DateTime(0)).compareTo(b.at ?? DateTime(0))),
      tree: PacketTreeNodeData.parse(j['tree']),
    );
  }
}

class PacketDetailApi {
  final String baseUrl;
  final http.Client? client;
  PacketDetailApi(this.baseUrl, {this.client});
  Uri uriFor(String hash) => regionDatasetUri(baseUrl, 'region-packet', {'hash': hash.toLowerCase()});
  Future<RegionFetch<PacketDetailData>> fetch(String hash) => fetchRegionDataset(uriFor(hash), PacketDetailData.parse, client: client);
}
