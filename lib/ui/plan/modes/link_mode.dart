// The Planner's Link mode (release 0.38 A8; build plan section 4.2 job A "Will A hear B", section 4.3 improvements 1-7 and
// 11-16). It acts on the one Plan (PlanController) like every mode:
//   1  ends from the network or the plan: the two end pickers list the plan's nodes (existing repeaters, the person's
//      radios, planned sites); "Add from the network" opens the existing-node picker; a tap on a node on the map makes it
//      an end; a dragged or moved node is re-checked at once.
//   2  three-state verdict, Works / Marginal / Unlikely, with the 10 dB fade margin, "Raise A by N m" (one tap applies it,
//      Undo takes it back) and the blocking ridge, marked on the map and on the profile chart.
//   3  measured next to predicted: plan-link's `measured` (packets our observers heard between the pair), our drive cells
//      near each end, and a flag when the measurement and the model disagree.
//   4  the plan's radio (never a constant: the region's preset), changed in the one Radio and trees sheet (build 77: this
//      mode no longer repeats the radio and tree settings under other names).
//   5  tree / clutter: in Radio and trees, labelled Estimate.
//   6  the terrain profile chart with a scrubbing crosshair (profile_chart.dart); the same spot is drawn on the map.
//   7  relay finder (core/plan/plan_analysis.dart findRelays: dual line of sight first) with one-tap Add, and "snap to high
//      ground" for planned ends.
//   11 direction: Down (A to B), Up (B to A), Both (the weaker).   12 receiver height for handheld ends (the plan's
//      `receiverM`).   14 the fade margin and a plain-words glossary (info sheet).   16 the calibration-confidence line.
// Offline: PlanApi.link serves a stored answer, else works the link out on the phone from score-link's profile
// (localPlanLink); when neither answers, the last profile this mode saw for the same two points is re-judged on the phone
// (heights, radio, clutter or direction changed while offline). Every state has an icon and words.
//
// Build 77 (round 4): the ends are the app's action-sheet pick fields; plain words first (verdict, sentence, what to change
// "to clear the hill"), every figure under "The numbers"; a planned place is a "spot", a real one a "repeater".
//
// Keys: 'plan-mode-link' (body), 'link-a-<id>', 'link-b-<id>' (the pick fields), 'link-swap', 'link-add-network', 'link-dir-<down|up|both>',
// 'link-run', 'link-loading', 'link-error', 'link-result', 'link-verdict', 'link-stale', 'link-profile',
// 'link-scrub-readout', 'link-raise', 'link-raise-apply', 'link-raise-relay', 'link-ridge', 'link-ridge-show',
// 'link-disagree', 'link-never-heard', 'link-measured', 'link-measured-none', 'link-drive-cells', 'link-confidence',
// 'link-relay-find', 'link-relay-<i>', 'link-relay-add-<i>', 'link-relay-empty', 'link-relay-error', 'link-snap-a',
// 'link-snap-b', 'link-glossary', 'link-glossary-sheet', 'link-receiver', 'link-margin'.
// Map targets: 'link-ridge', 'link-scrub', 'link-relay-<i>'.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/api.dart' show PublicCoverage;
import '../../../core/plan/link_model.dart' show fadeMarginDb, fadeMarginWords, haversineKm, lambdaFor, localPlanLink, raiseMaxM, verdictOf;
import '../../../core/plan/plan_analysis.dart' show CalibrationConfidence, RelayCandidate, calibrationConfidence;
import '../../../core/plan/plan_api.dart';
import '../../../core/plan/plan_controller.dart' show PlanFullException;
import '../../../core/plan/plan_model.dart';
import '../../../core/plan_contract.dart';
import '../../../core/time_format.dart' show dateOnly;
import '../../../core/units.dart' show Units;
import '../../app.dart';
import '../../design/app_haptics.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/sheet_detents.dart' show formSheetDetents;
import '../../design/state_views.dart';
import '../../design/tokens.dart';
import '../../map/layers/plan_overlay.dart' show PlanLinkVerdict, PlanOverlayLink;
import '../../map/main_map_focus.dart' show MapFocusTarget;
import '../../pick_field.dart';
import '../../settings/settings_kit.dart' show SliderTile;
import '../plan_modes.dart';
import 'profile_chart.dart';

/// The three verdict words of the Link mode (plan: Works / Marginal / Unlikely).
String linkVerdictWords(PlanVerdict v) => switch (v) {
      PlanVerdict.likely => 'Works',
      PlanVerdict.marginal => 'Marginal',
      PlanVerdict.unlikely => 'Unlikely',
    };

String directionWords(PlanDirection d) => switch (d) {
      PlanDirection.down => 'Down: A to B',
      PlanDirection.up => 'Up: B to A',
      PlanDirection.both => 'Both ways',
    };

String confidenceWords(PlanConfidenceLevel l) => switch (l) {
      PlanConfidenceLevel.measured => 'Measured',
      PlanConfidenceLevel.calibrated => 'Calibrated',
      PlanConfidenceLevel.estimate => 'Estimate',
    };

/// Snap-to-high-ground search radius.
const double linkSnapRadiusM = 500;

/// Drive cells are counted this far from each end for the evidence line.
const double linkDriveCellRadiusKm = 2;

