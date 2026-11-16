// What the Planner works out about a plan on the phone (release 0.38 improvements 7, 8, 15, 16): the link matrix (every
// pair of up to [linkMatrixMaxNodes] nodes), "how many nodes see this spot", the relay finder, snap-to-high-ground, node
// classes (critical / backbone / redundant / marginal, from E8 network facts and line-of-sight peers) and the calibration
// confidence line ("412 drive cells within 2 km" or "unobserved, estimate"), and the verify loop (improvement 20: an installed
// node's plan-verify prediction against measured cells, [compareVerifyWithMeasured]). Terrain comes in through a [ProfileSource]
// (PlanApi.profile: score-link, else plan-link, each with its stored copies); every number is the on-device model
// (link_model.dart) for the plan's radio and clutter, so changing a height or the radio needs no new request. Pure Dart.
import 'dart:convert' show base64;
import 'dart:math' as math;

import '../plan_contract.dart';
import 'link_model.dart';
import 'plan_api.dart' show PlanResult, ScoredProfile;
import 'plan_model.dart';

/// The bare-earth profile from [a] to [b] (samples evenly spaced, A first).
typedef ProfileSource = Future<PlanResult<ScoredProfile>> Function(PlanPoint a, PlanPoint b);

/// The link matrix covers at most this many nodes (45 pairs); larger plans pick which ones (build plan section 12).
const int linkMatrixMaxNodes = 10;

/// One node to another over [profile], judged with each node's own height, power and gain and the plan's radio.
PlanLinkResult judgeLink(Plan plan, PlanNode a, PlanNode b, ScoredProfile profile, {PlanDirection direction = PlanDirection.both, DateTime? asOf}) =>
    localPlanLink(
      PlanLinkRequest(
        a: a.point,
        b: b.point,
        haM: a.antennaM,
        hbM: b.antennaM,
        radio: plan.radio,
        clutter: plan.clutter,
        direction: direction,
        aKey: a.existingKey,
        bKey: b.existingKey,
      ),
      profile.groundM,
      km: profile.km,
      aTxDbm: a.effectiveTxDbm,
      bTxDbm: b.effectiveTxDbm,
      aGainDbi: a.effectiveGainDbi,
      bGainDbi: b.effectiveGainDbi,
      terrain: profile.source,
      asOf: asOf,
    );

/// A line of sight with no ground above the straight antenna line (the first Fresnel zone may still be partly blocked).
bool hasLineOfSight(PlanLinkResult r) => (r.fresnelClearancePct ?? -1) >= 0;

class PlanPairLink {
  final String aId, bId;
  final PlanLinkResult? result;
  final String? error;

  /// The terrain behind [result] is a stored copy fetched at this time (no connection now).
  final DateTime? offlineAsOf;
  const PlanPairLink({required this.aId, required this.bId, this.result, this.error, this.offlineAsOf});
  PlanVerdict? get verdict => result?.verdict;
}

class LinkMatrix {
  /// The nodes the matrix covers, in plan order.
  final List<String> nodeIds;
  final Map<String, PlanPairLink> _links;

  /// The plan has more nodes than the matrix covers.
  final bool truncated;
  LinkMatrix(this.nodeIds, Map<String, PlanPairLink> links, {this.truncated = false}) : _links = Map.unmodifiable(links);

  static String _key(String a, String b) => a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';
  PlanPairLink? between(String a, String b) => _links[_key(a, b)];
  Iterable<PlanPairLink> get links => _links.values;

  /// The ids [id] links to with at least [atLeast] (likely by default).
  Set<String> peersOf(String id, {PlanVerdict atLeast = PlanVerdict.likely}) => {
        for (final l in _links.values)
          if ((l.aId == id || l.bId == id) && l.verdict != null && _rank(l.verdict!) >= _rank(atLeast)) l.aId == id ? l.bId : l.aId,
      };
}

int _rank(PlanVerdict v) => switch (v) {
      PlanVerdict.likely => 2,
      PlanVerdict.marginal => 1,
      PlanVerdict.unlikely => 0,
    };

