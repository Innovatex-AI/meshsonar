// The Tools reads of the public `/v1` API (build 71, stream D), on the shared [V1Client]:
//   POST /v1/tools/path-inspect      Path Inspector: the full routes a list of hop prefixes most likely stands for
//   GET  /v1/traces/{hash}           Trace Viewer: targets, per-hop SNR, who heard it
//   GET  /v1/packets?type=TRACE      the region's recent traces (the Trace Viewer's list)
//   GET  /v1/insights/hashes/prefix  Prefix Tool: is a hash prefix free, what is taken nearby, suggestions
// Shapes follow the site (meshcore-insights src/server/v1/endpoints/tools.ts, src/lib/analyzer/insights-types.ts and
// src/components/tools/path-inspector.tsx). Parsers are tolerant: a missing or oddly typed field becomes null or an
// empty list, never an exception, because `/v1/traces` had no live TRACE to check against when this was written.
//
// Pure Dart: no Flutter imports.
import 'package:http/http.dart' as http;

import 'packet_models.dart' show HopConfidence, PacketListRow, hopConfidenceOf;
import 'v1_client.dart';

export 'v1_client.dart' show V1Error, V1NotLive;

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;
double? _num(Object? v) => v is num ? v.toDouble() : null;
int? _int(Object? v) => v is num ? v.toInt() : null;
List<Object?> _list(Object? v) => v is List ? v : const [];

/// A node as the tools name it: key, name, role.
class ToolNode {
  final String key;
  final String? name;
  final String role;
  const ToolNode({required this.key, this.name, this.role = 'unknown'});

  /// The name, or the first 8 hex of the key when it has none.
  String get label => name ?? (key.length > 8 ? key.substring(0, 8) : key);

  static ToolNode? tryParse(Object? j) {
    if (j is! Map || j['key'] is! String || (j['key'] as String).isEmpty) return null;
    return ToolNode(key: (j['key'] as String).toLowerCase(), name: _str(j['name']), role: _str(j['role']) ?? 'unknown');
  }
}

// ---------------------------------------------------------------- path inspector

class PathHop {
  final String prefix;

  /// Null when no known node has this prefix.
  final ToolNode? node;

  /// 0..1; null when the server gave none.
  final double? hopScore;
  const PathHop({required this.prefix, this.node, this.hopScore});

  static PathHop? tryParse(Object? j) {
    if (j is! Map || j['prefix'] is! String) return null;
    return PathHop(prefix: j['prefix'] as String, node: ToolNode.tryParse(j['node']), hopScore: _num(j['hopScore']));
  }
}

class PathCandidate {
  final int rank;

  /// 0..1.
  final double score;

  /// Under the server's `speculativeBelow`: a guess, said so on screen.
  final bool speculative;
  final List<PathHop> hops;
  final double? totalKm;
  const PathCandidate({required this.rank, required this.score, required this.speculative, required this.hops, this.totalKm});

  static PathCandidate? tryParse(Object? j) {
    if (j is! Map) return null;
    return PathCandidate(
      rank: _int(j['rank']) ?? 0,
      score: _num(j['score']) ?? 0,
      speculative: j['speculative'] == true,
      hops: [for (final h in _list(j['hops'])) ?PathHop.tryParse(h)],
      totalKm: _num(j['totalKm']),
    );
  }
}

class PathInspectResult {
  final List<PathCandidate> candidates;
  final double? speculativeBelow;

  /// Hop prefixes no known node matches (the live server sends a list; a bare count is read as that many unnamed hops).
  final List<String> unknownHops;
  const PathInspectResult({required this.candidates, this.speculativeBelow, this.unknownHops = const []});

  static PathInspectResult parse(Object? j) {
    if (j is! Map) throw const FormatException('path-inspect data is not an object');
    return PathInspectResult(
      candidates: [for (final c in _list(j['candidates'])) ?PathCandidate.tryParse(c)],
      speculativeBelow: _num(j['speculativeBelow']),
      unknownHops: j['unknownHops'] is num ? List.filled((j['unknownHops'] as num).toInt().clamp(0, 64), '?') : [for (final u in _list(j['unknownHops'])) '$u'],
    );
  }
}

