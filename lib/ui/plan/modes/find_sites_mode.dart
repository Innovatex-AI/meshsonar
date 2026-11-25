// Find sites (release 0.38 A10, plan §4.4, flow C "where should I put one"): a query in two stages over the region's
// candidate table, fed by our own data.
//
//   * This view: goal chips (Coverage / Links / Redundancy / Best overall) rank up to 20 places in the part of the map
//     above the sheet (POST plan-suggest, stage 1). Each comes back as a numbered pin with its reason, its stage-1
//     estimate (new area, people, links it would make, redundancy gain) and actions: Add to plan, Navigate (Apple Maps,
//     like DriveNextCard) and Show (move the map there). "Verify top 5" runs the real model on the first five, one site
//     after the other (POST plan-verify once per site; the server runs one verify at a time) and shows the model's numbers
//     beside the estimate. "Show on the Drive map" opens the Drive tab with the picks drawn as targets (MainMapFocus).
//   * Guide me (wizard.dart): a Personal - Balanced - Mesh slider, then a ZIP code / address (looked up on the phone, never
//     sent) or a point on the map, rounded to about 1 km before it leaves the phone, and two ranked lists, "For your
//     coverage" and "To extend the mesh".
//
// Privacy: only the view (or the rounded point and a box around it) and the plan's radio settings are sent. Positions
// that are not public (the U+1F6AB mark, `position_public false`) never become candidates: the server leaves them out of
// its table, and [publicCandidates] drops anything that is an existing node or sits on a node whose position is hidden,
// so the phone never shows one either.
//
// States: loading (a spinner that gives up), error with a retry, "preparing this region" (the server is building the
// table; checked again every 30 s while open), empty, offline (the saved result), and per-site verify progress/errors.
//
// Keys: 'plan-mode-sites' (the body), 'sites-tab-view' / 'sites-tab-wizard', 'sites-goal-<goal>', 'sites-run',
// 'sites-error', 'sites-preparing', 'sites-empty', 'sites-result', 'sites-verify', 'sites-drive-map', and per site
// '<base>-<id>', '<base>-add-<id>', '<base>-nav-<id>', '<base>-show-<id>', '<base>-check-<id>' with base `site` here and
// `wiz-c` / `wiz-m` in the wizard.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../../core/plan/link_model.dart' show ftM, haversineKm;
import '../../../core/plan/plan_api.dart';
import '../../../core/plan/plan_controller.dart';
import '../../../core/plan/plan_model.dart';
import '../../../core/plan_contract.dart';
import '../../../core/units.dart' show Units;
import '../../app.dart';
import '../../design/app_haptics.dart';
import '../../design/app_surfaces.dart';
import '../../design/app_symbols.dart';
import '../../design/state_views.dart';
import '../../design/tokens.dart';
import '../../map/main_map_focus.dart';
import '../../nodes/node_ref.dart' show nameHidesPosition;
import '../../shell/drive_next_card.dart' show DriveTargetActions, focusTargetsFromSites, showTargetsOnDriveMap;
import '../plan_modes.dart';
import 'wizard.dart';

// ------------------------------------------------------------------------------------------------ the mode

class FindSitesMode extends PlanMode {
  const FindSitesMode();
  @override
  PlanModeId get id => PlanModeId.findSites;
  @override
  String get label => 'Find sites';
  @override
  AppSymbol get symbol => AppSymbols.magnifyingglass;
  @override
  String get hint => 'Where a new repeater would help most: in the part of the map you are looking at, or near you.';
  @override
  String get what => 'Where would a new repeater help most?';
  @override
  bool get needsNodes => false;
  @override
  Widget buildSheet(PlanModeContext context) => FindSitesBody(context, key: const ValueKey('plan-mode-body-sites'));
}

// ------------------------------------------------------------------------------------------------ shared pieces (also wizard.dart)