/// Every pair among the plan's first [linkMatrixMaxNodes] nodes (or the ones in [only], in plan order, at most that
/// many). Profiles are fetched [concurrency] at a time; a pair whose terrain cannot be had carries the reason.
Future<LinkMatrix> buildLinkMatrix(Plan plan, ProfileSource profile, {Iterable<String>? only, int concurrency = 3}) async {
  final pick = only?.toSet();
  final pool = [for (final n in plan.nodes) if (pick == null || pick.contains(n.id)) n];
  final nodes = pool.take(linkMatrixMaxNodes).toList();
  final pairs = <(PlanNode, PlanNode)>[
    for (var i = 0; i < nodes.length; i++)
      for (var j = i + 1; j < nodes.length; j++) (nodes[i], nodes[j]),
  ];
  final out = <String, PlanPairLink>{};
  var next = 0;
  Future<void> worker() async {
    while (next < pairs.length) {
      final (a, b) = pairs[next++];
      final p = await profile(a.point, b.point);
      out[LinkMatrix._key(a.id, b.id)] = p.ok
          ? PlanPairLink(aId: a.id, bId: b.id, result: judgeLink(plan, a, b, p.data!, asOf: p.at), offlineAsOf: p.offlineAsOf)
          : PlanPairLink(aId: a.id, bId: b.id, error: p.error);
    }
  }

  await Future.wait([for (var i = 0; i < math.max(1, concurrency); i++) worker()]);
  return LinkMatrix([for (final n in nodes) n.id], out, truncated: pool.length > nodes.length);
}

/// How many of the plan's repeater nodes are likely to be heard at [spot] by a receiver [receiverM] above ground
/// ("how many repeaters see this spot").
Future<int> nodesSeeing(Plan plan, PlanPoint spot, ProfileSource profile, {double receiverM = handheldHeightM}) async {
  final rx = PlanNode(id: '_spot', name: 'Spot', lat: spot.lat, lon: spot.lon, heightM: receiverM, role: PlanNodeRole.handheld);
  var n = 0;
  for (final node in plan.nodes.where((x) => x.role == PlanNodeRole.repeater).take(Plan.maxNodes)) {
    if (haversineKm(node.lat, node.lon, spot.lat, spot.lon) < 0.01) {
      n++;
      continue;
    }
    final p = await profile(node.point, spot);
    if (!p.ok) continue;
    if (judgeLink(plan, node, rx, p.data!, direction: PlanDirection.down).verdict == PlanVerdict.likely) n++;
  }
  return n;
}

// ---------------------------------------------------------------- geometry helpers
const double _mPerDegLat = 111320;
double _mPerDegLon(double lat) => _mPerDegLat * math.cos(lat * math.pi / 180);

/// [p] moved [northM] metres north and [eastM] metres east.
PlanPoint offsetM(PlanPoint p, double northM, double eastM) => PlanPoint(p.lat + northM / _mPerDegLat, p.lon + eastM / _mPerDegLon(p.lat));

double distanceM(PlanPoint a, PlanPoint b) => haversineKm(a.lat, a.lon, b.lat, b.lon) * 1000;

/// The profile's samples on the map: sample i sits i/(n-1) of the way from [a] to [b].
List<(PlanPoint, double)> profileSamples(PlanPoint a, PlanPoint b, ScoredProfile p) {
  final n = p.groundM.length;
  return [
    for (var i = 0; i < n; i++) (PlanPoint(a.lat + (b.lat - a.lat) * i / (n - 1), a.lon + (b.lon - a.lon) * i / (n - 1)), p.groundM[i]),
  ];
}

// ---------------------------------------------------------------- snap to high ground
class SnapResult {
  final PlanPoint at;
  final double groundM;

  /// Metres higher than the ground at the starting point (null when that was not sampled).
  final double? gainM;
  final double distanceM;
  const SnapResult({required this.at, required this.groundM, required this.distanceM, this.gainM});
}

