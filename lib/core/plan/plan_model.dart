// Plan JSON v1 (release 0.38 Master Planner; spec plan-tab-master-planner-2026-11-15.md section 4.4 "Plan JSON v1", build
// plan section 4.3/5.6): the one saved set of nodes every Planner mode acts on. Kept on the phone (saved_plans.dart over
// PlanRepository) and carried in share links (plan_codec.dart). Shape:
//   { "v": 1, "id", "name", "region"?, "radio": {freqMHz,bwKHz,sf,cr}, "clutter": {canopyM,dbPerKm}, "goal",
//     "receiverM"?, "createdAt", "updatedAt", "nodes": [ { "id", "name", "lat", "lon", "status": planned|installed|existing,
//     "mine"?, "existingKey"?, "heightM"?, "txDbm"?, "gainDbi"?, "cableLossDb"?, "mount"?, "role", "approx"? } ] }
// At most [Plan.maxNodes] (30) nodes. Optional fields are left out when unset, so a plan stays small in a link. Decoding is
// tolerant (a missing or odd field takes its default, a node without a usable position is dropped) but a document that is
// not a v1 plan throws [FormatException]. The spec's earlier `source: existing|mine|planned` is still read (a node is
// `mine` on its own axis now, because a planned or an existing node can both be the person's).
// Pure Dart.
import 'dart:math' as math;

import '../api.dart' show RadioPreset;
import '../node_claim.dart' show ClaimNodeType, NodeClaim, normalizePublicKey;
import '../plan_contract.dart';

/// Where a node stands: a site being considered, one the person has put up (the Verify loop compares it with measured
/// data), or a node already on the network.
enum PlanNodeStatus {
  planned('planned'),
  installed('installed'),
  existing('existing');

  final String wire;
  const PlanNodeStatus(this.wire);
  static PlanNodeStatus? tryParse(Object? v) => values.where((s) => s.wire == v).firstOrNull;
}

/// What the node is: a fixed repeater, or a person's handheld/companion radio (a link end, not a site).
enum PlanNodeRole {
  repeater('repeater'),
  handheld('handheld');

  final String wire;
  const PlanNodeRole(this.wire);
  static PlanNodeRole parse(Object? v) => values.firstWhere((r) => r.wire == v, orElse: () => PlanNodeRole.repeater);
}

/// Antenna height (m above ground) a mount gives when the node has no height of its own.
double mountHeightM(PlanMount m) => switch (m) {
      PlanMount.ground => 6,
      PlanMount.tree => 15,
      PlanMount.building => 10,
    };

/// Height of an existing network repeater when nothing better is known (website `EXISTING.heightM`).
const double existingHeightM = 8;

/// Default height of a new planned site (the Find sites/verify default `antennaM`).
const double plannedHeightM = 10;

/// Height of a handheld radio (website `RECEIVERS.handheld`).
const double handheldHeightM = 1.5;

const double defaultTxDbm = 22, defaultGainDbi = 3, handheldGainDbi = 0;

class PlanNode {
  final String id;
  final String name;
  final double lat, lon;
  final PlanNodeStatus status;

  /// The person's own radio: resolved from their claimed radios (`my-radios`) for a node with a key, set by the person
  /// for a planned site. Mine and installed positions are rounded to about 1 km in a share link by default.
  final bool mine;

  /// The network node's public key (64 lower-case hex) when the node is a known radio.
  final String? existingKey;

  /// Optional per-node settings; null = the default for the node's mount, status and role.
  final double? heightM, txDbm, gainDbi, cableLossDb;
  final PlanMount? mount;
  final PlanNodeRole role;

  /// The position was rounded to about 1 km when the plan was shared (the receiver sees it as approximate).
  final bool approximate;

  const PlanNode({
    required this.id,
    required this.name,
    required this.lat,
    required this.lon,
    this.status = PlanNodeStatus.planned,
    this.mine = false,
    this.existingKey,
    this.heightM,
    this.txDbm,
    this.gainDbi,
    this.cableLossDb,
    this.mount,
    this.role = PlanNodeRole.repeater,
    this.approximate = false,
  });

  PlanPoint get point => PlanPoint(lat, lon);

