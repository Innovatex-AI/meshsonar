// The plan layer's data and its provider hook (release 0.38, plan §4.5 item 1: "one map vocabulary"). The `plan` layer
// (registry.dart kPlanLayerId) draws whatever a [PlanOverlayController] holds: the open plan's planned and installed nodes, the
// links between them, and targets to drive to (Find sites results, Where to drive). The planner owns one controller for the
// Plan tab's map; the main map (the Drive tab's) reads [MainMapFocus.overlay], which "open the map with this overlay/plan"
// requests fill (main_map_focus.dart).
//
// The plan JSON itself is not read here (its codec is lib/core/plan/): a host that can turn a saved plan id into nodes sets
// [PlanOverlayController.resolvePlan] once, and a request that names only a plan id is drawn through it.
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

import '../main_map_focus.dart' show MapFocusRequest, MapFocusTarget;

/// What a node on the plan layer is.
enum PlanOverlayNodeKind {
  /// Not built yet (dashed ring).
  planned,

  /// Built and on the air (solid ring).
  installed,

  /// A place to drive to (a suggested site, a Where-to-drive spot).
  target,
}

@immutable
class PlanOverlayNode {
  /// Stable within the plan (the plan node id, or the target id), carried by [PlanNodeHit.nodeId].
  final String id;
  final String name;
  final LatLng at;
  final PlanOverlayNodeKind kind;
  const PlanOverlayNode({required this.id, required this.name, required this.at, this.kind = PlanOverlayNodeKind.planned});

  /// The words for [kind] (sheet subtitle, VoiceOver).
  String get kindLabel => switch (kind) {
    PlanOverlayNodeKind.planned => 'Planned site',
    PlanOverlayNodeKind.installed => 'Installed',
    PlanOverlayNodeKind.target => 'Target',
  };

  @override
  bool operator ==(Object other) => other is PlanOverlayNode && other.id == id && other.name == name && other.at == at && other.kind == kind;
  @override
  int get hashCode => Object.hash(id, name, at, kind);
  @override
  String toString() => 'PlanOverlayNode($id, ${kind.name})';
}

/// The Estimate for a planned link (the Map Definition's `symbols.plan.verdictBand` colours it).
enum PlanLinkVerdict { likely, marginal, unlikely, unknown }

@immutable
class PlanOverlayLink {
  final String fromId, toId;
  final PlanLinkVerdict verdict;
  const PlanOverlayLink({required this.fromId, required this.toId, this.verdict = PlanLinkVerdict.unknown});

  @override
  bool operator ==(Object other) => other is PlanOverlayLink && other.fromId == fromId && other.toId == toId && other.verdict == verdict;
  @override
  int get hashCode => Object.hash(fromId, toId, verdict);
}

/// One plan as the layer draws it.
@immutable
class PlanOverlay {
  /// The saved plan's id (lib/core/plan/plan_repository.dart); null for an unsaved plan.
  final String? planId;
  final List<PlanOverlayNode> nodes;
  final List<PlanOverlayLink> links;
  const PlanOverlay({this.planId, this.nodes = const [], this.links = const []});

  static const PlanOverlay empty = PlanOverlay();

  bool get isEmpty => nodes.isEmpty;
}

/// The provider hook: the plan layer listens to one of these and redraws when it changes.
class PlanOverlayController extends ChangeNotifier {
  PlanOverlay _plan = PlanOverlay.empty;
  List<MapFocusTarget> _targets = const [];
  Set<String> _requestedLayers = const {};
  int _requestSeq = 0;
  int _resolveGen = 0;

  /// Turns a saved plan id into what to draw (set once by the host that owns the plan codec). Null = a request that names
  /// only a plan id draws nothing new (its targets and layers still apply).
  Future<PlanOverlay?> Function(String planId)? resolvePlan;

  PlanOverlay get plan => _plan;
  List<MapFocusTarget> get targets => _targets;

  /// The layer ids the last applied request asked to switch on, and a counter that moves with every applied request (the
  /// Drive map model switches those layers on once per request).
  Set<String> get requestedLayers => _requestedLayers;
  int get requestSeq => _requestSeq;

  /// Something to draw.
  bool get isActive => _plan.nodes.isNotEmpty || _targets.isNotEmpty;

  /// Everything the layer draws as a marker: the plan's nodes, then the targets.
  List<PlanOverlayNode> get drawnNodes => [
    ..._plan.nodes,
    for (final t in _targets) PlanOverlayNode(id: t.id, name: t.label, at: t.at, kind: PlanOverlayNodeKind.target),
  ];

  /// The node with [id] (plan node or target), or null.
  PlanOverlayNode? nodeById(String id) {
    for (final n in drawnNodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Draws [plan] (replaces the one drawn).
  void showPlan(PlanOverlay plan) {
    _resolveGen++; // a slower resolve of an older request must not overwrite this
    if (identical(plan, _plan)) return;
    _plan = plan;
    notifyListeners();
  }

  /// Draws [targets] (replaces the ones drawn).
  void showTargets(List<MapFocusTarget> targets) {
    if (listEquals(targets, _targets)) return;
    _targets = List.unmodifiable(targets);
    notifyListeners();
  }

  /// Applies what an "open the map with this overlay/plan" request asks for. A request with no overlay leaves what is drawn.
  Future<void> applyFocus(MapFocusRequest r) async {
    if (!r.hasOverlay) return;
    _requestedLayers = r.showLayers;
    _requestSeq++;
    if (r.targets.isNotEmpty) _targets = r.targets;
    notifyListeners();
    final id = r.planId;
    final resolve = resolvePlan;
    if (id == null || resolve == null || id == _plan.planId) return;
    final gen = ++_resolveGen;
    PlanOverlay? got;
    try {
      got = await resolve(id);
    } catch (_) {
      got = null; // a plan that cannot be read draws nothing; the targets still show
    }
    if (gen != _resolveGen || got == null) return;
    _plan = got;
    notifyListeners();
  }

  /// Takes everything off the layer ("Remove from map").
  void clear() {
    _resolveGen++;
    if (!isActive && _requestedLayers.isEmpty) return;
    _plan = PlanOverlay.empty;
    _targets = const [];
    _requestedLayers = const {};
    notifyListeners();
  }
}