/// The highest of [samples] within [radiusM] of [from] (ties: the nearest). Null when none is in range.
SnapResult? highestSample(PlanPoint from, double radiusM, Iterable<(PlanPoint, double)> samples) {
  (PlanPoint, double, double)? best;
  double? startGround;
  var startD = double.infinity;
  for (final (p, g) in samples) {
    final d = distanceM(from, p);
    if (d < startD) {
      startD = d;
      startGround = d <= 15 ? g : null;
    }
    if (d > radiusM) continue;
    if (best == null || g > best.$2 || (g == best.$2 && d < best.$3)) best = (p, g, d);
  }
  if (best == null) return null;
  return SnapResult(at: best.$1, groundM: best.$2, distanceM: best.$3, gainM: startGround == null ? null : best.$2 - startGround);
}

/// "Snap to the highest point within [radiusM]": samples the terrain along [radials] straight lines out of [from]
/// (one profile each, cached like any other) and returns the highest point found. Null when no terrain could be had.
Future<SnapResult?> snapToHighGround(PlanPoint from, double radiusM, ProfileSource profile, {int radials = 8}) async {
  final samples = <(PlanPoint, double)>[];
  for (var i = 0; i < radials; i++) {
    final az = 2 * math.pi * i / radials;
    final edge = offsetM(from, radiusM * math.cos(az), radiusM * math.sin(az));
    final p = await profile(from, edge);
    if (p.ok) samples.addAll(profileSamples(from, edge, p.data!));
  }
  return samples.isEmpty ? null : highestSample(from, radiusM, samples);
}

// ---------------------------------------------------------------- relay finder
class RelayCandidate {
  final PlanPoint at;
  final double? groundM;

  /// The links from A to the relay and from the relay to B, at [relayHeightM].
  final PlanLinkResult toA, toB;
  final double relayHeightM;
  const RelayCandidate({required this.at, this.groundM, required this.toA, required this.toB, required this.relayHeightM});

  /// Both hops have a clear line of sight.
  bool get dualLineOfSight => hasLineOfSight(toA) && hasLineOfSight(toB);

  /// The weaker hop's margin after the fade margin.
  double get worstMarginDb => math.min(toA.marginDb ?? -999, toB.marginDb ?? -999);
  PlanVerdict get verdict => verdictOf(worstMarginDb);
}

/// When A-B fails, the points that would relay it, best first: dual line of sight first, then the weaker hop's margin.
/// Candidates are the high points of the A-B profile ([abProfile]), points either side of the midpoint, and any
/// [extra] (Find sites results, the person's picks); at most [maxCandidates] are checked (two profiles each).
Future<List<RelayCandidate>> findRelays(
  Plan plan,
  PlanNode a,
  PlanNode b,
  ProfileSource profile, {
  ScoredProfile? abProfile,
  Iterable<PlanPoint> extra = const [],
  double relayHeightM = plannedHeightM,
  int maxCandidates = 8,
  int top = 3,
}) async {
  final cands = <PlanPoint>[...extra];
  if (abProfile != null) {
    final s = profileSamples(a.point, b.point, abProfile);
    final inner = [for (var i = 1; i < s.length - 1; i++) (i, s[i].$2)];
    inner.sort((x, y) => y.$2.compareTo(x.$2));
    cands.addAll([for (final (i, _) in inner.take(4)) s[i].$1]);
  }
  final mid = PlanPoint((a.lat + b.lat) / 2, (a.lon + b.lon) / 2);
  final dN = (b.lat - a.lat) * _mPerDegLat, dE = (b.lon - a.lon) * _mPerDegLon(mid.lat);
  final len = math.sqrt(dN * dN + dE * dE);
  cands.add(mid);
  if (len > 0) {
    for (final f in const [0.25, -0.25]) {
      cands.add(offsetM(mid, -dE * f, dN * f)); // a quarter of the path length either side
    }
  }
  // Drop near-duplicates (within 200 m) and points on top of the ends.
  final unique = <PlanPoint>[];
  for (final c in cands) {
    if (distanceM(c, a.point) < 200 || distanceM(c, b.point) < 200) continue;
    if (unique.any((u) => distanceM(u, c) < 200)) continue;
    unique.add(c);
    if (unique.length >= maxCandidates) break;
  }
  final out = <RelayCandidate>[];
  for (final c in unique) {
    final relay = PlanNode(id: '_relay', name: 'Relay', lat: c.lat, lon: c.lon, heightM: relayHeightM);
    final pa = await profile(a.point, c);
    if (!pa.ok) continue;
    final pb = await profile(c, b.point);
    if (!pb.ok) continue;
    out.add(RelayCandidate(
      at: c,
      groundM: pa.data!.groundM.last,
      toA: judgeLink(plan, a, relay, pa.data!),
      toB: judgeLink(plan, relay, b, pb.data!),
      relayHeightM: relayHeightM,
    ));
  }
  out.sort((x, y) {
    if (x.dualLineOfSight != y.dualLineOfSight) return x.dualLineOfSight ? -1 : 1;
    return y.worstMarginDb.compareTo(x.worstMarginDb);
  });
  return out.take(top).toList();
}

