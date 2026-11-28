// The one Plan every Planner mode acts on (release 0.38): add / move / edit / delete nodes, rename, the per-plan radio,
// clutter, goal and receiver height, with undo and redo, autosave through SavedPlans, and the plan-wide analysis
// (plan_analysis.dart: link matrix, relay finder, snap to high ground, node classes). Pure Dart (no Flutter): the UI
// listens through [addListener] (the same shape as a Flutter Listenable, so a thin adapter is all a widget needs) or
// [changes].
import 'dart:async';
import 'dart:math' as math;

import '../node_claim.dart' show NodeClaim;
import '../plan_contract.dart';
import 'plan_analysis.dart';
import 'plan_model.dart';
import 'saved_plans.dart';

/// Thrown when a node cannot be added because the plan already has [Plan.maxNodes].
class PlanFullException implements Exception {
  const PlanFullException();
  @override
  String toString() => 'A plan holds at most ${Plan.maxNodes} spots. Remove one first.';
}

class PlanController {
  Plan _plan;
  final SavedPlans? saved;

  /// How long after the last change the plan is written (null = only on [save]).
  final Duration? autosaveAfter;
  final int maxUndo;
  final math.Random _random;
  final List<Plan> _undo = [], _redo = [];
  final List<void Function()> _listeners = [];
  final StreamController<Plan> _changes = StreamController<Plan>.broadcast();
  Timer? _saveTimer;
  bool _dirty = false;
  bool _disposed = false;

  /// The matrix last built for this plan's nodes, radio and clutter (cleared by any change that affects it).
  LinkMatrix? _matrix;
  Plan? _matrixFor;

  PlanController(Plan plan, {this.saved, this.autosaveAfter = const Duration(milliseconds: 600), this.maxUndo = 50, math.Random? random})
      : _plan = plan,
        _random = random ?? math.Random();

  Plan get plan => _plan;
  List<PlanNode> get nodes => _plan.nodes;
  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  /// Unsaved changes are waiting for the autosave (or [save]).
  bool get dirty => _dirty;
  Stream<Plan> get changes => _changes.stream;

  void addListener(void Function() l) => _listeners.add(l);
  void removeListener(void Function() l) => _listeners.remove(l);