/// The hop list a person typed, or why it cannot be read.
class HopInput {
  final List<String> hops;
  final int hashSize;
  final String? error;
  const HopInput.ok(this.hops, this.hashSize) : error = null;
  const HopInput.bad(String this.error)
      : hops = const [],
        hashSize = 1;
  bool get ok => error == null;
}

final _hopSplit = RegExp(r'(?:\s|,|;|>|→|->|-)+');
final _hex = RegExp(r'^[0-9a-f]+$');

/// Reads "a1, b2 c3", "a1 > b2 → c3" or "a1b2c3" (cut by [hashSize]). Hops are 1, 2 or 3 bytes, all the same size:
/// when they are typed apart their own length decides the size; one unbroken string is cut by [hashSize].
HopInput parseHopInput(String raw, {int hashSize = 1}) {
  final text = raw.trim().toLowerCase();
  if (text.isEmpty) return const HopInput.bad('Type at least one hop prefix.');
  var parts = [for (final p in text.split(_hopSplit)) if (p.isNotEmpty) p];
  final notHex = parts.where((p) => !_hex.hasMatch(p)).firstOrNull;
  if (notHex != null) return HopInput.bad('"$notHex" is not hex. Use the digits 0-9 and letters a-f.');
  var size = hashSize;
  if (parts.length == 1) {
    final one = parts.single;
    if (one.length > size * 2) {
      if (one.length % (size * 2) != 0) return HopInput.bad('${one.length} hex characters cannot be cut into $size-byte hops. Put spaces between the hops.');
      parts = [for (var i = 0; i < one.length; i += size * 2) one.substring(i, i + size * 2)];
    } else if (const {2, 4, 6}.contains(one.length)) {
      size = one.length ~/ 2;
    }
  } else {
    final len = parts.first.length;
    if (const {2, 4, 6}.contains(len) && parts.every((p) => p.length == len)) size = len ~/ 2;
  }
  if (parts.length > 64) return const HopInput.bad('At most 64 hops.');
  final bad = parts.where((p) => p.length != size * 2).firstOrNull;
  if (bad != null) return HopInput.bad('"$bad" is not a $size-byte prefix (${size * 2} hex characters).');
  return HopInput.ok(parts, size);
}

// ---------------------------------------------------------------- trace viewer

class TraceHop {
  final int index;
  final String prefix;
  final HopConfidence confidence;
  final ToolNode? node;

  /// SNR at which this hop heard the trace; null when the trace did not get this far or the bytes were not kept.
  final double? snrDb;
  const TraceHop({required this.index, required this.prefix, required this.confidence, this.node, this.snrDb});

  static TraceHop? tryParse(Object? j, int at) {
    if (j is! Map || j['prefix'] is! String) return null;
    return TraceHop(
      index: _int(j['index']) ?? at,
      prefix: j['prefix'] as String,
      confidence: hopConfidenceOf(_str(j['confidence'])),
      node: ToolNode.tryParse(j['node']),
      snrDb: _num(j['snrDb']),
    );
  }
}

class TraceObservation {
  final String observerId;
  final String? observerName;

  /// `fixed`, `phone` or `outside`.
  final String observerKind;
  final DateTime? at;
  final double? snr, rssi;
  final int? hopsCompleted;
  const TraceObservation({required this.observerId, this.observerName, this.observerKind = 'fixed', this.at, this.snr, this.rssi, this.hopsCompleted});

  static TraceObservation? tryParse(Object? j) {
    if (j is! Map) return null;
    final o = j['observer'];
    if (o is! Map || o['id'] is! String) return null;
    return TraceObservation(
      observerId: o['id'] as String,
      observerName: _str(o['name']),
      observerKind: _str(o['kind']) ?? 'fixed',
      at: v1Time(j['at']),
      snr: _num(j['snr']),
      rssi: _num(j['rssi']),
      hopsCompleted: _int(j['hopsCompleted']),
    );
  }
}