// ---------------------------------------------------------------- node classes
enum PlanNodeClass {
  /// Losing it strands other nodes.
  critical('Critical'),

  /// Links to three or more nodes.
  backbone('Backbone'),

  /// Two links: losing one still leaves a path.
  redundant('Redundant'),

  /// One link or none, or only marginal ones.
  marginal('Marginal');

  final String label;
  const PlanNodeClass(this.label);
}

/// What the server's network analysis (E8 components and critical nodes, E5 links) says, by public key.
class NetworkFacts {
  /// Repeaters whose loss strands others from the largest component, with how many they strand.
  final Map<String, int> criticalStranded;

  /// Links each repeater has on the network (E5), by key.
  final Map<String, Set<String>> peers;
  const NetworkFacts({this.criticalStranded = const {}, this.peers = const {}});
}

class NodeClassification {
  final PlanNodeClass cls;
  final String reason;

  /// Nodes it links to (plan links that are likely plus network links).
  final int peers;
  const NodeClassification(this.cls, this.reason, this.peers);
}

/// The class of every plan node: E8's critical list first, then the articulation points of the plan's likely-link
/// graph, then the number of peers (likely plan links + E5 network links).
Map<String, NodeClassification> classifyNodes(Plan plan, {LinkMatrix? matrix, NetworkFacts facts = const NetworkFacts()}) {
  final ids = [for (final n in plan.nodes) n.id];
  final likely = {for (final id in ids) id: matrix?.peersOf(id) ?? <String>{}};
  final marginalPeers = {for (final id in ids) id: matrix?.peersOf(id, atLeast: PlanVerdict.marginal) ?? <String>{}};
  final cut = _articulationPoints(ids, likely);
  final keyOfId = {for (final n in plan.nodes) n.id: n.existingKey};
  final out = <String, NodeClassification>{};
  for (final n in plan.nodes) {
    final networkPeers = n.existingKey == null ? <String>{} : (facts.peers[n.existingKey] ?? const <String>{});
    // A plan peer that is also a network peer counts once.
    final planPeerKeys = {for (final p in likely[n.id]!) keyOfId[p] ?? 'id:$p'};
    final peers = {...planPeerKeys, ...networkPeers}.length;
    final stranded = n.existingKey == null ? 0 : (facts.criticalStranded[n.existingKey] ?? 0);
    if (stranded > 0) {
      out[n.id] = NodeClassification(PlanNodeClass.critical, 'Strands $stranded ${stranded == 1 ? 'repeater' : 'repeaters'} if it goes down', peers);
    } else if (cut.contains(n.id)) {
      out[n.id] = NodeClassification(PlanNodeClass.critical, 'The only link between parts of this plan', peers);
    } else if (peers >= 3) {
      out[n.id] = NodeClassification(PlanNodeClass.backbone, 'Links to $peers nodes', peers);
    } else if (peers == 2) {
      out[n.id] = NodeClassification(PlanNodeClass.redundant, 'Two links: one can fail', peers);
    } else if (peers == 0 && marginalPeers[n.id]!.isNotEmpty) {
      out[n.id] = NodeClassification(PlanNodeClass.marginal, 'Only marginal links', peers);
    } else {
      out[n.id] = NodeClassification(PlanNodeClass.marginal, peers == 1 ? 'Reaches only 1 node' : 'Reaches no other node', peers);
    }
  }
  return out;
}