  /// The antenna height the maths uses: the node's own, else its mount's, else the default for what it is.
  double get antennaM =>
      heightM ??
      (mount != null
          ? mountHeightM(mount!)
          : role == PlanNodeRole.handheld
              ? handheldHeightM
              : status == PlanNodeStatus.existing
                  ? existingHeightM
                  : plannedHeightM);
  double get effectiveTxDbm => txDbm ?? defaultTxDbm;

  /// Antenna gain less the cable loss.
  double get effectiveGainDbi => (gainDbi ?? (role == PlanNodeRole.handheld ? handheldGainDbi : defaultGainDbi)) - (cableLossDb ?? 0);

  /// Is this position shared only approximately by default (privacy rule, build plan 5.6)?
  bool get sensitivePosition => mine || status == PlanNodeStatus.installed;

  PlanNode copyWith({
    String? name,
    double? lat,
    double? lon,
    PlanNodeStatus? status,
    bool? mine,
    String? existingKey,
    bool clearExistingKey = false,
    double? heightM,
    bool clearHeight = false,
    double? txDbm,
    bool clearTx = false,
    double? gainDbi,
    bool clearGain = false,
    double? cableLossDb,
    bool clearCableLoss = false,
    PlanMount? mount,
    bool clearMount = false,
    PlanNodeRole? role,
    bool? approximate,
  }) =>
      PlanNode(
        id: id,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        status: status ?? this.status,
        mine: mine ?? this.mine,
        existingKey: clearExistingKey ? null : existingKey ?? this.existingKey,
        heightM: clearHeight ? null : heightM ?? this.heightM,
        txDbm: clearTx ? null : txDbm ?? this.txDbm,
        gainDbi: clearGain ? null : gainDbi ?? this.gainDbi,
        cableLossDb: clearCableLoss ? null : cableLossDb ?? this.cableLossDb,
        mount: clearMount ? null : mount ?? this.mount,
        role: role ?? this.role,
        approximate: approximate ?? this.approximate,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lat': _r(lat, 5),
        'lon': _r(lon, 5),
        'status': status.wire,
        if (mine) 'mine': true,
        'existingKey': ?existingKey,
        'heightM': ?heightM,
        'txDbm': ?txDbm,
        'gainDbi': ?gainDbi,
        'cableLossDb': ?cableLossDb,
        'mount': ?mount?.wire,
        'role': role.wire,
        if (approximate) 'approx': true,
      };