/// The goal chips, in the order the spec lists them.
const List<PlanGoal> kSiteGoals = [PlanGoal.coverage, PlanGoal.links, PlanGoal.redundancy, PlanGoal.overall];

String siteGoalWords(PlanGoal g) => switch (g) {
      PlanGoal.overall => 'Best overall',
      PlanGoal.coverage => 'Coverage',
      PlanGoal.links => 'Links',
      PlanGoal.redundancy => 'Redundancy',
    };

/// The most pins a list shows (the server caps a request at the same number).
const int kMaxSites = PlanSuggestRequest.maxLimit;

/// How many sites "Verify top 5" runs the real model on.
const int kVerifyTop = 5;

/// Candidate kinds that are an existing node rather than a place to build: never shown.
const Set<String> _nodeKinds = {'repeater', 'room', 'node', 'existing', 'observer', 'companion', 'sensor', 'contact'};

/// The suggestions the phone may show: at most [kMaxSites], never an existing node, never a spot within 150 m of a node
/// whose position is not public ([hiddenNodes]), never one whose OSM operator carries the "position not public" mark.
/// The server already guarantees this; the phone checks again so a stale or wrong table cannot expose one.
List<PlanSite> publicCandidates(Iterable<PlanSite> sites, {Iterable<PlanPoint> hiddenNodes = const []}) {
  final hidden = hiddenNodes.toList();
  return [
    for (final s in sites)
      if (!_nodeKinds.contains(s.kind.toLowerCase()) &&
          !nameHidesPosition(s.osmOperator) &&
          hidden.every((h) => haversineKm(h.lat, h.lon, s.at.lat, s.at.lon) > 0.15))
        s,
  ].take(kMaxSites).toList();
}

/// Positions of the repeaters this phone knows (the region roster and the network list) whose names say "do not share
/// my position", so [publicCandidates] can keep suggestions off them.
List<PlanPoint> hiddenNodePoints(BuildContext context) {
  final s = AppScope.read(context);
  return [
    for (final r in [...s.regionRepeaterSet.rows, ...s.globalRepeaterSet.rows])
      if (nameHidesPosition(r.name)) PlanPoint(r.lat, r.lon),
  ];
}

String peopleWords(int n) {
  final s = n.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${n < 0 ? '-' : ''}$b ${n == 1 ? 'person' : 'people'}';
}

String _kindWords(PlanSite s, Units units) {
  final what = switch (s.kind) {
    'terrain' => 'High ground',
    'pole' => 'Pole',
    'tower' => 'Tower',
    'building' => 'Building',
    'tree' => 'Treetop',
    _ => 'Site',
  };
  final mount = switch (s.mount) {
    PlanMount.ground => 'on a pole',
    PlanMount.tree => 'at treetop',
    PlanMount.building => 'on the roof',
    null => null,
  };
  final h = s.heightAboveM;
  return [what, ?mount, if (h != null) 'antenna ${units.height(h)} up'].join(', ');
}

/// The stage-1 numbers of [s], in words (every one is an Estimate).
String stageOneWords(PlanSite s, Units units) {
  final g = s.gain;
  final parts = <String>[
    if (g.newAreaKm2 != null) '+${areaWords(units, g.newAreaKm2!)} new',
    if (g.newPeople != null && g.newPeople! > 0) peopleWords(g.newPeople!),
    if (g.newLinks.isNotEmpty)
      g.newLinks.length == 1
          ? 'reaches ${g.newLinks.single.name}${g.newLinks.single.tier == null ? '' : ' (${g.newLinks.single.tier})'}'
          : 'reaches ${g.newLinks.length} repeaters',
  ];
  return parts.isEmpty ? 'Estimate: no gain figures for this site.' : 'Estimate: ${parts.join(', ')}.';
}

