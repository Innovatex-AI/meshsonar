// Flood routes, native: the website's `/api/cmh/tool-routes` (public GET on the region host; contract and shapes in
// meshcore-insights src/server/tools/routes.server.ts and src/components/tools/routes/data.ts). Three actions:
//   ?action=recent                  newest flood packets of the region (24 h, up to 150); `unavailable: true` when the region has no flood feed
//   ?action=trace&hash=<16 hex>     one packet: observations, hop resolution, the merged propagation tree, the bytes
//   ?action=aggregate&hours=24|168  who carries floods: carry share, corridors, hop histogram, where floods end, measured links, 1-byte collisions
// The server answers 404 for trace/aggregate when the region has no flood feed or the hash is unknown (RegionFetch.notFound).
// Paths are only what the region's observers decoded; 1-byte hop hashes are resolved by the server, never guessed here.
// Responses go through the shared ETag client, so the last good answer is stored and served offline ("Offline - as of").
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import 'region_dataset_fetch.dart';

/// Plain names for the payload types the server names in capitals (same table as the website's PAYLOAD_LABEL).
const Map<String, String> floodPayloadLabel = {
  'REQ': 'Request',
  'RESPONSE': 'Response',
  'TXT_MSG': 'Direct message',
  'ACK': 'Ack',
  'ADVERT': 'Advert',
  'GRP_TXT': 'Channel message',
  'GRP_DATA': 'Channel data',
  'ANON_REQ': 'Anonymous request',
  'PATH': 'Path return',
  'TRACE': 'Trace',
  'MULTIPART': 'Multipart',
  'CONTROL': 'Control',
  'RAW_CUSTOM': 'Custom',
};
String floodPayloadName(String? t) => t == null ? 'Packet' : floodPayloadLabel[t] ?? t;

/// A pasted packet hash as 16 lowercase hex characters, tolerating spaces and a 0x prefix; null when it is not one.
String? normalizePacketHash(String raw) {
  final h = raw.replaceAll(RegExp(r'\s+'), '').replaceFirst(RegExp(r'^0x', caseSensitive: false), '').toLowerCase();
  return RegExp(r'^[0-9a-f]{16}$').hasMatch(h) ? h : null;
}

/// First bytes of a key, or the id itself for a "hop:xx" placeholder.
String shortId(String id) => id.startsWith('hop:') ? id.substring(4) : (id.length <= 8 ? id : id.substring(0, 8));

// ------------------------------------------------------------------ recent
class RecentFlood {
  final String hash;
  final DateTime firstSeen;
  final String payloadType;
  final int hops, observers, observations;
  final String? firstRelayName, originName;
  const RecentFlood({
    required this.hash,
    required this.firstSeen,
    required this.payloadType,
    required this.hops,
    required this.observers,
    required this.observations,
    this.firstRelayName,
    this.originName,
  });
}

class RecentFloods {
  final List<RecentFlood> packets;
  final DateTime? since;

  /// The region has no outside flood feed (server `unavailable: true`).
  final bool unavailable;
  const RecentFloods({required this.packets, this.since, this.unavailable = false});

  static RecentFloods parse(Map<String, dynamic> j) => RecentFloods(
        unavailable: j['unavailable'] == true,
        since: jTime(j['since']),
        packets: [
          for (final p in jMaps(j['packets']))
            if (jStr(p['hash']) != null && jTime(p['firstSeen']) != null)
              RecentFlood(
                hash: jStr(p['hash'])!,
                firstSeen: jTime(p['firstSeen'])!,
                payloadType: jStr(p['payloadType']) ?? '',
                hops: jInt(p['hops']) ?? 0,
                observers: jInt(p['observers']) ?? 0,
                observations: jInt(p['observations']) ?? 0,
                firstRelayName: jStr(p['firstRelayName']),
                originName: jStr(p['originName']),
              ),
        ],
      );

  /// The packet worth showing first: a well-travelled one (website rule: hops x 10 + observations, among the newest 40).
  RecentFlood? get best {
    if (packets.isEmpty) return null;
    final top = packets.take(40).toList()..sort((a, b) => (b.hops * 10 + b.observations) - (a.hops * 10 + a.observations));
    return top.first;
  }
}

// ------------------------------------------------------------------ trace
class TraceNode {
  final String id;
  final String? pubkey, prefix, name;
  final double? lat, lon;
  final int depth;