class TraceView {
  final String hash;
  final String? tag;
  final List<String> targets;
  final int hashSize;
  final List<TraceHop> hops;

  /// Hops the trace got through, and whether that is all of them.
  final int completed;
  final bool complete;
  final List<TraceObservation> observations;

  /// Time between the first and the last observation.
  final Duration spread;

  /// The packet ids of the same trace at other hop counts (`meta.copies`).
  final List<String> copies;

  /// `meta.status.reason` when the answer is partial (the bytes were not kept).
  final String? note;
  const TraceView({
    required this.hash,
    this.tag,
    this.targets = const [],
    this.hashSize = 0,
    this.hops = const [],
    this.completed = 0,
    this.complete = false,
    this.observations = const [],
    this.spread = Duration.zero,
    this.copies = const [],
    this.note,
  });

  static TraceView parse(Object? j) {
    if (j is! Map || j['hash'] is! String) throw const FormatException('trace data has no hash');
    final hops = <TraceHop>[];
    final raw = _list(j['hops']);
    for (var i = 0; i < raw.length; i++) {
      final h = TraceHop.tryParse(raw[i], i);
      if (h != null) hops.add(h);
    }
    final targets = [for (final t in _list(j['targets'])) if (t is String) t];
    final completed = _int(j['completed']) ?? 0;
    return TraceView(
      hash: (j['hash'] as String).toLowerCase(),
      tag: j['tag'] is num ? '${j['tag']}' : _str(j['tag']),
      targets: targets,
      hashSize: _int(j['hashSize']) ?? 0,
      hops: hops,
      completed: completed,
      complete: j['complete'] is bool ? j['complete'] as bool : (targets.isNotEmpty && completed >= targets.length),
      observations: [for (final o in _list(j['observations'])) ?TraceObservation.tryParse(o)],
      spread: Duration(milliseconds: _int(j['spreadMs']) ?? 0),
    );
  }

  TraceView _withMeta(V1Meta meta) => TraceView(
        hash: hash,
        tag: tag,
        targets: targets,
        hashSize: hashSize,
        hops: hops,
        completed: completed,
        complete: complete,
        observations: observations,
        spread: spread,
        copies: [for (final c in _list(meta.raw['copies'])) if (c is String) c],
        note: meta.status.reason,
      );
}

/// One row of the recent-traces list.
class RecentTrace {
  final String hash;
  final DateTime firstSeen;
  final int hops;
  final int? observations;
  const RecentTrace({required this.hash, required this.firstSeen, required this.hops, this.observations});
}

// ---------------------------------------------------------------- prefix tool

class PrefixCheck {
  /// 1, 2 or 3.
  final int bytes;

  /// The prefix at this size; null when the query was shorter than this size.
  final String? prefix;
  final bool free, reserved;
  final List<ToolNode> conflicts;
  final double? nearestConflictKm;
  const PrefixCheck({required this.bytes, this.prefix, required this.free, this.reserved = false, this.conflicts = const [], this.nearestConflictKm});

  static PrefixCheck? tryParse(Object? j) {
    if (j is! Map || j['bytes'] is! num) return null;
    return PrefixCheck(
      bytes: (j['bytes'] as num).toInt(),
      prefix: _str(j['prefix']),
      free: j['free'] == true,
      reserved: j['reserved'] == true,
      conflicts: [for (final c in _list(j['conflicts'])) ?ToolNode.tryParse(c)],
      nearestConflictKm: _num(j['nearestConflictKm']),
    );
  }
}

class PrefixSuggestion {
  final int bytes;
  final String prefix;
  final double? nearestUseKm;
  const PrefixSuggestion({required this.bytes, required this.prefix, this.nearestUseKm});

  static PrefixSuggestion? tryParse(Object? j) {
    if (j is! Map || j['bytes'] is! num || j['prefix'] is! String) return null;
    return PrefixSuggestion(bytes: (j['bytes'] as num).toInt(), prefix: j['prefix'] as String, nearestUseKm: _num(j['nearestUseKm']));
  }
}

class PrefixReport {
  final String? query;
  final List<PrefixCheck> checks;
  final List<PrefixSuggestion> suggestions;