String? redundancyWords(PlanSite s) => switch (s.gain.redundancy) {
      PlanRedundancyGain.none => null,
      PlanRedundancyGain.secondPath => 'Gives a second path to part of the mesh.',
      PlanRedundancyGain.joinsComponents => 'Joins two separate parts of the mesh.',
      PlanRedundancyGain.removesSpof =>
        s.gain.spofName == null ? 'Removes a single point of failure.' : 'Removes the single point of failure at ${s.gain.spofName}.',
    };

String confidenceWords(PlanProvenance p) {
  final level = switch (p.confidence) {
    PlanConfidenceLevel.measured => 'measured',
    PlanConfidenceLevel.calibrated => 'calibrated on measured data',
    PlanConfidenceLevel.estimate => 'estimate only, not observed here',
  };
  return 'Confidence: $level${p.confidenceNote == null ? '' : ' (${p.confidenceNote})'}.';
}

/// What the real model said about one site (plan-verify, or the coverage painter when plan-verify is not on the server).
class SiteCheck {
  final double coveredKm2;
  final double? newAreaKm2;
  final int? newPeople;

  /// Live repeaters predicted to hear the site (margin at or above 0 dB).
  final int heardBy;
  final String terrain;
  final PlanProvenance? provenance;
  const SiteCheck({required this.coveredKm2, this.newAreaKm2, this.newPeople, required this.heardBy, required this.terrain, this.provenance});

  factory SiteCheck.ofVerify(PlanVerifyResult r) => SiteCheck(
        coveredKm2: r.coveredKm2,
        newAreaKm2: r.newAreaKm2,
        newPeople: r.newPeople,
        heardBy: r.links.where((l) => l.marginDb >= 0).length,
        terrain: r.provenance.terrain,
        provenance: r.provenance,
      );

  factory SiteCheck.ofPainter(PainterResult r) => SiteCheck(
        coveredKm2: r.coveredKm2,
        newPeople: r.peopleNew,
        heardBy: r.links.where((l) => l.marginDb >= 0).length,
        terrain: r.terrainSource,
      );
}

/// The real-model runs of one list of sites ("Verify top 5"), one site after the other.
class SiteChecks {
  final Map<String, PlanResult<SiteCheck>> results = {};
  final Set<String> running = {};

  /// 1-based index of the site being verified and how many in this run (null when idle).
  int? step, of;
  int _run = 0;
  bool get busy => step != null;

  void clear() {
    _run++;
    results.clear();
    running.clear();
    step = of = null;
  }

  static PlanVerifyRequest requestFor(PlanSite s, Plan p) => PlanVerifyRequest(
        site: s.at,
        radio: p.radio,
        antennaM: s.heightAboveM ?? (s.mount == null ? plannedHeightM : mountHeightM(s.mount!)),
        clutter: p.clutter,
        receiverM: p.receiverM,
        mount: s.mount,
      );

  /// Verifies [site] (plan-verify; the coverage painter when the server does not have plan-verify yet).
  static Future<PlanResult<SiteCheck>> checkOne(BuildContext context, PlanModeContext ctx, PlanSite site) async {
    final r = requestFor(site, ctx.controller.plan);
    final v = await ctx.api.verify(r);
    if (v.ok) return PlanResult.ok(SiteCheck.ofVerify(v.data!), at: v.at, offlineAsOf: v.offlineAsOf);
    if (!v.unavailable || !context.mounted) return PlanResult.fail(v.error ?? 'No answer.');
    final s = AppScope.read(context);
    final p = await CoveragePainterApi(s.planBaseUrl, s.planStore).paint(PainterParams(
      lat: r.site.lat,
      lon: r.site.lon,
      antennaFt: (r.antennaM / ftM).clamp(6, 200).toDouble(),
      txDbm: r.txDbm.clamp(0, 30).toDouble(),
      gainDbi: r.gainDbi.clamp(-3, 12).toDouble(),
    ));
    return p.ok ? PlanResult.ok(SiteCheck.ofPainter(p.data!), at: p.at, offlineAsOf: p.offlineAsOf) : PlanResult.fail(p.error ?? v.error ?? 'No answer.');
  }