  /// origin | relay | observer | relay+observer
  final String kind;

  /// okimesh | unique | geo | unresolved | origin | observer
  final String confidence;
  final DateTime? firstHeard;
  const TraceNode({
    required this.id,
    this.pubkey,
    this.prefix,
    this.name,
    this.lat,
    this.lon,
    required this.depth,
    required this.kind,
    required this.confidence,
    this.firstHeard,
  });
  bool get located => lat != null && lon != null && !(lat == 0 && lon == 0);
  bool get isOrigin => kind == 'origin';
  bool get isObserver => kind == 'observer';
  bool get isRelay => kind == 'relay' || kind == 'relay+observer';
  String get displayName =>
      name ?? (isOrigin ? 'Origin (unknown)' : (prefix != null ? 'Unknown $prefix' : shortId(id)));
}

class TraceEdge {
  final String from, to;
  final int depth;
  final double? snr, km;
  final int snrN;
  final DateTime? firstHeard;
  final bool toObserver;
  const TraceEdge({required this.from, required this.to, required this.depth, this.snr, this.km, this.snrN = 0, this.firstHeard, this.toObserver = false});
}

class TraceObservation {
  final String observerId;
  final String? observerName;
  final DateTime? time;
  final double? snr, rssi;
  final List<String> path;
  const TraceObservation({required this.observerId, this.observerName, this.time, this.snr, this.rssi, this.path = const []});
  String get observer => observerName ?? shortId(observerId);
}

class ByteRange {
  final int start, end;
  final String label, hex;

  /// header | path | payload
  final String group;
  const ByteRange(this.start, this.end, this.label, this.hex, this.group);
  int get length => end - start;
}

class TraceOrigin {
  final String? pubkey, name;
  final double? lat, lon;

  /// advert | sender | unknown
  final String kind;
  const TraceOrigin({this.pubkey, this.name, this.lat, this.lon, this.kind = 'unknown'});
}

class FloodTrace {
  final String hash;
  final DateTime? firstSeen;
  final String? payloadType;
  final TraceOrigin origin;
  final List<TraceObservation> observations;
  final List<TraceNode> nodes;
  final List<TraceEdge> edges;
  final int maxDepth, maxHops, observationCount, observerCount;
  final List<ByteRange> ranges;
  final String? bytesFromObserver;
  final int? payloadVersion;
  const FloodTrace({
    required this.hash,
    this.firstSeen,
    this.payloadType,
    required this.origin,
    required this.observations,
    required this.nodes,
    required this.edges,
    required this.maxDepth,
    required this.maxHops,
    required this.observationCount,
    required this.observerCount,
    required this.ranges,
    this.bytesFromObserver,
    this.payloadVersion,
  });

  Iterable<TraceNode> get relays => nodes.where((n) => n.isRelay);
  int get relaysIdentified => relays.where((n) => n.confidence != 'unresolved').length;
  TraceNode? get root => nodes.where((n) => n.isOrigin).firstOrNull;
  Map<String, TraceNode> get byId => {for (final n in nodes) n.id: n};