/// Articulation points (Tarjan) of an undirected graph; only meaningful with three or more nodes.
Set<String> _articulationPoints(List<String> ids, Map<String, Set<String>> adj) {
  if (ids.length < 3) return const {};
  final disc = <String, int>{}, low = <String, int>{};
  final cut = <String>{};
  var time = 0;
  void dfs(String u, String? parent) {
    disc[u] = low[u] = time++;
    var children = 0;
    for (final v in adj[u] ?? const <String>{}) {
      if (!disc.containsKey(v)) {
        children++;
        dfs(v, u);
        low[u] = math.min(low[u]!, low[v]!);
        if (parent != null && low[v]! >= disc[u]!) cut.add(u);
      } else if (v != parent) {
        low[u] = math.min(low[u]!, disc[v]!);
      }
    }
    if (parent == null && children > 1) cut.add(u);
  }

  for (final id in ids) {
    if (!disc.containsKey(id)) dfs(id, null);
  }
  return cut;
}

// ---------------------------------------------------------------- calibration confidence
class CalibrationConfidence {
  /// Measured drive cells within [radiusKm] of the spot.
  final int driveCells;
  final double radiusKm;
  const CalibrationConfidence(this.driveCells, this.radiusKm);

  bool get observed => driveCells > 0;

  /// "412 drive cells within 2 km" or "unobserved, estimate".
  String get text {
    if (driveCells == 0) return 'unobserved, estimate';
    final r = radiusKm == radiusKm.roundToDouble() ? radiusKm.toStringAsFixed(0) : radiusKm.toStringAsFixed(1);
    return '$driveCells drive ${driveCells == 1 ? 'cell' : 'cells'} within $r km';
  }
}

/// How well our own drives cover the ground around [at]: the measured cells (their centres) within [radiusKm].
CalibrationConfidence calibrationConfidence(PlanPoint at, Iterable<PlanPoint> driveCellCentres, {double radiusKm = 2}) {
  // A cheap box test first: most cells of a region are far away.
  final dLat = radiusKm * 1000 / _mPerDegLat, dLon = radiusKm * 1000 / _mPerDegLon(at.lat);
  var n = 0;
  for (final c in driveCellCentres) {
    if ((c.lat - at.lat).abs() > dLat || (c.lon - at.lon).abs() > dLon) continue;
    if (haversineKm(at.lat, at.lon, c.lat, c.lon) <= radiusKm) n++;
  }
  return CalibrationConfidence(n, radiusKm);
}

// ---------------------------------------------------------------- verify loop (improvement 20)
/// Fewer measured cells inside a prediction than this is "not enough data" to judge it.
const int verifyMinCells = 5;

/// One measured coverage cell (drives and observers): its centre, whether anything was heard there, its SNR when read.
class PlanMeasuredCell {
  final PlanPoint at;
  final bool heard;
  final double? snr;
  const PlanMeasuredCell(this.at, {required this.heard, this.snr});
}

/// A plan-verify prediction for an installed node next to what was measured around it.
class VerifyComparison {
  /// Measured cells inside the prediction's sweep (the cells compared).
  final int compared;

  /// Predicted covered (margin >= 0) and heard / predicted covered but nothing heard.
  final int coveredHeard, coveredSilent;

  /// Heard although the prediction says no decode there (measured outside the prediction) / quiet where it said so too.
  final int heardOutside, quietOutside;

  /// Mean measured and predicted SNR over the heard cells with a reading, dB (null = none).
  final double? measuredSnr, predictedSnr;
  final int minCells;
  const VerifyComparison({
    required this.compared,
    required this.coveredHeard,
    required this.coveredSilent,
    required this.heardOutside,
    required this.quietOutside,
    this.measuredSnr,
    this.predictedSnr,
    this.minCells = verifyMinCells,
  });

  /// Enough measured cells to say anything.
  bool get enough => compared >= minCells;

  /// Share of compared cells where prediction and measurement agree, percent.
  double get agreePct => compared == 0 ? 0 : 100 * (coveredHeard + quietOutside) / compared;