  /// Verifies the first [kVerifyTop] of [sites] in order, calling [changed] after each step. Stops when [alive] turns
  /// false or a newer run (or [clear]) started.
  Future<void> verifyTop(BuildContext context, PlanModeContext ctx, List<PlanSite> sites, {required VoidCallback changed, required bool Function() alive}) async {
    final top = sites.take(kVerifyTop).toList();
    if (top.isEmpty) return;
    final run = ++_run;
    of = top.length;
    for (var i = 0; i < top.length; i++) {
      if (!alive() || run != _run || !context.mounted) return;
      step = i + 1;
      running.add(top[i].id);
      changed();
      final res = await checkOne(context, ctx, top[i]);
      if (!alive() || run != _run) return;
      running.remove(top[i].id);
      results[top[i].id] = res;
      changed();
    }
    step = of = null;
    changed();
  }

  /// Verifies one site again (its retry).
  Future<void> retry(BuildContext context, PlanModeContext ctx, PlanSite site, {required VoidCallback changed, required bool Function() alive}) async {
    final run = _run;
    running.add(site.id);
    results.remove(site.id);
    changed();
    final res = await checkOne(context, ctx, site);
    if (!alive() || run != _run) return;
    running.remove(site.id);
    results[site.id] = res;
    changed();
  }
}

/// True when the plan already has a node on [s].
bool siteInPlan(PlanController c, PlanSite s) => c.nodes.any((n) => (n.lat - s.at.lat).abs() < 1e-6 && (n.lon - s.at.lon).abs() < 1e-6);

/// Adds [s] as a planned node named [name] (made unique in the plan), selects it and offers Undo.
void addSiteToPlan(BuildContext context, PlanModeContext ctx, PlanSite s, String name) {
  final c = ctx.controller;
  var n = name;
  for (var i = 2; c.nodes.any((x) => x.name == n); i++) {
    n = '$name ($i)';
  }
  try {
    final node = c.addNode(name: n, lat: s.at.lat, lon: s.at.lon, mount: s.mount, heightM: s.heightAboveM);
    ctx.selectNode(node.id);
    unawaited(AppHaptics.success());
    showAppToast(context, 'Added ${node.name} to the plan.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: c.undo);
  } on PlanFullException catch (e) {
    showAppToast(context, e.toString(), kind: AppToastKind.error);
  }
}

/// The pin of [s] as a Drive-map target (one place), for the row's "Show on the Drive map".
List<MapFocusTarget> siteTargets(PlanSite s, String pin) => [MapFocusTarget(id: s.id, at: LatLng(s.at.lat, s.at.lon), label: pin)];

Widget sitesPrimaryButton({required Key key, required String label, required AppSymbol symbol, required VoidCallback? onPressed, bool busy = false}) =>
    FilledButton.icon(
      key: key,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 8)),
      onPressed: busy ? null : onPressed,
      icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : AppSymbolIcon(symbol, size: 18),
      label: Text(label, textAlign: TextAlign.center),
    );

Widget sitesSecondaryButton({required Key key, required String label, required AppSymbol symbol, required VoidCallback? onPressed}) => OutlinedButton.icon(
      key: key,
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min)),
      onPressed: onPressed,
      icon: AppSymbolIcon(symbol, size: 18),
      label: Text(label, textAlign: TextAlign.center),
    );

/// One ranked site: its number (the pin's label), reason, stage-1 estimate, the model's numbers once verified, and the
/// actions Add to plan, Show here, Navigate and Show on the Drive map.
class SiteRow extends StatelessWidget {
  final String keyBase;

  /// The pin's label on the map (`#1`, `C2`...).
  final String pin;