  static FloodTrace parse(Map<String, dynamic> j) {
    final pkt = jMap(j['packet']);
    final o = jMap(j['origin']);
    final tree = jMap(j['tree']);
    final bytes = jMap(j['bytes']);
    final header = jMap(jMap(j['decoded'])['header']);
    return FloodTrace(
      hash: jStr(j['hash']) ?? '',
      firstSeen: jTime(pkt['firstSeen']),
      payloadType: jStr(pkt['payloadType']),
      origin: TraceOrigin(pubkey: jStr(o['pubkey']), name: jStr(o['name']), lat: jDbl(o['lat']), lon: jDbl(o['lon']), kind: jStr(o['kind']) ?? 'unknown'),
      observations: [
        for (final m in jMaps(j['observations']))
          TraceObservation(
            observerId: jStr(m['observerId']) ?? '',
            observerName: jStr(m['observerName']),
            time: jTime(m['time']),
            snr: jDbl(m['snr']),
            rssi: jDbl(m['rssi']),
            path: [if (m['path'] is List) for (final p in m['path'] as List) if (p is String) p],
          ),
      ],
      nodes: [
        for (final n in jMaps(tree['nodes']))
          if (jStr(n['id']) != null)
            TraceNode(
              id: jStr(n['id'])!,
              pubkey: jStr(n['pubkey']),
              prefix: jStr(n['prefix']),
              name: jStr(n['name']),
              lat: jDbl(n['lat']),
              lon: jDbl(n['lon']),
              depth: jInt(n['depth']) ?? 0,
              kind: jStr(n['kind']) ?? 'relay',
              confidence: jStr(n['confidence']) ?? 'unresolved',
              firstHeard: jTime(n['firstHeard']),
            ),
      ],
      edges: [
        for (final e in jMaps(tree['edges']))
          if (jStr(e['from']) != null && jStr(e['to']) != null)
            TraceEdge(
              from: jStr(e['from'])!,
              to: jStr(e['to'])!,
              depth: jInt(e['depth']) ?? 0,
              snr: jDbl(e['snr']),
              snrN: jInt(e['snrN']) ?? 0,
              km: jDbl(e['km']),
              firstHeard: jTime(e['firstHeard']),
              toObserver: e['toObserver'] == true,
            ),
      ],
      maxDepth: jInt(tree['maxDepth']) ?? 0,
      maxHops: jInt(tree['maxHops']) ?? 0,
      observationCount: jInt(tree['observationCount']) ?? 0,
      observerCount: jInt(tree['observerCount']) ?? 0,
      ranges: [
        for (final r in jMaps(bytes['ranges']))
          if (jInt(r['start']) != null && jInt(r['end']) != null)
            ByteRange(jInt(r['start'])!, jInt(r['end'])!, jStr(r['label']) ?? '', jStr(r['hex']) ?? '', jStr(r['group']) ?? 'payload'),
      ],
      bytesFromObserver: jStr(bytes['fromObserver']),
      payloadVersion: jInt(header['payloadVersion']),
    );
  }
}

// ------------------------------------------------------------------ aggregate
class CarryRow {
  final String id;
  final int hashes;
  final double share;
  final String? name;
  const CarryRow(this.id, this.hashes, this.share, this.name);
  String get displayName => name ?? shortId(id);
}

class Corridor {
  final List<String> ids;
  final List<String?> names;
  final int hashes;
  final double share;
  const Corridor(this.ids, this.names, this.hashes, this.share);
  List<String> get labels => [for (var i = 0; i < ids.length; i++) names[i] ?? shortId(ids[i])];
}

class FloodEnd {
  final String id;
  final int hashes;
  final String? name;
  const FloodEnd(this.id, this.hashes, this.name);
  String get displayName => name ?? (id.startsWith('hop:') ? 'Unidentified ${id.substring(4)}' : shortId(id));
}

class MeasuredLink {
  final String a, b;
  final int hashes;
  const MeasuredLink(this.a, this.b, this.hashes);
}

class CollisionNode {
  final String pubkey;
  final String? name;
  final int? hashSize;
  const CollisionNode(this.pubkey, this.name, this.hashSize);
}

class CollisionCell {
  final String prefix;
  final int seenAsOneByteHop;
  final List<CollisionNode> nodes;
  const CollisionCell(this.prefix, this.seenAsOneByteHop, this.nodes);
}

class FloodAggregate {
  final int hours;
  final DateTime? since;
  final bool truncated;
  final int hashes, withRelay, observations, hops, unresolvedHops, oneByteHops;
  final List<CarryRow> carry;
  final List<Corridor> corridors;
  final List<(int hops, int hashes)> hopHistogram;
  final List<FloodEnd> ends;
  final List<MeasuredLink> links;
  final Map<String, (double lat, double lon)> locations;
  final List<CollisionCell> collisions;
  final String? collisionsError;
  final bool hasCollisionData;
  const FloodAggregate({
    required this.hours,
    this.since,
    this.truncated = false,
    required this.hashes,
    required this.withRelay,
    required this.observations,
    required this.hops,
    required this.unresolvedHops,
    required this.oneByteHops,
    this.carry = const [],
    this.corridors = const [],
    this.hopHistogram = const [],
    this.ends = const [],
    this.links = const [],
    this.locations = const {},
    this.collisions = const [],
    this.collisionsError,
    this.hasCollisionData = false,
  });

  /// Share of hops the server could pin to one repeater; null with no hops.
  double? get resolvedShare => hops == 0 ? null : 1 - unresolvedHops / hops;