/// Glossary terms in plain words (the info sheet).
const List<(String, String)> linkGlossary = [
  ('Line of sight', 'A straight line from one antenna to the other that no hill crosses. Without it the signal has to bend over the ground and loses a lot.'),
  ('Fresnel zone', 'The fat, cigar-shaped space around the line of sight that the radio wave fills. Keep at least 60 % of it free of ground for a clean link; the chart shades it.'),
  ('Fade margin', fadeMarginWords),
  ('Link margin', 'How many dB the signal arrives above the weakest signal the radio can decode, after the 10 dB fade margin. 0 or more: works; down to -10: marginal; below that: unlikely.'),
  ('Blocking ridge', 'The highest ground above the line of sight. Raising an antenna, moving a site, or a relay on high ground gets around it.'),
  ('Terrain odds', 'How often links like this one (same distance, same terrain loss) worked on real repeater pairs. An estimate from Columbus data.'),
  ('Down, Up, Both', 'Down: A transmits to B (a repeater to a person). Up: B back to A. Both: the weaker of the two, what a two-way chat needs.'),
  ('Receiver height', 'How high a handheld or companion radio is held above the ground: lowest in a hand, a little higher on a car roof, highest at a window or on a mast.'),
  ('Clutter', 'Trees and buildings the terrain data does not show. The model adds a loss per kilometre for the part of the path below the canopy height. Both are estimates you can change.'),
  ('Estimate', 'Worked out by the model from bare-earth terrain. Not a promise: real links can be better or worse.'),
  ('Measured', 'From our own data: packets our observers heard between the two, or drives near them.'),
  ('Relay', 'A third spot both ends can reach, so messages hop around the obstacle.'),
  ('Fringe, Usable, Solid', 'How strong the signal is in a coverage estimate. Fringe: 0 to 6 dB above what the radio can decode, it may drop out. Usable: 6 to 12 dB. Solid: more than 12 dB.'),
  ('Show signal at least', 'Hides the parts of a coverage estimate where the signal is weaker than this. Weaker shows everywhere a radio can just decode; Stronger only where the signal has room to spare.'),
  ('Spot', 'A place in your plan where a radio could go. A repeater is a real one already on the network.'),
];

/// The plan's words in plain language (Link and Coverage both open it). Keeps the figures the results no longer put in
/// their names, such as the dB range of each coverage band.
Future<void> showPlanGlossary(BuildContext context) => showAppSheet<void>(
      context,
      detents: formSheetDetents(context),
      builder: (ctx, scroll) => AppSheetScaffold(
        key: const Key('link-glossary-sheet'),
        controller: scroll,
        title: 'Words used in a plan',
        children: [
          for (final (term, words) in linkGlossary)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.s),
              child: MergeSemantics(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(term, style: Theme.of(ctx).textTheme.titleSmall)),
                  const SizedBox(height: 2),
                  Text(words, style: Theme.of(ctx).textTheme.bodyMedium),
                ]),
              ),
            ),
          const SizedBox(height: Gap.l),
        ],
      ),
    );

class LinkMode extends PlanMode {
  const LinkMode();
  @override
  PlanModeId get id => PlanModeId.link;
  @override
  String get label => 'Link';
  @override
  AppSymbol get symbol => AppSymbols.route;
  @override
  String get hint => 'Will one spot hear another: pick two spots of the plan or repeaters from the network.';
  @override
  String get what => 'Will these two radios hear each other?';
  @override
  Widget buildSheet(PlanModeContext context) => LinkModeBody(context, key: ValueKey('plan-mode-body-link-${context.intent?.seq}'));
}

/// A terrain profile this mode has seen for a pair of points, kept for on-phone re-judging while offline.
class _SeenProfile {
  final List<double> groundM;
  final double km;
  final String terrain;
  final DateTime? at;
  const _SeenProfile(this.groundM, this.km, this.terrain, this.at);
}

class LinkModeBody extends StatefulWidget {
  final PlanModeContext ctx;
  const LinkModeBody(this.ctx, {super.key});
  @override
  State<LinkModeBody> createState() => LinkModeBodyState();
}

class LinkModeBodyState extends State<LinkModeBody> {
  String? _a, _b;
  bool _pickA = false;
  PlanDirection _direction = PlanDirection.both;
  bool _loading = false;
  PlanResult<PlanLinkResult>? _res;
  PlanLinkRequest? _resReq;
  String? _resKey, _askedKey;
  int _seq = 0;
  Timer? _debounce;
  double? _scrubT;
  final Map<String, _SeenProfile> _seen = {};

  bool _relayLoading = false;
  List<RelayCandidate>? _relays;
  String? _relayKey, _relayError;
  String? _snapping;

  PlanModeContext get ctx => widget.ctx;

  @visibleForTesting
  PlanDirection get direction => _direction;

  @override
  void initState() {
    super.initState();
    final i = ctx.intent;
    final nodes = ctx.controller.nodes;
    if (i != null && (i.kind == PlanModeIntentKind.linkFrom || i.kind == PlanModeIntentKind.linkPair)) {
      _a = i.nodeId;
      _b = i.otherId;
    } else {
      _a = ctx.selectedNodeId ?? nodes.firstOrNull?.id;
      _b = nodes.where((n) => n.id != _a).firstOrNull?.id;
    }
    ctx.hooks.onNodeTap = _onNodeTap;
    ctx.plan.addListener(_onPlan);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeRun();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    ctx.plan.removeListener(_onPlan);
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    super.dispose();
  }