  /// Null when [j] is not a usable node (no position, a position off the globe).
  static PlanNode? tryParse(Object? j, {String? fallbackId}) {
    if (j is! Map) return null;
    final lat = _n(j['lat']), lon = _n(j['lon']);
    if (lat == null || lon == null || lat.abs() > 90 || lon.abs() > 180) return null;
    final id = _s(j['id']) ?? fallbackId;
    if (id == null) return null;
    // Spec draft `source: existing|mine|planned`, still read.
    final source = j['source'];
    final status = PlanNodeStatus.tryParse(j['status']) ?? (source == 'existing' ? PlanNodeStatus.existing : PlanNodeStatus.planned);
    final key = j['existingKey'] is String ? normalizePublicKey(j['existingKey'] as String) : null;
    return PlanNode(
      id: id.length > 64 ? id.substring(0, 64) : id,
      name: (_s(j['name']) ?? 'Node').trim(),
      lat: lat,
      lon: lon,
      status: status,
      mine: j['mine'] == true || source == 'mine',
      existingKey: key,
      heightM: _clampOrNull(_n(j['heightM']), 0.5, 300),
      txDbm: _clampOrNull(_n(j['txDbm']), -10, 36),
      gainDbi: _clampOrNull(_n(j['gainDbi']), -10, 30),
      cableLossDb: _clampOrNull(_n(j['cableLossDb']), 0, 30),
      mount: PlanMount.tryParse(j['mount']),
      role: PlanNodeRole.parse(j['role']),
      approximate: j['approx'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PlanNode &&
      other.id == id &&
      other.name == name &&
      other.lat == lat &&
      other.lon == lon &&
      other.status == status &&
      other.mine == mine &&
      other.existingKey == existingKey &&
      other.heightM == heightM &&
      other.txDbm == txDbm &&
      other.gainDbi == gainDbi &&
      other.cableLossDb == cableLossDb &&
      other.mount == mount &&
      other.role == role &&
      other.approximate == approximate;
  @override
  int get hashCode => Object.hash(id, name, lat, lon, status, mine, existingKey, heightM, txDbm, gainDbi, cableLossDb, mount, role, approximate);
  @override
  String toString() => 'PlanNode($id, $name, $lat, $lon, ${status.wire}${mine ? ', mine' : ''})';
}

class Plan {
  static const int version = 1;
  static const int maxNodes = 30;

  final String id;
  final String name;

  /// The region slug the plan was made in (informational; requests take the region from the server's Host).
  final String? region;
  final PlanRadio radio;
  final PlanClutter clutter;
  final PlanGoal goal;

  /// Receiver height above ground for coverage (null = the receiver's default).
  final double? receiverM;
  final List<PlanNode> nodes;
  final DateTime createdAt, updatedAt;

  Plan({
    required this.id,
    this.name = 'My plan',
    this.region,
    this.radio = PlanRadio.usDefault,
    this.clutter = const PlanClutter(),
    this.goal = PlanGoal.overall,
    this.receiverM,
    List<PlanNode> nodes = const [],
    required this.createdAt,
    DateTime? updatedAt,
  })  : nodes = List.unmodifiable(nodes.length > maxNodes ? nodes.sublist(0, maxNodes) : nodes),
        updatedAt = updatedAt ?? createdAt;

  /// A new empty plan for the region's radio preset (US default only when the region has none).
  factory Plan.create({String? id, String name = 'My plan', String? region, RadioPreset? preset, DateTime? now, math.Random? random}) {
    final t = (now ?? DateTime.now()).toUtc();
    return Plan(id: id ?? newPlanId(now: t, random: random), name: name, region: region, radio: planRadioFor(preset), createdAt: t);
  }

  bool get isFull => nodes.length >= maxNodes;
  PlanNode? node(String id) => nodes.where((n) => n.id == id).firstOrNull;

  Plan copyWith({
    String? id,
    String? name,
    String? region,
    PlanRadio? radio,
    PlanClutter? clutter,
    PlanGoal? goal,
    double? receiverM,
    bool clearReceiver = false,
    List<PlanNode>? nodes,
    DateTime? updatedAt,
  }) =>
      Plan(
        id: id ?? this.id,
        name: name ?? this.name,
        region: region ?? this.region,
        radio: radio ?? this.radio,
        clutter: clutter ?? this.clutter,
        goal: goal ?? this.goal,
        receiverM: clearReceiver ? null : receiverM ?? this.receiverM,
        nodes: nodes ?? this.nodes,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'v': version,
        'id': id,
        'name': name,
        'region': ?region,
        'radio': radio.toJson(),
        'clutter': clutter.toJson(),
        'goal': goal.wire,
        'receiverM': ?receiverM,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'nodes': [for (final n in nodes) n.toJson()],
      };

  /// Throws [FormatException] when [j] is not a Plan JSON v1 document.
  static Plan fromJson(Object? j) {
    if (j is! Map) throw const FormatException('not a plan');
    final v = j['v'];
    if (v != version) throw FormatException('plan version $v is not supported');
    final nodesRaw = j['nodes'];
    if (nodesRaw is! List) throw const FormatException('plan without nodes');
    final nodes = <PlanNode>[];
    final seen = <String>{};
    for (var i = 0; i < nodesRaw.length && nodes.length < maxNodes; i++) {
      final n = PlanNode.tryParse(nodesRaw[i], fallbackId: 'n$i');
      if (n == null) continue;
      // Ids must be unique inside a plan (edits address nodes by id).
      final node = seen.add(n.id) ? n : PlanNode.tryParse({...nodesRaw[i] as Map, 'id': '${n.id}_$i'})!;
      seen.add(node.id);
      nodes.add(node);
    }
    final created = _t(j['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    final id = _s(j['id']);
    return Plan(
      id: id != null && RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id) ? id : 'p_imported',
      name: (_s(j['name']) ?? 'Shared plan').trim(),
      region: _s(j['region']),
      radio: PlanRadio.tryParse(j['radio']) ?? PlanRadio.usDefault,
      clutter: PlanClutter.tryParse(j['clutter']) ?? const PlanClutter(),
      goal: PlanGoal.parse(j['goal']),
      receiverM: _clampOrNull(_n(j['receiverM']), 0.5, 100),
      nodes: nodes,
      createdAt: created,
      updatedAt: _t(j['updatedAt']) ?? created,
    );
  }

  @override
  String toString() => 'Plan($id, $name, ${nodes.length} nodes)';
}

/// The plan's radio for a region preset; [PlanRadio.usDefault] only when the region has none.
PlanRadio planRadioFor(RadioPreset? p) =>
    p == null ? PlanRadio.usDefault : PlanRadio(freqMHz: p.freqMhz, bwKHz: p.bwKhz, sf: p.sf, cr: p.cr);

const String _idChars = '0123456789abcdefghijklmnopqrstuvwxyz';
String _rand(math.Random r, int n) => String.fromCharCodes([for (var i = 0; i < n; i++) _idChars.codeUnitAt(r.nextInt(_idChars.length))]);

/// A new plan id (a valid PlanRepository file name): `p_` + time + random.
String newPlanId({DateTime? now, math.Random? random}) =>
    'p_${(now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36)}${_rand(random ?? math.Random.secure(), 6)}';

/// A new node id, unique among [taken].
String newNodeId(Iterable<String> taken, {math.Random? random}) {
  final r = random ?? math.Random();
  final used = taken.toSet();
  while (true) {
    final id = 'n${_rand(r, 6)}';
    if (!used.contains(id)) return id;
  }
}

// ---------------------------------------------------------------- `mine` from claimed radios (J6)
/// Marks the nodes that are the person's own radios: a node whose key is an active claim of theirs becomes `mine`, a
/// keyed node that is no longer claimed stops being `mine`. Planned sites without a key keep what the person set.
/// Returns [plan] itself when nothing changes.
Plan resolveMine(Plan plan, Iterable<NodeClaim> claims) {
  final active = {for (final c in claims) if (!c.ended) c.pubkey};
  var changed = false;
  final nodes = [
    for (final n in plan.nodes)
      if (n.existingKey != null && n.mine != active.contains(n.existingKey))
        () {
          changed = true;
          return n.copyWith(mine: active.contains(n.existingKey));
        }()
      else
        n,
  ];
  return changed ? plan.copyWith(nodes: nodes) : plan;
}

/// Nodes for the person's claimed radios that have a known position ([positions] by public key, e.g. from the region
/// roster or the network list) and are not in [plan] yet, ready to add. Repeaters and rooms become existing repeater
/// nodes, companions handheld ends; observers are skipped (not a radio site).
List<PlanNode> mineNodes(Plan plan, Iterable<NodeClaim> claims, Map<String, PlanPoint> positions, {math.Random? random}) {
  final have = {for (final n in plan.nodes) ?n.existingKey};
  final taken = {for (final n in plan.nodes) n.id};
  final out = <PlanNode>[];
  for (final c in claims) {
    if (c.ended || have.contains(c.pubkey)) continue;
    final at = positions[c.pubkey];
    if (at == null) continue;
    final role = switch (c.nodeType) {
      ClaimNodeType.companion => PlanNodeRole.handheld,
      ClaimNodeType.observer => null,
      ClaimNodeType.repeater || ClaimNodeType.room || ClaimNodeType.unknown => PlanNodeRole.repeater,
    };
    if (role == null) continue;
    final id = newNodeId(taken, random: random);
    taken.add(id);
    have.add(c.pubkey);
    out.add(PlanNode(id: id, name: c.label, lat: at.lat, lon: at.lon, status: PlanNodeStatus.existing, mine: true, existingKey: c.pubkey, role: role));
  }
  return out;
}

double _r(double v, int places) => double.parse(v.toStringAsFixed(places));
double? _n(Object? v) => v is num && v.isFinite ? v.toDouble() : null;
String? _s(Object? v) => v is String && v.trim().isNotEmpty ? v : null;
DateTime? _t(Object? v) => v is String ? DateTime.tryParse(v)?.toUtc() : null;
double? _clampOrNull(double? v, double lo, double hi) => v?.clamp(lo, hi).toDouble();