  /// The name the site gets in the plan and in Maps.
  final String name;
  final PlanSite site;
  final PlanResult<SiteCheck>? check;
  final bool checking, inPlan;
  final VoidCallback onAdd, onShow;
  final VoidCallback? onRetryCheck;
  const SiteRow({
    super.key,
    required this.keyBase,
    required this.pin,
    required this.name,
    required this.site,
    required this.check,
    required this.checking,
    required this.inPlan,
    required this.onAdd,
    required this.onShow,
    this.onRetryCheck,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final cs = t.colorScheme;
    final units = AppScope.unitsOf(context);
    final s = site;
    final red = redundancyWords(s);
    final c = check;
    return Padding(
      key: Key('$keyBase-${s.id}'),
      padding: const EdgeInsets.symmetric(vertical: Gap.s),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MergeSemantics(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(
              label: 'Pin $pin',
              excludeSemantics: true,
              child: Container(
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(16)),
                child: Text(pin, style: t.textTheme.labelLarge?.copyWith(color: cs.onPrimaryContainer, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.reason.isEmpty ? name : s.reason, style: t.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
                Text('${_kindWords(s, units)} · score ${s.score.round()} of 100', style: t.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
        PlanLine(AppSymbols.chartBar, stageOneWords(s, units)),
        if (red != null) PlanLine(AppSymbols.route, red),
        if (s.deadZoneDrives > 0)
          PlanLine(AppSymbols.car, '${s.deadZoneDrives} ${s.deadZoneDrives == 1 ? 'drive' : 'drives'} heard nothing near here (measured).'),
        if (checking)
          const PlanLine(AppSymbols.clock, 'Running the full model on this site…')
        else if (c != null && c.ok)
          _model(context, c, units)
        else if (c != null)
          Column(key: Key('$keyBase-check-${s.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PlanLine(AppSymbols.exclamationTriangle, 'Could not verify: ${c.error}', color: cs.error),
            if (onRetryCheck != null)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
                  onPressed: onRetryCheck,
                  icon: const AppSymbolIcon(AppSymbols.arrowUpCircleFill, size: 18),
                  label: Text('Verify again', semanticsLabel: 'Verify pin $pin again'),
                ),
              ),
          ]),
        Wrap(spacing: Gap.xs, runSpacing: 0, children: [
          TextButton.icon(
            key: Key('$keyBase-add-${s.id}'),
            style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
            onPressed: inPlan ? null : onAdd,
            icon: AppSymbolIcon(inPlan ? AppSymbols.checkmarkCircleFill : AppSymbols.plus, size: 18),
            label: Text(inPlan ? 'In the plan' : 'Add', semanticsLabel: inPlan ? 'Pin $pin is in the plan' : 'Add pin $pin to the plan'),
          ),
          TextButton.icon(
            key: Key('$keyBase-show-${s.id}'),
            style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
            onPressed: onShow,
            icon: const AppSymbolIcon(AppSymbols.map, size: 18),
            label: Text('Show here', semanticsLabel: 'Show pin $pin on this map'),
          ),
        ]),
        // Navigate (Apple Maps) and Show on the Drive map, the same pair every drive target has (drive_next_card.dart).
        KeyedSubtree(
          key: Key('$keyBase-nav-${s.id}'),
          child: Semantics(
            container: true,
            label: 'Directions to pin $pin',
            child: DriveTargetActions(name: name, lat: s.at.lat, lon: s.at.lon, targets: siteTargets(s, pin)),
          ),
        ),
      ]),
    );
  }

  Widget _model(BuildContext context, PlanResult<SiteCheck> r, Units units) {
    final t = Theme.of(context);
    final d = r.data!;
    final parts = <String>[
      '${areaWords(units, d.coveredKm2)} covered',
      if (d.newAreaKm2 != null) '+${areaWords(units, d.newAreaKm2!)} new',
      if (d.newPeople != null) '${peopleWords(d.newPeople!)} not covered today',
      d.heardBy == 0 ? 'no live repeater hears it' : 'heard by ${d.heardBy} live ${d.heardBy == 1 ? 'repeater' : 'repeaters'}',
    ];
    return Column(key: Key('$keyBase-check-${site.id}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PlanLine(AppSymbols.checkmarkCircleFill, 'Model (Verify): ${parts.join(', ')}.', color: t.colorScheme.primary, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
      if (r.offlineAsOf != null) const PlanLine(AppSymbols.wifi, 'Offline: the saved model run for this site.'),
      if (d.provenance != null) Text(confidenceWords(d.provenance!), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

/// The "preparing this region" state: the server is building the region's candidate table. Checked again every 30 s
/// while it shows; [onRetry] checks now.
class SitesPreparingView extends StatelessWidget {
  final String? note;
  final VoidCallback onRetry;
  const SitesPreparingView({super.key, this.note, required this.onRetry});

  @override
  Widget build(BuildContext context) => AppEmptyView(
        symbol: AppSymbols.clock,
        title: 'Preparing this region',
        message: '${note ?? 'The server is working out the candidate sites for this region.'} MeshSonar checks again every 30 seconds while this is open.',
        actionLabel: 'Check now',
        onAction: onRetry,
      );
}

// ------------------------------------------------------------------------------------------------ the body

enum _Tab { view, wizard }

class FindSitesBody extends StatefulWidget {
  final PlanModeContext ctx;
  const FindSitesBody(this.ctx, {super.key});
  @override
  State<FindSitesBody> createState() => _FindSitesBodyState();
}

class _FindSitesBodyState extends State<FindSitesBody> {
  _Tab _tab = _Tab.view;
  bool _loading = false;
  PlanResult<PlanSuggestResult>? _res;
  List<PlanSite> _sites = const [];
  PlanGoal? _askedGoal;
  String? _noView;
  int _seq = 0;
  Timer? _again;
  int _preparingTries = 0;
  final SiteChecks _checks = SiteChecks();
  late final WizardModel _wizard = WizardModel(widget.ctx, onChanged: _onWizard);

  PlanModeContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    ctx.hooks.onNodeTap = _onNodeTap;
    ctx.plan.addListener(_onPlan);
    ctx.setOverlay(PlanModeOverlay.empty);
  }

  @override
  void dispose() {
    _again?.cancel();
    _checks.clear();
    _wizard.dispose();
    ctx.plan.removeListener(_onPlan);
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    super.dispose();
  }

  void _onPlan() {
    if (mounted) setState(() {});
  }

  void _onWizard() {
    if (!mounted) return;
    setState(() {});
    if (_tab == _Tab.wizard) _publish();
  }

  bool _onNodeTap(String id) {
    if (id.startsWith('wiz-')) return _wizard.onTargetTap(context, id);
    if (!id.startsWith('site-')) return false;
    final i = _sites.indexWhere((x) => 'site-${x.id}' == id);
    if (i < 0) return false;
    if (!siteInPlan(ctx.controller, _sites[i])) addSiteToPlan(context, ctx, _sites[i], 'Site ${i + 1}');
    return true;
  }

  List<MapFocusTarget> get _targets => [
        for (var i = 0; i < _sites.length; i++)
          MapFocusTarget(id: 'site-${_sites[i].id}', at: LatLng(_sites[i].at.lat, _sites[i].at.lon), label: '#${i + 1}'),
      ];

  void _publish() => ctx.setOverlay(PlanModeOverlay(targets: _tab == _Tab.view ? _targets : _wizard.targets));

  void _setTab(_Tab t) {
    if (t == _tab) return;
    setState(() => _tab = t);
    if (t != _Tab.wizard) _wizard.stopPicking();
    unawaited(AppHaptics.selection());
    _publish();
  }

  Future<void> _run({bool auto = false}) async {
    _again?.cancel();
    final b = ctx.visibleBounds();
    if (b == null) {
      setState(() => _noView = 'The map has not opened yet. Try again in a moment.');
      return;
    }
    if (!auto) _preparingTries = 0;
    final p = ctx.controller.plan;
    final n = ++_seq;
    final hidden = hiddenNodePoints(context);
    setState(() {
      _loading = true;
      _noView = null;
    });
    final r = await ctx.api.suggest(PlanSuggestRequest(
      bounds: b,
      goal: p.goal,
      limit: kMaxSites,
      radio: p.radio,
      clutter: p.clutter,
      receiverM: p.receiverM,
    ));
    if (!mounted || n != _seq) return;
    setState(() {
      _loading = false;
      _res = r;
      _askedGoal = p.goal;
      _sites = r.ok ? publicCandidates(r.data!.sites, hiddenNodes: hidden) : const [];
      _checks.clear();
    });
    if (r.ok && r.data!.preparing && _preparingTries < 10) {
      _preparingTries++;
      _again = Timer(const Duration(seconds: 30), () {
        if (mounted) unawaited(_run(auto: true));
      });
    }
    _publish();
  }

  void _pickGoal(PlanGoal g) {
    if (ctx.controller.plan.goal == g) return;
    ctx.controller.setGoal(g);
    unawaited(AppHaptics.selection());
    setState(() {});
    // A list on screen re-ranks for the new goal at once.
    if (_res != null && !_loading) unawaited(_run());
  }

  Future<void> _verify() => _checks.verifyTop(context, ctx, _sites, changed: () {
        if (mounted) setState(() {});
      }, alive: () => mounted);

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Column(key: const Key('plan-mode-sites'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        ChoiceChip(
          key: const Key('sites-tab-view'),
          avatar: const AppSymbolIcon(AppSymbols.map, size: 16),
          label: const Text('This view'),
          selected: _tab == _Tab.view,
          onSelected: (_) => _setTab(_Tab.view),
        ),
        ChoiceChip(
          key: const Key('sites-tab-wizard'),
          avatar: const AppSymbolIcon(AppSymbols.person, size: 16),
          label: const Text('Guide me'),
          selected: _tab == _Tab.wizard,
          onSelected: (_) => _setTab(_Tab.wizard),
        ),
      ]),
      const SizedBox(height: Gap.s),
      if (_tab == _Tab.view) ...[
        Semantics(header: true, child: Text('Goal', style: t.textTheme.titleSmall)),
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
          for (final g in kSiteGoals)
            ChoiceChip(
              key: Key('sites-goal-${g.wire}'),
              label: Text(siteGoalWords(g)),
              selected: ctx.controller.plan.goal == g,
              onSelected: (_) => _pickGoal(g),
            ),
        ]),
        const SizedBox(height: Gap.s),
        ..._viewBody(context),
      ] else
        FindSitesWizard(model: _wizard),
    ]);
  }

  List<Widget> _viewBody(BuildContext context) {
    final t = Theme.of(context);
    final r = _res;
    return [
      Text('Finds the best $kMaxSites places in the map area you can see. Only that area and the radio settings are sent.',
          style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.s),
      sitesPrimaryButton(
        key: const Key('sites-run'),
        label: _loading ? 'Finding sites…' : r == null ? 'Find sites in this view' : 'Find again in this view',
        symbol: AppSymbols.magnifyingglass,
        busy: _loading,
        onPressed: () => unawaited(_run()),
      ),
      const SizedBox(height: Gap.s),
      if (_noView != null) PlanLine(AppSymbols.infoCircle, _noView!),
      if (_loading && (r == null || !r.ok || _sites.isEmpty))
        ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 120),
          child: AppLoadingView(label: 'Ranking places from the network data…', timeout: const Duration(seconds: 35), onRetry: () => unawaited(_run())),
        ),
      if (!_loading && r != null && !r.ok)
        AppErrorView(
          key: const Key('sites-error'),
          title: r.unavailable ? 'Find sites is not on this region\'s server yet' : 'Could not find sites',
          message: r.unavailable ? '${r.error} Your plan, Link and Coverage keep working; try again later.' : r.error,
          onRetry: () => unawaited(_run()),
        ),
      if (!_loading && r != null && r.ok && r.data!.preparing)
        SitesPreparingView(key: const Key('sites-preparing'), note: r.data!.notes.firstOrNull, onRetry: () => unawaited(_run())),
      if (!_loading && r != null && r.ok && !r.data!.preparing && _sites.isEmpty)
        AppEmptyView(
          key: const Key('sites-empty'),
          symbol: AppSymbols.magnifyingglass,
          title: 'No sites in this view',
          message: 'Zoom out or move the map, then try again.',
          actionLabel: 'Try again',
          onAction: () => unawaited(_run()),
        ),
      if (r != null && r.ok && _sites.isNotEmpty) ..._results(context, r),
    ];
  }

  List<Widget> _results(BuildContext context, PlanResult<PlanSuggestResult> r) {
    final t = Theme.of(context);
    final d = r.data!;
    final goal = ctx.controller.plan.goal;
    final c = _checks;
    final verified = _sites.take(kVerifyTop).every((s) => c.results[s.id]?.ok == true);
    return [
      if (_askedGoal != null && _askedGoal != goal)
        PlanLine(AppSymbols.clock, 'Ranked for ${siteGoalWords(_askedGoal!)}; re-ranking for ${siteGoalWords(goal)}…'),
      MergeSemantics(
        child: PlanLine(
          AppSymbols.mapFill,
          '${_sites.length} ${_sites.length == 1 ? 'site' : 'sites'} for ${siteGoalWords(_askedGoal ?? goal)}'
          '${d.pool > 0 ? ', from ${d.pool} candidates in this region' : ''}. Every number is an Estimate until verified.',
          style: t.textTheme.titleSmall,
        ),
      ),
      ...resultNotes(context, r),
      sitesPrimaryButton(
        key: const Key('sites-verify'),
        label: c.busy
            ? 'Verifying ${c.step} of ${c.of}…'
            : verified
                ? 'Verify top $kVerifyTop again'
                : 'Verify top ${_sites.length < kVerifyTop ? _sites.length : kVerifyTop} with the full model',
        symbol: AppSymbols.antenna,
        busy: c.busy,
        onPressed: () => unawaited(_verify()),
      ),
      if (c.busy) const PlanLine(AppSymbols.clock, 'One site at a time. Each can take up to a minute.'),
      const SizedBox(height: Gap.xs),
      sitesSecondaryButton(
        key: const Key('sites-drive-map'),
        label: 'Show all on the Drive map',
        symbol: AppSymbols.car,
        onPressed: () => showTargetsOnDriveMap(context, focusTargetsFromSites(_sites), zoom: 11),
      ),
      Column(key: const Key('sites-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (var i = 0; i < _sites.length; i++)
          SiteRow(
            keyBase: 'site',
            pin: '#${i + 1}',
            name: 'Site ${i + 1}',
            site: _sites[i],
            check: c.results[_sites[i].id],
            checking: c.running.contains(_sites[i].id),
            inPlan: siteInPlan(ctx.controller, _sites[i]),
            onAdd: () => addSiteToPlan(context, ctx, _sites[i], 'Site ${i + 1}'),
            onShow: () => ctx.focusMap(_sites[i].at, zoom: 14),
            onRetryCheck: () => unawaited(c.retry(context, ctx, _sites[i], changed: () {
              if (mounted) setState(() {});
            }, alive: () => mounted)),
          ),
      ]),
      Text(
        '${confidenceWords(d.provenance)} Model: ${d.provenance.model}; terrain: ${d.provenance.terrain}.',
        style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
      ),
      for (final n in d.notes) Text(n, style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ];
  }
}