  /// Free 1-byte prefixes left in the area (the larger sizes are not counted by the server).
  final int? freeOneByte;
  final int? repeaters;

  /// `1` or `2`: the hash size the server recommends here.
  final String? recommendation;
  final String? overviewNote, note;
  final double? radiusKm;
  const PrefixReport({this.query, this.checks = const [], this.suggestions = const [], this.freeOneByte, this.repeaters, this.recommendation, this.overviewNote, this.note, this.radiusKm});

  static PrefixReport parse(Object? j) {
    if (j is! Map) throw const FormatException('prefix data is not an object');
    final o = j['overview'], a = j['available'], c = j['center'];
    return PrefixReport(
      query: _str(j['query']),
      checks: [for (final x in _list(j['checks'])) ?PrefixCheck.tryParse(x)],
      suggestions: [for (final x in _list(j['suggestions'])) ?PrefixSuggestion.tryParse(x)],
      freeOneByte: a is Map ? _int(a['1']) : null,
      repeaters: o is Map ? _int(o['repeaters']) : null,
      recommendation: o is Map ? _str(o['recommendation']) : null,
      overviewNote: o is Map ? _str(o['note']) : null,
      note: _str(j['note']),
      radiusKm: c is Map ? _num(c['radiusKm']) : null,
    );
  }
}

/// Null when [raw] is a prefix the tool takes (2, 4 or 6 hex, or a 64-hex key); else the reason.
String? prefixInputError(String raw) {
  final p = raw.trim().toLowerCase();
  if (p.isEmpty) return null;
  if (!_hex.hasMatch(p)) return 'Use hex only: the digits 0-9 and letters a-f.';
  if (!const {2, 4, 6, 64}.contains(p.length)) return 'Type 2, 4 or 6 hex characters, or a whole 64-character key.';
  return null;
}

// ---------------------------------------------------------------- client

class ToolsApi {
  final String baseUrl;
  final V1Client v1;
  ToolsApi(this.baseUrl, {http.Client? client, DateTime Function()? clock}) : v1 = V1Client(baseUrl, client: client, clock: clock);

  /// The routes [hops] most likely stand for, best first. One region only (the region host). Throws [V1Error] /
  /// [V1NotLive].
  Future<PathInspectResult> pathInspect(List<String> hops, {required int hashSize, String? observer}) async {
    final env = await v1.post('tools/path-inspect', {'hops': hops, 'hashSize': hashSize, if (observer != null && observer.isNotEmpty) 'observer': observer}, PathInspectResult.parse);
    return env.data;
  }

  /// One TRACE. A hash the server does not have, or one that is not a TRACE, is a [V1Error] with `notFound`.
  Future<TraceView> trace(String hash) async {
    final env = await v1.get('traces/${Uri.encodeComponent(hash.trim().toLowerCase())}', TraceView.parse);
    return env.data._withMeta(env.meta);
  }

  /// The region's TRACE packets of the last 7 days, newest first.
  Future<List<RecentTrace>> recentTraces({int limit = 30}) async {
    final env = await v1.getPage('packets', PacketListRow.tryParse, query: const {'type': 'TRACE', 'window': '7d', 'groupBy': 'hash'}, limit: limit);
    return [for (final r in env.data) RecentTrace(hash: r.hash, firstSeen: r.firstSeen, hops: r.hops, observations: r.observationCount)];
  }

  /// The prefix report for the region; with [prefix] (2, 4 or 6 hex, or a key) it also says whether that one is free.
  Future<PrefixReport> prefix({String? prefix, double? lat, double? lon}) async {
    final p = prefix?.trim().toLowerCase();
    final env = await v1.get('insights/hashes/prefix', PrefixReport.parse,
        query: {'prefix': p == null || p.isEmpty ? null : p, 'lat': lat?.toString(), 'lon': lon?.toString()});
    return env.data;
  }

  void close() => v1.close();
}

/// Replaced by widget tests.
ToolsApi Function(String baseUrl) toolsApiFactory = (b) => ToolsApi(b);