  /// Predicted minus measured SNR (positive = the prediction is more hopeful than the drives).
  double? get biasDb => measuredSnr == null || predictedSnr == null ? null : predictedSnr! - measuredSnr!;
}

/// The margin (dB over sensitivity) the coverage run in [r] predicts at a point, read from its 0.5 dB `grid` (radials x
/// samples around [site], default the run's own `params` position). Null when the answer carries no usable grid.
double? Function(PlanPoint at)? predictedMarginSampler(PlanVerifyResult r, {PlanPoint? site}) {
  final g = r.raw['grid'], params = r.raw['params'];
  if (g is! Map) return null;
  final radials = (g['radials'] as num?)?.round(), n = (g['n'] as num?)?.round(), step = (g['stepM'] as num?)?.toDouble();
  final b64 = g['margin'], scale = (g['scale'] as num?)?.toDouble() ?? 0.5;
  final at = site ?? (params is Map && params['lat'] is num && params['lon'] is num ? PlanPoint((params['lat'] as num).toDouble(), (params['lon'] as num).toDouble()) : null);
  if (radials == null || n == null || step == null || step <= 0 || b64 is! String || at == null || radials < 1 || n < 1) return null;
  final List<int> bytes;
  try {
    bytes = base64.decode(b64);
  } on FormatException {
    return null;
  }
  if (bytes.length != radials * n) return null;
  final mLon = _mPerDegLon(at.lat);
  return (p) {
    final dy = (p.lat - at.lat) * _mPerDegLat, dx = (p.lon - at.lon) * mLon;
    final d = math.sqrt(dx * dx + dy * dy);
    if (d > (n + 0.5) * step) return null;
    final j = (d / step).round().clamp(1, n);
    var brg = math.atan2(dx, dy) * 180 / math.pi;
    if (brg < 0) brg += 360;
    final k = (brg / 360 * radials).round() % radials;
    final b = bytes[k * n + j - 1];
    return (b > 127 ? b - 256 : b) * scale;
  };
}

/// Compares the [prediction] for an installed node with measured [cells]: a cell is predicted covered when the margin
/// there is at least 0 ([marginAt], default the answer's own grid, [predictedMarginSampler]); predicted SNR = margin +
/// the radio's SNR floor ([snrFloorDb], default the run's `model.snrFloorDb`, else SF7's). Cells outside the sweep are
/// not compared. Below [minCells] compared cells the result says [VerifyComparison.enough] false.
VerifyComparison compareVerifyWithMeasured(
  PlanVerifyResult prediction,
  Iterable<PlanMeasuredCell> cells, {
  PlanPoint? site,
  double? Function(PlanPoint at)? marginAt,
  double? snrFloorDb,
  int minCells = verifyMinCells,
}) {
  final sample = marginAt ?? predictedMarginSampler(prediction, site: site);
  final model = prediction.raw['model'];
  final floor = snrFloorDb ?? (model is Map && model['snrFloorDb'] is num ? (model['snrFloorDb'] as num).toDouble() : snrFloorForSf(model is Map && model['sf'] is num ? (model['sf'] as num).round() : 7));
  var compared = 0, ch = 0, cs = 0, ho = 0, qo = 0, nSnr = 0;
  var sumM = 0.0, sumP = 0.0;
  if (sample != null) {
    for (final c in cells) {
      final m = sample(c.at);
      if (m == null) continue;
      compared++;
      final covered = m >= 0;
      if (covered && c.heard) ch++;
      if (covered && !c.heard) cs++;
      if (!covered && c.heard) ho++;
      if (!covered && !c.heard) qo++;
      final s = c.snr;
      if (c.heard && s != null && s.isFinite) {
        nSnr++;
        sumM += s;
        sumP += m + floor;
      }
    }
  }
  return VerifyComparison(
    compared: compared,
    coveredHeard: ch,
    coveredSilent: cs,
    heardOutside: ho,
    quietOutside: qo,
    measuredSnr: nSnr == 0 ? null : sumM / nSnr,
    predictedSnr: nSnr == 0 ? null : sumP / nSnr,
    minCells: minCells,
  );
}