  void _notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
    if (!_changes.isClosed) _changes.add(_plan);
  }

  /// Applies [next]; [undoable] false for a change the person did not make (e.g. `mine` resolution) or the middle of a
  /// drag ([moveNode] with `continuing`).
  void _apply(Plan next, {bool undoable = true}) {
    if (_disposed || identical(next, _plan)) return;
    if (undoable) {
      _undo.add(_plan);
      if (_undo.length > maxUndo) _undo.removeAt(0);
      _redo.clear();
    }
    _plan = next;
    _dirty = true;
    _scheduleSave();
    _notify();
  }

  void _scheduleSave() {
    final d = autosaveAfter;
    if (saved == null || d == null) return;
    _saveTimer?.cancel();
    _saveTimer = Timer(d, () => unawaited(save()));
  }

  /// Writes the plan now (also what the autosave runs). Returns the saved plan.
  Future<Plan> save() async {
    _saveTimer?.cancel();
    final s = saved;
    if (s == null) return _plan;
    final written = await s.save(_plan);
    // Keep the stamped time, unless the plan changed while the write was in flight.
    if (!_disposed && written.id == _plan.id && _sameContent(written, _plan)) {
      _plan = written;
      _dirty = false;
    }
    return written;
  }

  static bool _sameContent(Plan a, Plan b) =>
      a.name == b.name && a.radio == b.radio && a.goal == b.goal && a.receiverM == b.receiverM &&
      a.clutter.canopyM == b.clutter.canopyM && a.clutter.dbPerKm == b.clutter.dbPerKm && _listEq(a.nodes, b.nodes);
  static bool _listEq(List<PlanNode> a, List<PlanNode> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------- nodes
  /// Adds a node and returns it; throws [PlanFullException] at [Plan.maxNodes]. A node with the [existingKey] of one
  /// already in the plan is not added twice: that node is returned.
  PlanNode addNode({
    required String name,
    required double lat,
    required double lon,
    PlanNodeStatus status = PlanNodeStatus.planned,
    bool mine = false,
    String? existingKey,
    double? heightM,
    double? txDbm,
    double? gainDbi,
    double? cableLossDb,
    PlanMount? mount,
    PlanNodeRole role = PlanNodeRole.repeater,
  }) {
    if (existingKey != null) {
      final have = _plan.nodes.where((n) => n.existingKey == existingKey).firstOrNull;
      if (have != null) return have;
    }
    if (_plan.isFull) throw const PlanFullException();
    final node = PlanNode(
      id: newNodeId(_plan.nodes.map((n) => n.id), random: _random),
      name: name.trim().isEmpty ? 'Node ${_plan.nodes.length + 1}' : name.trim(),
      lat: lat,
      lon: lon,
      status: status,
      mine: mine,
      existingKey: existingKey,
      heightM: heightM,
      txDbm: txDbm,
      gainDbi: gainDbi,
      cableLossDb: cableLossDb,
      mount: mount,
      role: role,
    );
    _apply(_plan.copyWith(nodes: [..._plan.nodes, node]));
    return node;
  }

  /// Moves a node. A drag calls this with [continuing] true for every step after the first, so one undo puts the node
  /// back where the drag started. Returns false when there is no such node.
  bool moveNode(String id, double lat, double lon, {bool continuing = false}) {
    final n = _plan.node(id);
    if (n == null || lat.abs() > 90 || lon.abs() > 180) return false;
    if (n.lat == lat && n.lon == lon) return true;
    // A moved node's position is exact again.
    _replaceNode(n.copyWith(lat: lat, lon: lon, approximate: false), undoable: !continuing);
    return true;
  }

  /// Edits a node through [edit] (its id cannot change). Returns false when there is no such node.
  bool updateNode(String id, PlanNode Function(PlanNode node) edit) {
    final n = _plan.node(id);
    if (n == null) return false;
    final next = edit(n);
    if (next.id != id) throw ArgumentError('a node edit cannot change its id');
    if (next == n) return true;
    _replaceNode(next);
    return true;
  }

  void _replaceNode(PlanNode next, {bool undoable = true}) =>
      _apply(_plan.copyWith(nodes: [for (final x in _plan.nodes) x.id == next.id ? next : x]), undoable: undoable);

  bool deleteNode(String id) {
    if (_plan.node(id) == null) return false;
    _apply(_plan.copyWith(nodes: [for (final x in _plan.nodes) if (x.id != id) x]));
    return true;
  }

  // ---------------------------------------------------------------- plan settings
  void rename(String name) {
    final t = name.trim();
    if (t.isEmpty || t == _plan.name) return;
    _apply(_plan.copyWith(name: t));
  }

  void setRadio(PlanRadio radio) {
    if (radio != _plan.radio) _apply(_plan.copyWith(radio: radio));
  }

  void setClutter(PlanClutter clutter) {
    if (clutter.canopyM != _plan.clutter.canopyM || clutter.dbPerKm != _plan.clutter.dbPerKm) _apply(_plan.copyWith(clutter: clutter));
  }

  void setGoal(PlanGoal goal) {
    if (goal != _plan.goal) _apply(_plan.copyWith(goal: goal));
  }

  void setReceiverM(double? metres) {
    if (metres == _plan.receiverM) return;
    _apply(metres == null ? _plan.copyWith(clearReceiver: true) : _plan.copyWith(receiverM: metres.clamp(0.5, 100).toDouble()));
  }

  /// Marks the person's own radios from their claims (J6). Not an undo step: it is what the data says.
  void resolveMineFrom(Iterable<NodeClaim> claims) => _apply(resolveMine(_plan, claims), undoable: false);

  /// Opens another plan in this controller (undo history starts again).
  void replace(Plan plan) {
    _undo.clear();
    _redo.clear();
    _plan = plan;
    _matrix = null;
    _dirty = false;
    _notify();
  }

  // ---------------------------------------------------------------- undo
  bool undo() {
    if (_undo.isEmpty) return false;
    _redo.add(_plan);
    _apply(_undo.removeLast(), undoable: false);
    return true;
  }

  bool redo() {
    if (_redo.isEmpty) return false;
    final next = _redo.removeLast();
    _undo.add(_plan);
    _plan = next;
    _dirty = true;
    _scheduleSave();
    _notify();
    return true;
  }

  // ---------------------------------------------------------------- analysis
  /// The link matrix of the plan's first 10 nodes (or [only]); reused while nothing that affects it changed.
  Future<LinkMatrix> linkMatrix(ProfileSource profile, {Iterable<String>? only}) async {
    final m = _matrix, f = _matrixFor;
    if (only == null && m != null && f != null && _matrixValid(f)) return m;
    final built = await buildLinkMatrix(_plan, profile, only: only);
    if (only == null) {
      _matrix = built;
      _matrixFor = _plan;
    }
    return built;
  }

  bool _matrixValid(Plan f) =>
      f.radio == _plan.radio && f.clutter.canopyM == _plan.clutter.canopyM && f.clutter.dbPerKm == _plan.clutter.dbPerKm && _listEq(f.nodes, _plan.nodes);

  /// Node classes from the last matrix (if any) and the server's network facts.
  Map<String, NodeClassification> nodeClasses({LinkMatrix? matrix, NetworkFacts facts = const NetworkFacts()}) =>
      classifyNodes(_plan, matrix: matrix ?? (_matrixFor != null && _matrixValid(_matrixFor!) ? _matrix : null), facts: facts);

  /// Relay points for the pair [aId]-[bId], best first.
  Future<List<RelayCandidate>> relaysFor(String aId, String bId, ProfileSource profile, {Iterable<PlanPoint> extra = const []}) async {
    final a = _plan.node(aId), b = _plan.node(bId);
    if (a == null || b == null) return const [];
    final ab = await profile(a.point, b.point);
    return findRelays(_plan, a, b, profile, abProfile: ab.data, extra: extra);
  }

  /// Adds the relay [c] as a planned node (one undo step).
  PlanNode addRelay(RelayCandidate c, {String name = 'Relay'}) =>
      addNode(name: name, lat: c.at.lat, lon: c.at.lon, heightM: c.relayHeightM);

  /// Moves node [id] to the highest ground within [radiusM] (one undo step). Null when there is no such node or no
  /// terrain; the node stays put when it already sits on the highest point found.
  Future<SnapResult?> snapNode(String id, double radiusM, ProfileSource profile) async {
    final n = _plan.node(id);
    if (n == null) return null;
    final r = await snapToHighGround(n.point, radiusM, profile);
    if (r == null) return null;
    if (_plan.node(id) != null && r.distanceM > 1) moveNode(id, r.at.lat, r.at.lon);
    return r;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    if (_dirty && saved != null) await save();
    _disposed = true;
    _saveTimer?.cancel();
    _listeners.clear();
    await _changes.close();
  }
}