  /// The hop count that half the floods stay at or under (website's median marker).
  int? get medianHops {
    var acc = 0;
    for (final h in hopHistogram) {
      acc += h.$2;
      if (acc >= hashes / 2) return h.$1;
    }
    return null;
  }

  static FloodAggregate parse(Map<String, dynamic> j) {
    final t = jMap(j['totals']);
    final c = j['collisions'];
    final cm = jMap(c);
    final locs = <String, (double, double)>{};
    jMap(j['locations']).forEach((k, v) {
      final m = jMap(v);
      final la = jDbl(m['lat']), lo = jDbl(m['lon']);
      if (la != null && lo != null && !(la == 0 && lo == 0)) locs[k] = (la, lo);
    });
    return FloodAggregate(
      hours: jInt(j['hours']) ?? 24,
      since: jTime(j['since']),
      truncated: j['truncated'] == true,
      hashes: jInt(t['hashes']) ?? 0,
      withRelay: jInt(t['withRelay']) ?? 0,
      observations: jInt(t['observations']) ?? 0,
      hops: jInt(t['hops']) ?? 0,
      unresolvedHops: jInt(t['unresolvedHops']) ?? 0,
      oneByteHops: jInt(t['oneByteHops']) ?? 0,
      carry: [
        for (final r in jMaps(j['carry']))
          if (jStr(r['id']) != null) CarryRow(jStr(r['id'])!, jInt(r['hashes']) ?? 0, jDbl(r['share']) ?? 0, jStr(r['name'])),
      ],
      corridors: [
        for (final s in jMaps(j['subpaths']))
          if (s['ids'] is List && (s['ids'] as List).isNotEmpty)
            Corridor(
              [for (final i in s['ids'] as List) '$i'],
              [for (final n in (s['names'] is List ? s['names'] as List : const [])) n is String ? n : null],
              jInt(s['hashes']) ?? 0,
              jDbl(s['share']) ?? 0,
            ),
      ],
      hopHistogram: [
        for (final h in jMaps(j['hopHistogram']))
          if (jInt(h['hops']) != null) (jInt(h['hops'])!, jInt(h['hashes']) ?? 0),
      ]..sort((a, b) => a.$1.compareTo(b.$1)),
      ends: [
        for (final e in jMaps(j['ends']))
          if (jStr(e['id']) != null) FloodEnd(jStr(e['id'])!, jInt(e['hashes']) ?? 0, jStr(e['name'])),
      ],
      links: [
        for (final l in jMaps(j['links']))
          if (jStr(l['a']) != null && jStr(l['b']) != null) MeasuredLink(jStr(l['a'])!, jStr(l['b'])!, jInt(l['hashes']) ?? 0),
      ],
      locations: locs,
      hasCollisionData: c is Map<String, dynamic>,
      collisionsError: jStr(cm['error']),
      collisions: [
        for (final cell in jMaps(cm['cells']))
          if (jStr(cell['prefix']) != null)
            CollisionCell(jStr(cell['prefix'])!, jInt(cell['seenAsOneByteHop']) ?? 0, [
              for (final n in jMaps(cell['nodes']))
                if (jStr(n['pubkey']) != null) CollisionNode(jStr(n['pubkey'])!, jStr(n['name']), jInt(n['hashSize'])),
            ]),
      ],
    );
  }
}

// ------------------------------------------------------------------ client
class FloodRoutesApi {
  final String baseUrl;
  final http.Client? client;
  FloodRoutesApi(this.baseUrl, {this.client});

  Uri uri(Map<String, String> q) => regionDatasetUri(baseUrl, 'tool-routes', q);
  Future<RegionFetch<RecentFloods>> recent() => fetchRegionDataset(uri({'action': 'recent'}), RecentFloods.parse, client: client, timeout: const Duration(seconds: 40));
  Future<RegionFetch<FloodTrace>> trace(String hash) =>
      fetchRegionDataset(uri({'action': 'trace', 'hash': hash}), FloodTrace.parse, client: client, timeout: const Duration(seconds: 40));
  Future<RegionFetch<FloodAggregate>> aggregate(int hours) =>
      fetchRegionDataset(uri({'action': 'aggregate', 'hours': '${hours == 168 ? 168 : 24}'}), FloodAggregate.parse, client: client, timeout: const Duration(seconds: 60));
}