  Plan get _plan => ctx.controller.plan;
  PlanNode? get _nodeA => _a == null ? null : _plan.node(_a!);
  PlanNode? get _nodeB => _b == null ? null : _plan.node(_b!);

  // ------------------------------------------------------------------------------------------------ ends

  bool _onNodeTap(String id) {
    if (id.startsWith('link-relay-')) {
      final i = int.tryParse(id.substring('link-relay-'.length));
      final r = _relays;
      if (i != null && r != null && i < r.length) _addRelay(i);
      return true;
    }
    if (id == 'link-ridge' || id == 'link-scrub') return true;
    if (_plan.node(id) == null) return false;
    // Taps fill A, then B, then alternate (B, A, B…), so two taps re-pick both ends.
    setState(() {
      if (_a == null || (_pickA && id != _b)) {
        _a = id;
        _pickA = false;
      } else if (id != _a) {
        _b = id;
        _pickA = true;
      }
    });
    unawaited(AppHaptics.selection());
    _maybeRun();
    return true;
  }

  void _onPlan() {
    if (!mounted) return;
    final p = _plan;
    setState(() {
      if (_a != null && p.node(_a!) == null) _a = null;
      if (_b != null && p.node(_b!) == null) _b = null;
      // A node that joins a plan with an end free fills it.
      _a ??= p.nodes.where((n) => n.id != _b).firstOrNull?.id;
      _b ??= p.nodes.where((n) => n.id != _a).firstOrNull?.id;
    });
    // Sliders and drags change the plan in steps: check once they settle.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _maybeRun();
    });
  }

  void _setEnds(String? a, String? b) {
    setState(() {
      _a = a;
      _b = b;
      _scrubT = null;
    });
    _maybeRun();
  }

  /// The height an end's antenna is at: its own, a handheld at the plan's receiver height, else its default.
  double _heightOf(PlanNode n) => n.heightM ?? (n.role == PlanNodeRole.handheld ? (_plan.receiverM ?? handheldHeightM) : n.antennaM);

  PlanLinkRequest? get _request {
    final a = _nodeA, b = _nodeB;
    if (a == null || b == null || a.id == b.id) return null;
    return PlanLinkRequest(
      a: a.point,
      b: b.point,
      haM: _heightOf(a),
      hbM: _heightOf(b),
      radio: _plan.radio,
      clutter: _plan.clutter,
      direction: _direction,
      aKey: a.existingKey,
      bKey: b.existingKey,
    );
  }

  double? get _km {
    final a = _nodeA, b = _nodeB;
    return a == null || b == null ? null : haversineKm(a.lat, a.lon, b.lat, b.lon);
  }

  bool get _inRange {
    final km = _km;
    return km != null && km >= 0.1 && km <= 40;
  }

  static String _pointsKey(PlanLinkRequest r) => '${r.a.lat},${r.a.lon}|${r.b.lat},${r.b.lon}';

  // ------------------------------------------------------------------------------------------------ checking

  void _maybeRun() {
    final r = _request;
    if (r == null || !_inRange) {
      _publish();
      return;
    }
    if (PlanApi.linkKey(r) == _askedKey) {
      _publish();
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    final r = _request;
    if (r == null || !_inRange) return;
    final a = _nodeA!, b = _nodeB!;
    final key = PlanApi.linkKey(r);
    final n = ++_seq;
    setState(() {
      _loading = true;
      _askedKey = key;
    });
    _publish();
    var res = await ctx.api.link(r, aTxDbm: a.effectiveTxDbm, bTxDbm: b.effectiveTxDbm, aGainDbi: a.effectiveGainDbi, bGainDbi: b.effectiveGainDbi);
    final pk = _pointsKey(r);
    if (!res.ok && res.unavailable) {
      // No server and no stored answer: re-judge the last profile seen for these two points on the phone.
      final s = _seen[pk];
      if (s != null && s.groundM.length >= 3) {
        res = PlanResult.ok(
          localPlanLink(r, s.groundM,
              km: s.km, aTxDbm: a.effectiveTxDbm, bTxDbm: b.effectiveTxDbm, aGainDbi: a.effectiveGainDbi, bGainDbi: b.effectiveGainDbi, terrain: s.terrain, asOf: s.at),
          at: s.at,
          offlineAsOf: s.at ?? DateTime.now().toUtc(),
          onDevice: true,
        );
      }
    }
    if (res.ok) {
      final d = res.data!;
      _seen[pk] = _SeenProfile(d.profile.groundM, d.km, d.provenance.terrain, res.at);
    }
    if (!mounted || n != _seq) return;
    setState(() {
      _loading = false;
      _res = res;
      _resReq = r;
      _resKey = key;
      if (_relayKey != _pointsKey(r)) {
        _relays = null;
        _relayError = null;
      }
    });
    if (res.ok) {
      final v = res.data!.verdict;
      unawaited(v == PlanVerdict.likely ? AppHaptics.success() : AppHaptics.warning());
    }
    _publish();
  }

  bool get _current {
    final req = _request;
    return _res != null && req != null && _resKey == PlanApi.linkKey(req);
  }

  // ------------------------------------------------------------------------------------------------ the map

  PlanPoint _along(PlanLinkRequest r, double t) => PlanPoint(r.a.lat + (r.b.lat - r.a.lat) * t, r.a.lon + (r.b.lon - r.a.lon) * t);

  PlanPoint? _ridgePoint() {
    final d = _res?.data, r = _resReq;
    final ridge = d?.ridge;
    if (d == null || r == null || ridge == null) return null;
    return ridge.at ?? (d.km > 0 ? _along(r, (ridge.km / d.km).clamp(0.0, 1.0)) : null);
  }

  void _publish() {
    if (!mounted) return;
    if (_a == null || _b == null) {
      ctx.setOverlay(PlanModeOverlay.empty);
      return;
    }
    final current = _current && _res!.ok;
    final units = AppScope.read(context).units;
    final targets = <MapFocusTarget>[];
    final ridge = current ? _ridgePoint() : null;
    if (ridge != null) targets.add(MapFocusTarget(id: 'link-ridge', at: LatLng(ridge.lat, ridge.lon), label: 'Ridge'));
    final r = _resReq, t = _scrubT, d = _res?.data;
    if (current && r != null && t != null && d != null) {
      final p = _along(r, t);
      targets.add(MapFocusTarget(id: 'link-scrub', at: LatLng(p.lat, p.lon), label: units.distance(d.km * t * 1000)));
    }
    final relays = _relays ?? const <RelayCandidate>[];
    for (var i = 0; i < relays.length; i++) {
      targets.add(MapFocusTarget(id: 'link-relay-$i', at: LatLng(relays[i].at.lat, relays[i].at.lon), label: 'R${i + 1}'));
    }
    ctx.setOverlay(PlanModeOverlay(
      links: [PlanOverlayLink(fromId: _a!, toId: _b!, verdict: current ? overlayVerdict(_res!.data!.verdict) : PlanLinkVerdict.unknown)],
      targets: targets,
    ));
  }

  void _scrub(double t) {
    final q = (t * 200).round() / 200;
    if (q == _scrubT) return;
    setState(() => _scrubT = q);
    unawaited(AppHaptics.selection());
    _publish();
  }

  // ------------------------------------------------------------------------------------------------ actions

  void _applyRaise(PlanNode end, double raiseM) {
    final from = _heightOf(end);
    final to = (from + raiseM).clamp(0.5, 300).toDouble();
    ctx.controller.updateNode(end.id, (n) => n.copyWith(heightM: to));
    unawaited(AppHaptics.success());
    final units = AppScope.read(context).units;
    showAppToast(context, '${end.name} is now ${units.height(to)} above ground.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: ctx.controller.undo);
  }

  Future<void> _findRelays() async {
    final a = _a, b = _b, r = _request;
    if (a == null || b == null || r == null) return;
    setState(() {
      _relayLoading = true;
      _relayError = null;
    });
    List<RelayCandidate> out;
    try {
      out = await ctx.controller.relaysFor(a, b, ctx.api.profile);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _relayLoading = false;
        _relays = null;
        _relayError = 'Could not read the terrain for relay points. Check the connection and try again.';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _relayLoading = false;
      _relays = out;
      _relayKey = _pointsKey(r);
    });
    _publish();
  }

  void _addRelay(int i) {
    final r = _relays;
    if (r == null || i >= r.length) return;
    final relays = _plan.nodes.where((n) => n.name.startsWith('Relay')).length;
    try {
      final node = ctx.controller.addRelay(r[i], name: 'Relay ${relays + 1}');
      unawaited(AppHaptics.success());
      setState(() {
        _relays = [for (var j = 0; j < r.length; j++) if (j != i) r[j]];
      });
      _publish();
      showAppToast(context, 'Added ${node.name} to the plan as a planned spot.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: ctx.controller.undo);
    } on PlanFullException catch (e) {
      showAppToast(context, e.toString(), kind: AppToastKind.error);
    }
  }

  Future<void> _snap(PlanNode n) async {
    setState(() => _snapping = n.id);
    final units = AppScope.read(context).units;
    final r = await ctx.controller.snapNode(n.id, linkSnapRadiusM, ctx.api.profile);
    if (!mounted) return;
    setState(() => _snapping = null);
    if (r == null) {
      showAppToast(context, 'Could not read the terrain around ${n.name}. Check the connection and try again.', kind: AppToastKind.error);
      return;
    }
    if (r.distanceM <= 1) {
      showAppToast(context, '${n.name} is already on the highest ground within ${units.distance(linkSnapRadiusM)}.');
      return;
    }
    unawaited(AppHaptics.success());
    final gain = r.gainM;
    showAppToast(
      context,
      'Moved ${n.name} ${units.distance(r.distanceM)} to ground at ${units.height(r.groundM)}${gain != null && gain > 0 ? ', ${units.height(gain)} higher' : ''}.',
      kind: AppToastKind.success,
      actionLabel: 'Undo',
      onAction: ctx.controller.undo,
    );
  }

  Future<void> _glossary() => showPlanGlossary(context);

  // ------------------------------------------------------------------------------------------------ build

  Color _verdictColour(BuildContext context, PlanVerdict? v) => v == null ? Theme.of(context).colorScheme.primary : verdictColour(context, v);

  /// Spot A / Spot B: the app's action-sheet pick field (round 4 P-V4; the Material dropdown opened over the content).
  Widget _endPicker(String label, String? value, ValueChanged<String?> onChanged, Key key) {
    final nodes = ctx.controller.nodes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: PickField<String?>(
        key: key,
        label: label,
        dense: true,
        value: value,
        options: [
          for (final n in nodes)
            PickOption<String?>(
              n.id,
              '${n.name}${n.mine ? ' (yours)' : n.status == PlanNodeStatus.existing ? ' (repeater)' : n.status == PlanNodeStatus.planned ? ' (planned spot)' : ''}',
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _button({required Key key, required String label, required AppSymbol symbol, required VoidCallback? onPressed, bool busy = false, bool filled = false}) {
    final icon = busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : AppSymbolIcon(symbol, size: 18);
    final style = ButtonStyle(minimumSize: WidgetStateProperty.all(Size.fromHeight(Hit.min + (filled ? 8 : 0))));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: filled
          ? FilledButton.icon(key: key, style: style, onPressed: busy ? null : onPressed, icon: icon, label: Text(label, textAlign: TextAlign.center))
          : OutlinedButton.icon(key: key, style: style, onPressed: busy ? null : onPressed, icon: icon, label: Text(label, textAlign: TextAlign.center)),
    );
  }

  Widget _header(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: Gap.m, bottom: Gap.xs),
        child: Semantics(header: true, child: Text(text, style: Theme.of(context).textTheme.titleSmall)),
      );

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final nodes = ctx.controller.nodes;
    if (nodes.length < 2) {
      // One spot short of a link (an empty plan shows the planner's first-run card instead). The list of spots below
      // has "Add from the network"; this offers the spot itself.
      return AppEmptyView(
        key: const Key('plan-mode-link'),
        symbol: AppSymbols.route,
        title: nodes.isEmpty ? 'Add two spots to check a link' : 'Add one more spot to check a link',
        message: 'A spot on the map, or a repeater from the network.',
        actionLabel: 'Add a spot',
        onAction: ctx.addSpot,
      );
    }
    final km = _km;
    final req = _request;
    final res = _res;
    final current = _current;
    return Column(key: const Key('plan-mode-link'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _endPicker('Spot A', _a, (v) => _setEnds(v, _b == v ? null : _b), Key('link-a-$_a')),
      _endPicker('Spot B', _b, (v) => _setEnds(_a == v ? null : _a, v), Key('link-b-$_b')),
      Wrap(spacing: Gap.s, runSpacing: 0, children: [
        TextButton.icon(
          key: const Key('link-swap'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: _a != null && _b != null ? () => _setEnds(_b, _a) : null,
          icon: const AppSymbolIcon(AppSymbols.route, size: 18),
          label: const Text('Swap A and B'),
        ),
        TextButton.icon(
          key: const Key('link-add-network'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: ctx.openNodePicker,
          icon: const AppSymbolIcon(AppSymbols.plus, size: 18),
          label: const Text('Add from the network'),
        ),
      ]),
      if (_b == null) const PlanLine(AppSymbols.infoCircle, 'Pick spot B: choose it above or tap a spot on the map.', key: Key('link-pick-b')),
      // Only until there is a result (build 76): after that the screen shows the answer, not a tip.
      if (res == null) Text('Tip: tap a spot on the map to pick it as A or B.', key: const Key('link-tip'), style: t.textTheme.bodySmall),
      if (km != null) PlanFact('Straight line', units.distance(km * 1000)),
      if (km != null && km > 40)
        PlanLine(AppSymbols.exclamationTriangle, 'The ends are ${units.distance(km * 1000)} apart; a link check reads terrain for up to ${units.distance(40000)}. Add a relay between them.',
            key: const Key('link-toofar')),
      if (km != null && km < 0.1)
        PlanLine(AppSymbols.exclamationTriangle, 'The ends are less than ${units.distance(100)} apart. Move one of them.', key: const Key('link-tooclose')),
      _header(context, 'Direction'),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        for (final d in const [PlanDirection.down, PlanDirection.up, PlanDirection.both])
          ChoiceChip(
            key: Key('link-dir-${d.wire}'),
            label: Text(directionWords(d)),
            selected: _direction == d,
            onSelected: (_) {
              setState(() => _direction = d);
              _maybeRun();
            },
          ),
      ]),
      const SizedBox(height: Gap.s),
      _button(
        key: const Key('link-run'),
        label: _loading ? 'Reading the terrain…' : current ? 'Check again' : 'Check this link',
        symbol: AppSymbols.route,
        busy: _loading,
        filled: true,
        onPressed: req != null && _inRange ? () => unawaited(_run()) : null,
      ),
      if (_loading && !(current && res!.ok))
        ConstrainedBox(
          key: const Key('link-loading'),
          constraints: const BoxConstraints(minHeight: 120),
          child: const AppLoadingView(label: 'Reading the terrain between the two ends…', timeout: Duration(seconds: 50)),
        ),
      if (res != null && !res.ok && current && !_loading)
        AppErrorView(
          key: const Key('link-error'),
          title: res.unavailable ? 'No answer: the link could not be checked' : 'Could not check the link',
          message: res.unavailable
              ? '${res.error} A link needs the terrain between its ends once; after that it is worked out on this phone, even offline.'
              : res.error,
          onRetry: () => unawaited(_run()),
        ),
      if (res != null && res.ok) _result(context, res, current, units),
      ..._receiver(context, units),
    ]);
  }

  Widget _result(BuildContext context, PlanResult<PlanLinkResult> r, bool current, Units units) {
    final t = Theme.of(context);
    final d = r.data!;
    final v = d.verdict;
    final rq = _resReq!;
    final a = _plan.node(_a ?? '') , b = _plan.node(_b ?? '');
    final aName = a?.name ?? 'A', bName = b?.name ?? 'B';
    final colour = _verdictColour(context, v);
    final model = d.marginDb == null ? null : verdictOf(d.marginDb!);
    final m = d.measured;
    final scrubPoint = _scrubT == null ? null : profilePointAt(d.profile, rq.haM, rq.hbM, lambdaFor(rq.radio), _scrubT!);
    // Which end the raise applies to: the one whose antenna (ground + mast) is lower (website linkGeometry).
    final g = d.profile.groundM;
    final raiseA = g.first + rq.haM <= g.last + rq.hbM;
    final raiseEnd = raiseA ? a : b;
    final raiseName = raiseA ? aName : bName;
    final raise = d.tightest?.raiseM ?? 0;
    final canRaise = raise > 0 && raise < raiseMaxM && raiseEnd != null && _heightOf(raiseEnd) + raise <= 300;
    final ridge = d.ridge;
    final notWorking = v != PlanVerdict.likely;
    return Column(key: const Key('link-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: Gap.s),
      if (!current) const PlanLine(AppSymbols.clock, 'The ends or settings changed: this is the last result. Check again to update it.', key: Key('link-stale')),
      if (v != null)
        Semantics(
          liveRegion: true,
          child: PlanLine(verdictSymbol(v), '${linkVerdictWords(v)} (Estimate)', key: const Key('link-verdict'), color: colour, style: t.textTheme.titleLarge),
        ),
      // Build 76: the verdict in a plain sentence with the next step, before any dB figure.
      if (v != null)
        Text(
          switch (v) {
            PlanVerdict.likely => 'These two should hear each other.',
            PlanVerdict.marginal => 'It may work some of the time. A higher antenna on either end helps.',
            PlanVerdict.unlikely => 'Something is in the way. Try a higher antenna, or a relay between them.',
          },
          key: const Key('link-plain'),
          style: t.textTheme.bodyLarge,
        ),
      // ---- what to change, in plain words (round 4 P-U4); the figures are under "The numbers".
      if (raise > 0 || ridge != null) _header(context, 'What to change'),
      if (raise > 0 && raise < raiseMaxM)
        PlanLine(AppSymbols.arrowUpCircleFill, 'Raise $raiseName ${units.height(raise)} to clear ${ridge != null ? 'the hill' : 'the ground in between'}.', key: const Key('link-raise')),
      if (canRaise)
        _button(
          key: const Key('link-raise-apply'),
          label: 'Raise $raiseName to ${units.height(_heightOf(raiseEnd) + raise)}',
          symbol: AppSymbols.arrowUpCircleFill,
          onPressed: () => _applyRaise(raiseEnd, raise),
        ),
      if (raise >= raiseMaxM || (raise > 0 && !canRaise))
        const PlanLine(AppSymbols.exclamationTriangle, 'No mast is tall enough to clear this path: put a relay on high ground between them.', key: Key('link-raise-relay')),
      if (ridge != null) ...[
        PlanLine(
          AppSymbols.flag,
          'A hill ${units.distance(ridge.km * 1000)} from $aName is in the way. It is marked on the chart and the map.',
          key: const Key('link-ridge'),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('link-ridge-show'),
            style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
            onPressed: () {
              final p = _ridgePoint();
              if (p != null) ctx.focusMap(p, zoom: 14);
            },
            icon: const AppSymbolIcon(AppSymbols.map, size: 18),
            label: const Text('Show the hill on the map'),
          ),
        ),
      ],
      // ---- the profile
      const SizedBox(height: Gap.s),
      ProfileChart(
        profile: d.profile,
        haM: rq.haM,
        hbM: rq.hbM,
        lambdaM: lambdaFor(rq.radio),
        ridgeKm: ridge?.km,
        lineColour: colour,
        scrubT: _scrubT,
        onScrub: _scrub,
        units: units,
        aName: aName,
        bName: bName,
      ),
      Text(
        scrubPoint == null ? 'Touch and drag along the chart: the spot shows on the map.' : profileReadout(scrubPoint, units, aName: aName),
        key: const Key('link-scrub-readout'),
        style: t.textTheme.bodySmall,
      ),
      Text('Shaded: the space the signal needs clear of hills.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      if (notWorking) ..._relaySection(context, units),
      ..._snapButtons(context, units, a, b),
      // ---- measured next to predicted
      _header(context, 'Measured'),
      if (m != null && m.echoes > 0 && model != null && v != null && model != v)
        PlanLine(
          AppSymbols.exclamationCircle,
          'The terrain model alone says ${linkVerdictWords(model)}, but ${m.echoes} measured ${m.echoes == 1 ? 'packet says' : 'packets say'} otherwise: the verdict follows the measurement.',
          key: const Key('link-disagree'),
          color: MeshSonarColors.of(context).warning,
        ),
      if (m == null && v == PlanVerdict.likely && a?.existingKey != null && b?.existingKey != null)
        const PlanLine(AppSymbols.exclamationCircle, 'The Estimate says it works, but no packets between these two have been Measured yet.', key: Key('link-never-heard')),
      if (m != null)
        PlanLine(
          AppSymbols.waveform,
          'Between them: ${m.echoes} ${m.echoes == 1 ? 'packet' : 'packets'} heard'
          '${m.lastAt == null ? '' : ', last ${dateOnly(m.lastAt!)}'} (${m.source}).',
          key: const Key('link-measured'),
        )
      else
        const PlanLine(AppSymbols.waveform, 'Between them: no packets or drives recorded yet.', key: Key('link-measured-none')),
      _driveCells(context, rq),
      PlanLine(
        d.provenance.confidence == PlanConfidenceLevel.measured ? AppSymbols.checkmarkCircleFill : AppSymbols.infoCircle,
        _confidenceLine(d.provenance),
        key: const Key('link-confidence'),
      ),
      // ---- the numbers
      _header(context, 'The numbers (Estimate)'),
      if (d.marginDb != null)
        PlanFact('Link margin after the ${fadeMarginDb.round()} dB fade margin (${directionWords(rq.direction)})', dbWords(d.marginDb!, signed: true), key: const Key('link-margin')),
      PlanFact('Distance', units.distance(d.km * 1000)),
      PlanFact('Antennas', '$aName ${units.height(rq.haM)}, $bName ${units.height(rq.hbM)} above ground'),
      if (raise > 0 && raise < raiseMaxM) PlanFact('Raise $raiseName to clear 60 % of the Fresnel zone', units.height(raise)),
      if (ridge?.groundM != null) PlanFact('Ground at the hill', units.height(ridge!.groundM!)),
      if (d.fresnelClearancePct != null)
        PlanFact('Fresnel zone open at the tightest point', d.fresnelClearancePct! < 0 ? 'blocked (${d.fresnelClearancePct!.round()} %)' : '${d.fresnelClearancePct!.round()} %'),
      if (d.odds != null) PlanFact('Terrain odds', '${(d.odds! * 100).clamp(0, 100).toStringAsFixed(0)} %'),
      if (m?.meanSnr != null) PlanFact('Measured mean SNR', dbWords(m!.meanSnr!)),
      ...resultNotes(context, r),
      Text(
        'Estimate from ${d.provenance.terrain.isEmpty ? 'bare-earth terrain' : d.provenance.terrain}; trees use the plan\'s Radio and trees setting. Model: ${d.provenance.model}. Not a promise.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('link-glossary'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: () => unawaited(_glossary()),
          icon: const AppSymbolIcon(AppSymbols.infoCircle, size: 18),
          label: const Text('What these words mean'),
        ),
      ),
    ]);
  }

  /// "Confidence: Measured (heard 41 times …)." The on-phone note "unobserved, estimate" only repeats the level.
  static String _confidenceLine(PlanProvenance p) {
    final note = p.confidenceNote;
    final level = confidenceWords(p.confidence);
    if (note == null || note.toLowerCase() == 'unobserved, estimate') {
      return p.confidence == PlanConfidenceLevel.estimate ? 'Confidence: $level. Nothing measured between these two yet; the model alone.' : 'Confidence: $level.';
    }
    return 'Confidence: $level ($note).';
  }

  PublicCoverage? _cellsFor;
  String? _cellsKey;
  (CalibrationConfidence, CalibrationConfidence)? _cells;

  Widget _driveCells(BuildContext context, PlanLinkRequest rq) {
    final cov = AppScope.of(context).networkCoverage;
    if (cov == null) {
      return const PlanLine(AppSymbols.car, 'Drive data: not loaded on this phone yet, so the numbers are the model alone.', key: Key('link-drive-cells'));
    }
    final key = _pointsKey(rq);
    if (!identical(cov, _cellsFor) || key != _cellsKey) {
      final centres = [for (final c in cov.cells) PlanPoint(c.lat, c.lon)];
      _cells = (
        calibrationConfidence(rq.a, centres, radiusKm: linkDriveCellRadiusKm),
        calibrationConfidence(rq.b, centres, radiusKm: linkDriveCellRadiusKm),
      );
      _cellsFor = cov;
      _cellsKey = key;
    }
    final (ca, cb) = _cells!;
    final units = AppScope.unitsOf(context);
    String words(CalibrationConfidence c) => c.observed
        ? '${c.driveCells} drive ${c.driveCells == 1 ? 'cell' : 'cells'} within ${units.distance(c.radiusKm * 1000)}'
        : 'no drives within ${units.distance(c.radiusKm * 1000)} (unobserved, estimate)';
    return PlanLine(
      AppSymbols.car,
      'Drive data near A: ${words(ca)}; near B: ${words(cb)}.',
      key: const Key('link-drive-cells'),
    );
  }

  List<Widget> _relaySection(BuildContext context, Units units) {
    final t = Theme.of(context);
    final relays = _relays;
    return [
      _header(context, 'Relay'),
      _button(
        key: const Key('link-relay-find'),
        label: _relayLoading ? 'Looking for relay points…' : relays == null ? 'Find a relay point' : 'Look again',
        symbol: AppSymbols.magnifyingglass,
        busy: _relayLoading,
        onPressed: () => unawaited(_findRelays()),
      ),
      if (_relayLoading) const PlanLine(AppSymbols.clock, 'Reading the terrain from both ends to a few high points between them…'),
      if (_relayError != null && !_relayLoading)
        AppErrorView(key: const Key('link-relay-error'), title: 'No relay points', message: _relayError, onRetry: () => unawaited(_findRelays())),
      if (relays != null && relays.isNotEmpty && !_relayLoading && relays.every((r) => r.verdict == PlanVerdict.unlikely))
        const PlanLine(AppSymbols.exclamationTriangle, 'None of these points makes both hops work at the default mast height. Try a taller mast on the relay, or Find sites for higher ground.',
            key: Key('link-relay-none-works')),
      if (relays != null && relays.isEmpty && !_relayLoading)
        const PlanLine(AppSymbols.infoCircle, 'No point between them was found that both ends reach. Try a spot on higher ground with Find sites.', key: Key('link-relay-empty')),
      if (relays != null && !_relayLoading)
        for (var i = 0; i < relays.length; i++)
          Padding(
            key: Key('link-relay-$i'),
            padding: const EdgeInsets.symmetric(vertical: Gap.xs),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PlanLine(
                verdictSymbol(relays[i].verdict),
                'R${i + 1}: ${linkVerdictWords(relays[i].verdict)} (Estimate). '
                '${relays[i].dualLineOfSight ? 'Clear line of sight to both ends' : 'No clear line of sight to both ends'}; '
                'weaker hop ${dbWords(relays[i].worstMarginDb, signed: true)} at ${units.height(relays[i].relayHeightM)}'
                '${relays[i].groundM == null ? '' : ', ground ${units.height(relays[i].groundM!)}'}.',
                color: _verdictColour(context, relays[i].verdict),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  key: Key('link-relay-add-$i'),
                  style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
                  onPressed: () => _addRelay(i),
                  icon: const AppSymbolIcon(AppSymbols.plus, size: 18),
                  label: Text('Add R${i + 1} to the plan', style: TextStyle(color: t.colorScheme.primary)),
                ),
              ),
            ]),
          ),
    ];
  }

  List<Widget> _snapButtons(BuildContext context, Units units, PlanNode? a, PlanNode? b) {
    final ends = [('a', a), ('b', b)].where((e) => e.$2 != null && e.$2!.status == PlanNodeStatus.planned).toList();
    if (ends.isEmpty) return const [];
    return [
      _header(context, 'High ground'),
      for (final (which, n) in ends)
        _button(
          key: Key('link-snap-$which'),
          label: _snapping == n!.id ? 'Reading the terrain around ${n.name}…' : 'Move ${n.name} to the highest ground within ${units.distance(linkSnapRadiusM)}',
          symbol: AppSymbols.arrowUpCircleFill,
          busy: _snapping == n.id,
          onPressed: _snapping == null ? () => unawaited(_snap(n)) : null,
        ),
    ];
  }

  /// The receiver height for a handheld end (the one link setting the Radio and trees sheet does not hold). The radio and
  /// the trees are no longer repeated here under other names (round 4): they live in Radio and trees only.
  List<Widget> _receiver(BuildContext context, Units units) {
    final p = _plan;
    final a = _nodeA, b = _nodeB;
    final handheldEnds = [if (a != null && a.role == PlanNodeRole.handheld && a.heightM == null) 'A', if (b != null && b.role == PlanNodeRole.handheld && b.heightM == null) 'B'];
    final rx = p.receiverM ?? handheldHeightM;
    return [
      const SizedBox(height: Gap.s),
      SliderTile(
        key: const ValueKey('link-receiver'),
        sliderKey: const Key('link-receiver-slider'),
        icon: symbolData(context, AppSymbols.person),
        title: 'Receiver height',
        caption: handheldEnds.isEmpty ? null : 'Used for spot ${handheldEnds.join(' and ')} (a handheld).',
        enabled: handheldEnds.isNotEmpty,
        disabledReason: 'Both ends have their own antenna heights. A handheld end (a contact or your companion radio) uses this height.',
        stops: _receiverStops,
        value: (rx * 10).round(),
        label: (v) => units.height(v / 10),
        onChanged: (v) => ctx.controller.setReceiverM(v / 10),
      ),
    ];
  }
}

/// Receiver heights offered, decimetres (1 m to 10 m; 1.5 m is a hand).
const List<int> _receiverStops = [10, 15, 20, 30, 50, 80, 100];
