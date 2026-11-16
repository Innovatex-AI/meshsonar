// Coverage mode of the Planner (release 0.38 A9; plan §4.2 job B "what would a repeater here cover", improvements 8, 9, 13,
// 20 display). For each node of the plan it asks plan-verify (the website's coverage model, the coverage painter when a
// server does not have plan-verify yet) with the plan's own radio and clutter, the node's height (mount presets), power
// and gain, and the receiver the person picks (handheld, car roof, rooftop, and its height). Every answer is kept as
// received power per cell (footprint_field.dart), so:
//   * the footprints draw as ONE layer on the planner map (footprint_layer.dart), coloured by signal or by how many sites
//     reach a cell, with opacity and minimum-SNR sliders that re-style without a request;
//   * a change of spreading factor or bandwidth re-colours the stored estimate (the received power does not change);
//   * a stats card per site (area, the bands, new area vs already covered today, people where census data exists, longest
//     predicted link) and one for the whole plan (area together, covered twice, what the planned sites add to the existing
//     nodes);
//   * "how many repeaters see this spot": long-press the map while Check a spot is on, or check the middle of the view;
//   * the link matrix of up to 10 nodes (plan_analysis.dart, each pair judged on the phone from its terrain profile), drawn
//     on the map by verdict, and the node classes (critical / backbone / redundant / marginal);
//   * the verify loop for an installed node: measured cells around it against what was predicted.
// The mode's results live with the plan controller ([_CoverageSession]), so switching modes and back keeps them.
//
// Keys: 'plan-mode-coverage', 'coverage-node-<id>', 'coverage-edit-node', 'coverage-mount-<ground|tree|building>',
// 'coverage-receiver-<handheld|mobile|rooftop>', 'coverage-receiver-height', 'coverage-run', 'coverage-run-all',
// 'coverage-error', 'coverage-result', 'coverage-area', 'coverage-stale', 'coverage-nolinks', 'coverage-layer',
// 'coverage-opacity', 'coverage-min-snr', 'coverage-colour-<signal|sites>', 'coverage-legend', 'coverage-restyled',
// 'coverage-union', 'coverage-spot-arm', 'coverage-spot-centre', 'coverage-spot-result', 'coverage-matrix-run',
// 'coverage-matrix', 'coverage-pair-<a>-<b>', 'coverage-classes', 'coverage-class-<id>', 'coverage-verify-loop'.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/plan/link_model.dart' show ftM, haversineKm, radioNoiseFloorDbm, snrFloorForSf;
import '../../../core/plan/plan_analysis.dart';
import '../../../core/plan/plan_api.dart';
import '../../../core/plan/plan_controller.dart';
import '../../../core/plan/plan_model.dart';
import '../../../core/plan_contract.dart';
import '../../../core/units.dart' show Units;
import '../../app.dart';
import '../../design/app_haptics.dart';
import '../../design/app_symbols.dart';
import '../../design/tokens.dart';
import '../../map/coverage_bands.dart' show CoverageBandColors;
import '../../map/layers/plan_overlay.dart' show PlanOverlayLink;
import '../../settings/settings_kit.dart' show SliderTile;
import '../../design/state_views.dart';
import '../plan_modes.dart';
import 'footprint_field.dart';
import 'footprint_layer.dart';

/// The most nodes "Estimate every node" runs (one coverage run each, one after the other).
const int coverageMaxSites = 10;

class CoverageMode extends PlanMode {
  const CoverageMode();
  @override
  PlanModeId get id => PlanModeId.coverage;
  @override
  String get label => 'Coverage';
  @override
  AppSymbol get symbol => AppSymbols.antenna;
  @override
  String get hint => 'What the nodes of the plan would cover, drawn on the map.';
  @override
  Widget buildSheet(PlanModeContext context) => CoverageBody(context, key: ValueKey('plan-mode-body-coverage-${context.intent?.seq}'));
}

// ------------------------------------------------------------------------------------------------ receiver

/// The receivers plan-verify draws a footprint for (website coverage.ts RECEIVERS) and their default heights.
enum CoverageReceiver {
  handheld('handheld', 'Handheld', 1.5),
  mobile('mobile', 'Car roof', 1.8),
  rooftop('rooftop', 'Rooftop', 6);

  final String wire, label;
  final double heightM;
  const CoverageReceiver(this.wire, this.label, this.heightM);

  /// The receiver a height stands for (the plan stores only the height).
  static CoverageReceiver of(double? m) => m == null || m < 1.7 ? handheld : (m < 3 ? mobile : rooftop);
}

/// Mount presets with the heights the candidate pool uses (plan_model.dart mountHeightM).
String mountWords(PlanMount m) => switch (m) {
      PlanMount.ground => 'Pole',
      PlanMount.tree => 'Treetop',
      PlanMount.building => 'Rooftop',
    };

// ------------------------------------------------------------------------------------------------ results kept per plan

/// The numbers of one coverage run (plan-verify or the coverage painter).
class CoverageNumbers {
  final double coveredKm2;
  final List<(String id, String label, double km2)> bands;
  final double? newAreaKm2, alreadyKm2;
  final int? newPeople;
  final List<(String key, String name, double km, double marginDb)> links;
  final String note, confidence;
  const CoverageNumbers({
    required this.coveredKm2,
    required this.bands,
    this.newAreaKm2,
    this.alreadyKm2,
    this.newPeople,
    required this.links,
    this.note = '',
    this.confidence = '',
  });

  static CoverageNumbers ofVerify(PlanVerifyResult r) {
    final already = r.raw['alreadyCoveredKm2'];
    return CoverageNumbers(
      coveredKm2: r.coveredKm2,
      bands: [for (final b in r.bands) (b.id, b.label, b.areaKm2)],
      newAreaKm2: r.newAreaKm2,
      alreadyKm2: already is num && already.isFinite ? already.toDouble() : null,
      newPeople: r.newPeople,
      links: [for (final l in r.links) (l.publicKey, l.name, l.km, l.marginDb)],
      note: r.provenance.terrain.isEmpty ? '' : 'Terrain: ${r.provenance.terrain}.',
      confidence: r.provenance.confidenceNote ?? '',
    );
  }

  static CoverageNumbers ofPainter(PainterResult r) => CoverageNumbers(
        coveredKm2: r.coveredKm2,
        bands: [for (final b in r.bands) (b.id, b.label, b.areaKm2)],
        newPeople: r.peopleNew,
        links: [for (final l in r.links) (l.publicKey, l.name, l.km, l.marginDb)],
        note: '${r.note} Terrain: ${r.terrainSource}.',
      );

  /// The farthest live repeater predicted to decode the site, km (null = none).
  double? get longestLinkKm {
    double? best;
    for (final l in links) {
      if (l.$4 >= 0 && (best == null || l.$3 > best)) best = l.$3;
    }
    return best;
  }
}

class _SiteRun {
  /// What the run was made for (position, heights, power, clutter, receiver, frequency): another key = stale.
  final String key;
  final PlanResult<CoverageNumbers> result;
  final SiteFootprint? footprint;

  /// The plan-verify answer itself (null for the coverage painter), for the verify loop.
  final PlanVerifyResult? verify;
  const _SiteRun(this.key, this.result, this.footprint, [this.verify]);
}

class _Spot {
  final PlanPoint at;
  final bool loading;

  /// (node name, words, reaches)
  final List<(String, String, bool)> rows;
  const _Spot(this.at, {this.loading = false, this.rows = const []});
}

/// Coverage results of one plan, kept as long as its controller (modes come and go).
class _CoverageSession {
  final Map<String, _SiteRun> runs = {};
  double opacity = 0.55;

  /// Null = follow the radio's decode limit.
  double? minSnrDb;
  FootprintColour colour = FootprintColour.signal;
  LinkMatrix? matrix;
  String? matrixKey;
  _Spot? spot;
  String? planId;
}

final Expando<_CoverageSession> _sessions = Expando('coverage');

_CoverageSession _sessionOf(PlanController c) {
  final s = _sessions[c] ??= _CoverageSession();
  if (s.planId != c.plan.id) {
    // Another plan was opened in the same controller: its results do not carry over.
    s.runs.clear();
    s.matrix = null;
    s.matrixKey = null;
    s.spot = null;
    s.planId = c.plan.id;
  }
  return s;
}

String _f5(double v) => v.toStringAsFixed(5);

/// What a coverage run of [n] depends on, apart from SF / bandwidth / CR (they only move the sensitivity).
String coverageRunKey(Plan p, PlanNode n) => [
      _f5(n.lat),
      _f5(n.lon),
      n.antennaM,
      n.effectiveTxDbm,
      n.effectiveGainDbi,
      n.mount?.wire,
      p.clutter.canopyM,
      p.clutter.dbPerKm,
      p.receiverM,
      p.radio.freqMHz,
    ].join('|');

/// The plan-verify request for [n] of [p].
PlanVerifyRequest coverageRequest(Plan p, PlanNode n) => PlanVerifyRequest(
      site: n.point,
      radio: p.radio,
      antennaM: n.antennaM.clamp(1.8, 61).toDouble(),
      txDbm: n.effectiveTxDbm,
      gainDbi: n.effectiveGainDbi,
      clutter: p.clutter,
      receiver: CoverageReceiver.of(p.receiverM).wire,
      receiverM: p.receiverM,
      mount: n.mount,
    );

String _matrixKeyOf(Plan p) => [
      p.radio.freqMHz,
      p.radio.bwKHz,
      p.radio.sf,
      p.clutter.canopyM,
      p.clutter.dbPerKm,
      for (final n in p.nodes.take(linkMatrixMaxNodes)) '${n.id}:${_f5(n.lat)},${_f5(n.lon)},${n.antennaM},${n.effectiveTxDbm},${n.effectiveGainDbi}',
    ].join('|');

String _snrWords(double db) => '${db >= 0 ? '+' : '-'}${db.abs().toStringAsFixed(1)} dB';

// ------------------------------------------------------------------------------------------------ the body

class CoverageBody extends StatefulWidget {
  final PlanModeContext ctx;
  const CoverageBody(this.ctx, {super.key});
  @override
  State<CoverageBody> createState() => CoverageBodyState();
}

class CoverageBodyState extends State<CoverageBody> {
  String? _node;
  final Set<String> _busy = {};
  (int done, int of)? _all;
  bool _matrixBusy = false;
  bool _spotArmed = false;
  PlanFootprintController? _layer;
  late _CoverageSession _session;
  Timer? _rerun;
  Set<String> _staleBefore = const {};

  // Memo of the union and its look, so a rebuild without a change costs nothing.
  String? _fieldSig;
  FootprintField? _field;
  List<SiteFootprint> _fieldSites = const [];
  String? _viewSig;
  FootprintView? _view;
  String? _drawnSig;

  PlanModeContext get ctx => widget.ctx;
  Plan get _plan => ctx.controller.plan;

  @visibleForTesting
  FootprintField? get fieldForTest => _field;
  @visibleForTesting
  FootprintView? get viewForTest => _view;

  @override
  void initState() {
    super.initState();
    _session = _sessionOf(ctx.controller);
    final i = ctx.intent;
    _node = i?.kind == PlanModeIntentKind.coverageOf ? i!.nodeId : (ctx.selectedNodeId ?? ctx.controller.nodes.firstOrNull?.id);
    ctx.hooks.onNodeTap = _onNodeTap;
    ctx.hooks.onMapPoint = _onMapPoint;
    ctx.plan.addListener(_onPlan);
    _staleBefore = _staleIds();
    ctx.setOverlay(PlanModeOverlay.empty);
    if (i?.kind == PlanModeIntentKind.coverageOf) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(estimate(i!.nodeId)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _layer = PlanFootprintScope.maybeOf(context);
  }

  @override
  void dispose() {
    _rerun?.cancel();
    ctx.plan.removeListener(_onPlan);
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    if (ctx.hooks.onMapPoint == _onMapPoint) ctx.hooks.onMapPoint = null;
    _layer?.clear();
    super.dispose();
  }

  // ---------------------------------------------------------------- plan and map events

  Set<String> _staleIds() => {
        for (final n in _plan.nodes)
          if (_session.runs[n.id] case final r? when r.key != coverageRunKey(_plan, n) && r.footprint != null) n.id,
      };

  void _onPlan() {
    if (!mounted) return;
    final p = _plan;
    setState(() {
      if (_node != null && p.node(_node!) == null) _node = p.nodes.firstOrNull?.id;
      _node ??= p.nodes.firstOrNull?.id;
      _session.runs.removeWhere((id, _) => p.node(id) == null);
    });
    // A node that was dragged or edited re-estimates itself after a pause (one or two at a time; a plan-wide change such as
    // the receiver height offers "Estimate again" instead of sending a request per node).
    final stale = _staleIds();
    final fresh = stale.difference(_staleBefore);
    _staleBefore = stale;
    if (fresh.isNotEmpty && fresh.length <= 2) {
      _rerun?.cancel();
      _rerun = Timer(const Duration(milliseconds: 1500), () {
        for (final id in fresh) {
          if (mounted && _staleIds().contains(id)) unawaited(estimate(id));
        }
      });
    }
  }

  bool _onNodeTap(String id) {
    if (_plan.node(id) == null) return false;
    setState(() => _node = id);
    ctx.selectNode(id);
    return true;
  }

  bool _onMapPoint(PlanPoint at) {
    if (!_spotArmed) return false;
    unawaited(checkSpot(at));
    return true;
  }

  // ---------------------------------------------------------------- running estimates

  PlanApi get _api => ctx.api;

  /// Estimates the coverage of node [id] (plan-verify, else the coverage painter).
  Future<void> estimate(String id) async {
    final p = _plan;
    final n = p.node(id);
    if (n == null || _busy.contains(id)) return;
    final key = coverageRunKey(p, n);
    final req = coverageRequest(p, n);
    setState(() => _busy.add(id));
    final s = AppScope.read(context);
    final v = await _api.verify(req);
    _SiteRun run;
    if (v.ok) {
      final d = v.data!;
      run = _SiteRun(key, PlanResult.ok(CoverageNumbers.ofVerify(d), at: v.at, offlineAsOf: v.offlineAsOf),
          SiteFootprint.fromVerify(id, d.raw, site: n.point, radio: p.radio), d);
    } else if (v.unavailable) {
      // The planner endpoint is not on this server yet: the website's coverage painter runs the same model.
      final pr = await CoveragePainterApi(s.planBaseUrl, s.planStore).paint(PainterParams(
        lat: n.lat,
        lon: n.lon,
        antennaFt: (req.antennaM / ftM).clamp(6, 200).toDouble(),
        txDbm: req.txDbm.clamp(0, 30).toDouble(),
        gainDbi: req.gainDbi.clamp(-3, 12).toDouble(),
        receiver: req.receiver == 'handheld' ? 'handheld' : 'repeater',
      ));
      run = pr.ok
          ? _SiteRun(
              key,
              PlanResult.ok(CoverageNumbers.ofPainter(pr.data!), at: pr.at, offlineAsOf: pr.offlineAsOf),
              SiteFootprint.ofBands(id, [for (final b in pr.data!.footprint) (b.id, b.rings)],
                  site: n.point, radio: p.radio, sensitivityDbm: pr.data!.sensitivityDbm),
            )
          : _SiteRun(key, PlanResult.fail(pr.error ?? v.error ?? 'No answer.'), null);
    } else {
      run = _SiteRun(key, PlanResult.fail(v.error ?? 'No answer.'), null);
    }
    if (!mounted) return;
    setState(() {
      _busy.remove(id);
      // A failure keeps the last good footprint on the map (marked stale) rather than wiping it.
      final old = _session.runs[id];
      _session.runs[id] = run.result.ok || old == null || !old.result.ok ? run : _SiteRun(old.key, run.result, null, old.verify);
      _staleBefore = _staleIds();
    });
    if (run.result.ok) unawaited(AppHaptics.success());
  }

  /// Estimates every node without a current estimate (at most [coverageMaxSites]), one after the other.
  Future<void> estimateAll() async {
    final todo = [for (final n in _plan.nodes.take(coverageMaxSites)) if (!_current(n)) n.id];
    if (todo.isEmpty) return;
    setState(() => _all = (0, todo.length));
    for (var i = 0; i < todo.length; i++) {
      if (!mounted) return;
      await estimate(todo[i]);
      if (mounted) setState(() => _all = (i + 1, todo.length));
    }
    if (mounted) setState(() => _all = null);
  }

  bool _current(PlanNode n) {
    final r = _session.runs[n.id];
    return r != null && r.result.ok && r.key == coverageRunKey(_plan, n);
  }

  // ---------------------------------------------------------------- the union

  double get _noise => radioNoiseFloorDbm(_plan.radio);
  double get _decodeSnr => snrFloorForSf(_plan.radio.sf);
  double get _minSnr => _session.minSnrDb ?? _decodeSnr;

  List<SiteFootprint> get _currentFootprints => [
        for (final n in _plan.nodes)
          if (_session.runs[n.id] case final r? when r.footprint != null && r.key == coverageRunKey(_plan, n)) r.footprint!,
      ];

  void _refreshUnion() {
    final sites = _currentFootprints;
    final sig = [for (final f in sites) '${f.nodeId}@${identityHashCode(f)}'].join(';');
    if (sig != _fieldSig) {
      _fieldSig = sig;
      _fieldSites = sites;
      _field = FootprintField.build(sites);
      _viewSig = null;
    }
    final f = _field;
    if (f == null) {
      _view = null;
      return;
    }
    final existing = {for (var i = 0; i < _fieldSites.length; i++) if (_plan.node(_fieldSites[i].nodeId)?.status == PlanNodeStatus.existing) i};
    final vs = '$sig|${_noise.toStringAsFixed(2)}|$_minSnr|${existing.join(',')}';
    if (vs != _viewSig) {
      _viewSig = vs;
      _view = f.classify(noiseDbm: _noise, minSnrDb: _minSnr, existing: existing);
    }
  }

  void _publishLayer(BuildContext context, Units units) {
    final layer = _layer;
    final f = _field, v = _view;
    if (layer == null) return;
    if (f == null || v == null) {
      _drawnSig = null;
      layer.clear();
      return;
    }
    final t = Theme.of(context);
    final palette = MeshSonarColors.of(context).palette;
    final sig = '$_viewSig|${_session.colour}|${_session.opacity}|${palette.id}|${t.brightness}|${_plan.radio.sf}';
    if (sig == _drawnSig) return;
    _drawnSig = sig;
    final colours = CoverageBandColors.of(palette, t.brightness);
    layer.show(
      footprintCells(f, v, mode: _session.colour, colours: colours, opacity: _session.opacity, sf: _plan.radio.sf),
      summary: 'Coverage estimate on the map: ${_fieldSites.length} ${_fieldSites.length == 1 ? 'site' : 'sites'}, ${areaWords(units, v.areaKm2)} at ${_snrWords(_minSnr)} SNR or better.',
    );
  }

  void _publishLinks() {
    final m = _session.matrix;
    if (m == null || _session.matrixKey != _matrixKeyOf(_plan)) {
      ctx.setOverlay(PlanModeOverlay.empty);
      return;
    }
    ctx.setOverlay(PlanModeOverlay(links: [
      for (final l in m.links)
        if (l.result != null) PlanOverlayLink(fromId: l.aId, toId: l.bId, verdict: overlayVerdict(l.verdict)),
    ]));
  }

  // ---------------------------------------------------------------- spot, matrix

  /// "How many repeaters see this spot": every repeater node of the plan, from its footprint when it has a current one,
  /// else judged on the phone over the terrain profile.
  Future<void> checkSpot(PlanPoint at) async {
    final p = _plan;
    final reps = [for (final n in p.nodes) if (n.role == PlanNodeRole.repeater) n].take(Plan.maxNodes).toList();
    setState(() => _session.spot = _Spot(at, loading: true));
    unawaited(AppHaptics.selection());
    final byFootprint = {for (final f in _currentFootprints) f.nodeId: f};
    final rows = <(String, String, bool)>[];
    final rx = PlanNode(id: '_spot', name: 'Spot', lat: at.lat, lon: at.lon, heightM: p.receiverM ?? CoverageReceiver.handheld.heightM, role: PlanNodeRole.handheld);
    for (final n in reps) {
      final f = byFootprint[n.id];
      if (f != null) {
        final v = f.dbmAt(at);
        if (v == null) {
          rows.add((n.name, 'outside its estimate', false));
        } else {
          final snr = v - _noise;
          rows.add((n.name, 'SNR ${_snrWords(snr)} (coverage estimate)', snr >= _minSnr));
        }
        continue;
      }
      if (haversineKm(n.lat, n.lon, at.lat, at.lon) < 0.01) {
        rows.add((n.name, 'at the spot', true));
        continue;
      }
      final pr = await _api.profile(n.point, at);
      if (!mounted) return;
      if (!pr.ok) {
        rows.add((n.name, 'no terrain: ${pr.error ?? 'no answer'}', false));
        continue;
      }
      final r = judgeLink(p, n, rx, pr.data!, direction: PlanDirection.down);
      final v = r.verdict;
      rows.add((n.name, '${v == null ? 'unknown' : verdictWords(v)} (terrain profile)', v == PlanVerdict.likely));
    }
    if (!mounted) return;
    rows.sort((a, b) => (b.$3 ? 1 : 0) - (a.$3 ? 1 : 0));
    setState(() => _session.spot = _Spot(at, rows: rows));
  }

  Future<void> runMatrix() async {
    setState(() => _matrixBusy = true);
    final key = _matrixKeyOf(_plan);
    final m = await ctx.controller.linkMatrix(_api.profile);
    if (!mounted) return;
    setState(() {
      _matrixBusy = false;
      _session.matrix = m;
      _session.matrixKey = key;
    });
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final nodes = ctx.controller.nodes;
    _refreshUnion();
    _publishLayer(context, units);
    _publishLinks();
    if (nodes.isEmpty) {
      return AppEmptyView(
        key: const Key('plan-mode-coverage'),
        symbol: AppSymbols.antenna,
        title: 'Add a node to estimate its coverage',
        message: 'Long-press the map where a repeater could go, or add one from the network.',
        actionLabel: 'Add from the network',
        onAction: ctx.openNodePicker,
      );
    }
    final p = _plan;
    final node = _node == null ? null : p.node(_node!);
    final run = node == null ? null : _session.runs[node.id];
    final current = node != null && run != null && run.key == coverageRunKey(p, node);
    final busy = node != null && _busy.contains(node.id);
    final missing = [for (final n in nodes.take(coverageMaxSites)) if (!_current(n)) n];
    return Column(key: const Key('plan-mode-coverage'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: DropdownButtonFormField<String>(
          key: Key('coverage-node-$_node'),
          initialValue: _node,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Site', border: OutlineInputBorder()),
          items: [for (final n in nodes) DropdownMenuItem(value: n.id, child: Text(n.name, overflow: TextOverflow.ellipsis))],
          onChanged: (v) {
            setState(() => _node = v);
            if (v != null) ctx.selectNode(v);
          },
        ),
      ),
      if (node != null) ..._siteSettings(context, node, units),
      const SizedBox(height: Gap.s),
      _button(
        key: const Key('coverage-run'),
        label: busy ? 'Estimating coverage…' : current ? 'Estimate again' : 'Estimate coverage',
        busy: busy,
        onPressed: node == null ? null : () => unawaited(estimate(node.id)),
      ),
      if (nodes.length > 1 && missing.isNotEmpty) ...[
        const SizedBox(height: Gap.xs),
        OutlinedButton.icon(
          key: const Key('coverage-run-all'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
          onPressed: _all != null ? null : () => unawaited(estimateAll()),
          icon: const AppSymbolIcon(AppSymbols.layers, size: 18),
          label: Text(_all != null
              ? 'Estimating ${math.min(_all!.$1 + 1, _all!.$2)} of ${_all!.$2}…'
              : 'Estimate ${missing.length == nodes.length ? 'every node' : 'the other ${missing.length} ${missing.length == 1 ? 'node' : 'nodes'}'}${nodes.length > coverageMaxSites ? ' (first $coverageMaxSites)' : ''}'),
        ),
      ],
      if (busy) const PlanLine(AppSymbols.clock, 'The model reads terrain tiles and sweeps the area; the first run for a place can take up to a minute.'),
      const SizedBox(height: Gap.s),
      if (run != null && !run.result.ok && current)
        AppErrorView(key: const Key('coverage-error'), title: 'Could not estimate coverage', message: run.result.error, onRetry: () => unawaited(estimate(node.id))),
      if (run != null && run.result.ok && node != null) _siteCard(context, node, run, current, units, t),
      if (_field != null && _view != null) ...[
        const Divider(),
        ..._layerControls(context, units, t),
        _unionCard(context, units, t),
      ],
      const Divider(),
      ..._spotSection(context, units, t),
      const Divider(),
      ..._matrixSection(context, units, t),
    ]);
  }

  Widget _button({required Key key, required String label, required VoidCallback? onPressed, bool busy = false}) => FilledButton.icon(
        key: key,
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 8)),
        onPressed: busy ? null : onPressed,
        icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const AppSymbolIcon(AppSymbols.antenna, size: 18),
        label: Text(label),
      );

  List<Widget> _siteSettings(BuildContext context, PlanNode node, Units units) {
    final t = Theme.of(context);
    final p = _plan;
    final rx = CoverageReceiver.of(p.receiverM);
    final rxM = p.receiverM ?? rx.heightM;
    return [
      PlanFact('Antenna', '${units.height(node.antennaM)} above ground, ${node.effectiveTxDbm.round()} dBm, ${node.effectiveGainDbi.toStringAsFixed(1)} dBi'),
      Semantics(header: true, child: Text('Mount', style: t.textTheme.titleSmall)),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        for (final m in PlanMount.values)
          ChoiceChip(
            key: Key('coverage-mount-${m.wire}'),
            label: Text('${mountWords(m)} ${units.height(mountHeightM(m))}'),
            selected: node.mount == m && node.heightM == null,
            onSelected: (_) {
              unawaited(AppHaptics.selection());
              ctx.controller.updateNode(node.id, (x) => x.copyWith(mount: m, clearHeight: true));
            },
          ),
      ]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('coverage-edit-node'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: () => ctx.editNode(node.id),
          icon: const AppSymbolIcon(AppSymbols.squareAndPencil, size: 18),
          label: const Text('Change height and power'),
        ),
      ),
      Semantics(header: true, child: Text('Received by', style: t.textTheme.titleSmall)),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        for (final r in CoverageReceiver.values)
          ChoiceChip(
            key: Key('coverage-receiver-${r.wire}'),
            label: Text('${r.label} ${units.height(r.heightM)}'),
            selected: ((p.receiverM ?? CoverageReceiver.handheld.heightM) - r.heightM).abs() < 0.05,
            onSelected: (_) => ctx.controller.setReceiverM(r == CoverageReceiver.handheld ? null : r.heightM),
          ),
      ]),
      SliderTile(
        key: const ValueKey('coverage-receiver-height'),
        sliderKey: const Key('coverage-receiver-height-slider'),
        icon: symbolData(context, AppSymbols.person),
        title: 'Receiver height',
        caption: '${rx.label} antenna above the ground. Changing it needs a new estimate.',
        stops: const [5, 10, 15, 18, 20, 30, 40, 60, 80, 100, 150, 200, 300],
        value: (rxM * 10).round(),
        label: (v) => units.height(v / 10),
        onChanged: (v) => ctx.controller.setReceiverM(v == 15 ? null : v / 10),
      ),
    ];
  }

  Widget _siteCard(BuildContext context, PlanNode node, _SiteRun run, bool current, Units units, ThemeData t) {
    final d = run.result.data!;
    final bandWords = {'below': 'No decode', 'fringe': 'Fringe (0 to 6 dB margin)', 'usable': 'Usable (6 to 12 dB)', 'solid': 'Solid (over 12 dB)'};
    final heard = d.links.where((l) => l.$4 >= 0).toList()..sort((a, b) => b.$4.compareTo(a.$4));
    final idx = _fieldSites.indexWhere((f) => f.nodeId == node.id);
    final atMin = idx >= 0 && _view != null ? _view!.siteKm2[idx] : null;
    final fp = run.footprint;
    final restyled = fp != null && current && (fp.radio.sf != _plan.radio.sf || fp.radio.bwKHz != _plan.radio.bwKHz);
    final longest = d.longestLinkKm;
    final cells = _measuredCells(context);
    final calib = cells == null ? null : calibrationConfidence(node.point, [for (final c in cells) c.at]);
    return Semantics(
      container: true,
      child: Column(key: const Key('coverage-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!current) const PlanLine(AppSymbols.clock, 'The site or settings changed: this is the last result. Estimate again to update it.', key: Key('coverage-stale')),
        Semantics(header: true, child: Text('${node.name} (Estimate)', style: t.textTheme.titleSmall)),
        Semantics(
          label: 'Covered area, Estimate: ${areaWords(units, d.coveredKm2)}',
          excludeSemantics: true,
          child: Text(areaWords(units, d.coveredKm2), key: const Key('coverage-area'), style: numberStyle(context, size: 30)),
        ),
        Text('Estimate: area where a ${CoverageReceiver.of(_plan.receiverM).label.toLowerCase()} radio can decode this site', style: t.textTheme.bodySmall),
        const SizedBox(height: Gap.s),
        for (final b in d.bands)
          if (b.$1 != 'below') PlanFact(bandWords[b.$1] ?? b.$2, areaWords(units, b.$3)),
        if (atMin != null && current && (_session.minSnrDb != null || restyled))
          PlanFact('At ${_snrWords(_minSnr)} SNR or better', areaWords(units, atMin)),
        if (d.newAreaKm2 != null) PlanFact('New area not covered today', areaWords(units, d.newAreaKm2!)),
        if (d.alreadyKm2 != null) PlanFact('Already covered today', areaWords(units, d.alreadyKm2!)),
        if (d.newPeople != null)
          PlanFact('People not covered by a live repeater today', '${d.newPeople}')
        else
          const PlanLine(AppSymbols.person2, 'People: no census counts for this area, so none are shown.'),
        PlanFact('Longest predicted link', longest == null ? 'none' : units.distance(longest * 1000)),
        const SizedBox(height: Gap.s),
        if (heard.isEmpty)
          const PlanLine(AppSymbols.antenna, 'No live repeater is predicted to hear this site.', key: Key('coverage-nolinks'))
        else ...[
          Semantics(header: true, child: Text('Predicted links to live repeaters', style: t.textTheme.titleSmall)),
          for (final l in heard.take(8)) PlanFact('${l.$2} · ${units.distance(l.$3 * 1000)}', dbWords(l.$4, signed: true)),
        ],
        if (restyled)
          PlanLine(AppSymbols.waveform,
              'Re-coloured for SF${_plan.radio.sf}, ${_plan.radio.bwKHz} kHz from the stored estimate (made for SF${fp.radio.sf}, ${fp.radio.bwKHz} kHz): the received power does not change, only what the radio can decode. The areas above are for SF${fp.radio.sf}.',
              key: const Key('coverage-restyled')),
        if (fp == null) const PlanLine(AppSymbols.map, 'This answer had no footprint to draw: numbers only.')
        else if (fp.fromBands) const PlanLine(AppSymbols.map, 'Drawn from the signal bands (the server did not send the fine grid): each band at its middle value.'),
        if (calib != null) PlanLine(AppSymbols.chartBar, 'Our drives near it: ${calib.text}.'),
        if (d.confidence.isNotEmpty) PlanLine(AppSymbols.infoCircle, 'Confidence: ${d.confidence}.'),
        ...resultNotes(context, run.result),
        if (d.note.isNotEmpty) Text('Estimate, not a measurement. ${d.note}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ..._verifyLoop(context, node, run, current, units, t, cells),
      ]),
    );
  }

  /// Measured network cells (all drives and observers of the region), or null when none are loaded.
  List<PlanMeasuredCell>? _measuredCells(BuildContext context) {
    final cov = AppScope.of(context).networkCoverage;
    if (cov == null) return null;
    return [
      for (final c in cov.cells)
        if (c.lat.isFinite && c.lon.isFinite) PlanMeasuredCell(PlanPoint(c.lat, c.lon), heard: c.heard > 0 || (c.nOk ?? 0) > 0, snr: c.snrMean ?? c.medianSnr),
    ];
  }

  /// Improvement 20 (display): an installed node's estimate against the drives around it.
  List<Widget> _verifyLoop(BuildContext context, PlanNode node, _SiteRun run, bool current, Units units, ThemeData t, List<PlanMeasuredCell>? cells) {
    final head = Semantics(header: true, child: Text('Did it work?', style: t.textTheme.titleSmall));
    if (node.status == PlanNodeStatus.planned) {
      return [
        const SizedBox(height: Gap.s),
        head,
        PlanLine(AppSymbols.checkmarkCircleFill, 'Once ${node.name} is up, mark it Installed (Edit) and drive around it: this card then compares the estimate with what was measured.',
            key: const Key('coverage-verify-loop')),
      ];
    }
    final fp = run.footprint;
    if (fp == null || !current) return const [];
    final words = <Widget>[];
    if (cells == null || cells.isEmpty) {
      words.add(PlanLine(AppSymbols.car, 'No measured drives near ${node.name} yet. Drive around it, then this compares the estimate with what was heard.'));
      words.add(Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          key: const Key('coverage-verify-drive'),
          style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: () => ctx.switchMode(PlanModeId.whereToDrive),
          icon: const AppSymbolIcon(AppSymbols.car, size: 18),
          label: const Text('Where to drive'),
        ),
      ));
    } else {
      // The stored received power against the plan's radio now (the same numbers the layer draws).
      final sens = _noise + _decodeSnr;
      final v = compareVerifyWithMeasured(
        run.verify ?? PlanVerifyResult(coveredKm2: run.result.data!.coveredKm2),
        cells,
        site: node.point,
        marginAt: (at) {
          final d = fp.dbmAt(at);
          return d == null ? null : d - sens;
        },
        snrFloorDb: _decodeSnr,
      );
      if (!v.enough) {
        words.add(PlanLine(AppSymbols.car,
            v.compared == 0
                ? 'Not enough data yet: no measured cells inside the estimate around ${node.name}. Drive around it to check the estimate.'
                : 'Not enough data yet: ${v.compared} measured ${v.compared == 1 ? 'cell' : 'cells'} inside the estimate, at least ${v.minCells} are needed to compare. Drive around it.',
            key: const Key('coverage-verify-thin')));
      } else {
        words.add(PlanFact('Measured cells compared', '${v.compared}'));
        words.add(PlanFact('Estimate and drives agree', '${v.agreePct.toStringAsFixed(0)} %'));
        words.add(PlanFact('Predicted covered and heard', '${v.coveredHeard}'));
        if (v.coveredSilent > 0) words.add(PlanLine(AppSymbols.exclamationTriangle, 'Predicted to decode, but nothing was heard: ${v.coveredSilent} ${v.coveredSilent == 1 ? 'cell' : 'cells'}.'));
        if (v.heardOutside > 0) words.add(PlanLine(AppSymbols.waveform, 'Heard outside the prediction: ${v.heardOutside} ${v.heardOutside == 1 ? 'cell' : 'cells'}.'));
        if (v.biasDb != null) {
          words.add(PlanFact('Mean SNR measured / predicted', '${_snrWords(v.measuredSnr!)} / ${_snrWords(v.predictedSnr!)}'));
          words.add(PlanLine(AppSymbols.gauge,
              v.biasDb!.abs() < 3 ? 'The estimate matches the drives within 3 dB.' : 'The estimate is ${v.biasDb!.abs().toStringAsFixed(1)} dB ${v.biasDb! > 0 ? 'more hopeful' : 'more cautious'} than the drives.'));
        }
        words.add(Text('Measured: every drive and observer of the region in those cells (Measured), not only this node.', style: t.textTheme.bodySmall));
      }
    }
    return [const SizedBox(height: Gap.s), head, Column(key: const Key('coverage-verify-loop'), crossAxisAlignment: CrossAxisAlignment.stretch, children: words)];
  }

  List<Widget> _layerControls(BuildContext context, Units units, ThemeData t) {
    final colours = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness);
    final decode = _decodeSnr;
    return [
      Semantics(header: true, child: Text('Coverage layer', key: const Key('coverage-layer'), style: t.textTheme.titleSmall)),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        for (final (m, words) in const [(FootprintColour.signal, 'By signal'), (FootprintColour.sites, 'Sites that reach it')])
          ChoiceChip(
            key: Key('coverage-colour-${m.name}'),
            label: Text(words),
            selected: _session.colour == m,
            onSelected: (_) => setState(() => _session.colour = m),
          ),
      ]),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: Wrap(key: const Key('coverage-legend'), spacing: Gap.m, runSpacing: Gap.xs, children: [
          for (final b in footprintLegendBands(_session.colour))
            MergeSemantics(
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 14, height: 14, decoration: BoxDecoration(color: colours[b], borderRadius: BorderRadius.circular(3))),
                const SizedBox(width: Gap.xs),
                Text(footprintBandWords(_session.colour, b), style: t.textTheme.bodySmall),
              ]),
            ),
        ]),
      ),
      SliderTile(
        key: const ValueKey('coverage-opacity'),
        sliderKey: const Key('coverage-opacity-slider'),
        icon: symbolData(context, AppSymbols.layers),
        title: 'Layer opacity',
        stops: const [20, 30, 40, 50, 55, 60, 70, 80, 90],
        value: (_session.opacity * 100).round(),
        label: (v) => '$v %',
        onChanged: (v) => setState(() => _session.opacity = v / 100),
      ),
      SliderTile(
        key: const ValueKey('coverage-min-snr'),
        sliderKey: const Key('coverage-min-snr-slider'),
        icon: symbolData(context, AppSymbols.waveform),
        title: 'Minimum SNR',
        caption: 'SF${_plan.radio.sf} decodes down to ${_snrWords(decode)}. Raise it to see only where the signal has room to spare. Re-draws at once, no new request.',
        stops: const [-200, -175, -150, -125, -100, -75, -50, -25, 0, 25, 50, 75, 100, 125, 150],
        value: (_minSnr * 10).round(),
        label: (v) => _snrWords(v / 10),
        minLabel: 'Weaker',
        maxLabel: 'Stronger',
        onChanged: (v) => setState(() => _session.minSnrDb = (v / 10 - decode).abs() < 0.01 ? null : v / 10),
      ),
    ];
  }

  Widget _unionCard(BuildContext context, Units units, ThemeData t) {
    final v = _view!;
    final n = _fieldSites.length;
    final hasExisting = _fieldSites.any((f) => _plan.node(f.nodeId)?.status == PlanNodeStatus.existing);
    final hasNew = _fieldSites.any((f) => _plan.node(f.nodeId)?.status != PlanNodeStatus.existing);
    final noEstimate = _plan.nodes.length - n;
    return Semantics(
      container: true,
      child: Column(key: const Key('coverage-union'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SizedBox(height: Gap.s),
        Semantics(header: true, child: Text(n == 1 ? 'On the map (Estimate)' : 'All $n sites together (Estimate)', style: t.textTheme.titleSmall)),
        PlanFact('Area at ${_snrWords(_minSnr)} SNR or better', areaWords(units, v.areaKm2)),
        if (n > 1) PlanFact('Reached by two or more sites', areaWords(units, v.overlapKm2)),
        if (hasExisting && hasNew) ...[
          PlanFact('Covered by the existing nodes', areaWords(units, v.existingKm2)),
          PlanFact('Added by the planned and installed sites', areaWords(units, v.addedKm2)),
        ],
        if (noEstimate > 0) PlanLine(AppSymbols.infoCircle, '$noEstimate ${noEstimate == 1 ? 'node has' : 'nodes have'} no current estimate and ${noEstimate == 1 ? 'is' : 'are'} not in this layer.'),
      ]),
    );
  }

  List<Widget> _spotSection(BuildContext context, Units units, ThemeData t) {
    final spot = _session.spot;
    final reach = spot?.rows.where((r) => r.$3).length ?? 0;
    return [
      Semantics(header: true, child: Text('How many repeaters see a spot', style: t.textTheme.titleSmall)),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        FilterChip(
          key: const Key('coverage-spot-arm'),
          avatar: const AppSymbolIcon(AppSymbols.pin, size: 16),
          label: Text(_spotArmed ? 'Long-press the map to check' : 'Check a spot'),
          selected: _spotArmed,
          onSelected: (on) => setState(() => _spotArmed = on),
        ),
        OutlinedButton(
          key: const Key('coverage-spot-centre'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
          onPressed: () {
            final b = ctx.visibleBounds();
            if (b == null) return;
            unawaited(checkSpot(PlanPoint((b.south + b.north) / 2, (b.west + b.east) / 2)));
          },
          child: const Text('Check the middle of the map'),
        ),
      ]),
      if (_spotArmed) const PlanLine(AppSymbols.infoCircle, 'While this is on, a long-press checks the spot instead of dropping a node.'),
      if (spot != null)
        Semantics(
          liveRegion: true,
          container: true,
          child: Column(key: const Key('coverage-spot-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (spot.loading)
              const PlanLine(AppSymbols.clock, 'Checking the spot against every repeater of the plan…')
            else if (spot.rows.isEmpty)
              const PlanLine(AppSymbols.antenna, 'The plan has no repeater node to check against.')
            else ...[
              PlanLine(reach == 0 ? AppSymbols.xmarkCircleFill : AppSymbols.checkmarkCircleFill,
                  '$reach of ${spot.rows.length} ${spot.rows.length == 1 ? 'repeater reaches' : 'repeaters reach'} this spot (Estimate, ${_snrWords(_minSnr)} SNR or better).',
                  style: t.textTheme.titleMedium),
              for (final r in spot.rows) PlanFact(r.$1, '${r.$3 ? 'Reaches' : 'Does not reach'} · ${r.$2}'),
            ],
          ]),
        ),
    ];
  }

  List<Widget> _matrixSection(BuildContext context, Units units, ThemeData t) {
    final p = _plan;
    final m = _session.matrix;
    final fresh = m != null && _session.matrixKey == _matrixKeyOf(p);
    final k = math.min(p.nodes.length, linkMatrixMaxNodes);
    final pairs = k * (k - 1) ~/ 2;
    final names = {for (final n in p.nodes) n.id: n.name};
    final out = <Widget>[
      Semantics(header: true, child: Text('Every link in the plan', style: t.textTheme.titleSmall)),
    ];
    if (p.nodes.length < 2) {
      out.add(const PlanLine(AppSymbols.route, 'Add a second node to see how the nodes link to each other.'));
      return out;
    }
    out.add(OutlinedButton.icon(
      key: const Key('coverage-matrix-run'),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 4)),
      onPressed: _matrixBusy ? null : () => unawaited(runMatrix()),
      icon: _matrixBusy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const AppSymbolIcon(AppSymbols.route, size: 18),
      label: Text(_matrixBusy ? 'Reading the terrain of $pairs ${pairs == 1 ? 'pair' : 'pairs'}…' : fresh ? 'Check every link again' : 'Check every link ($pairs ${pairs == 1 ? 'pair' : 'pairs'})'),
    ));
    if (p.nodes.length > linkMatrixMaxNodes) out.add(PlanLine(AppSymbols.infoCircle, 'Links are checked between the first $linkMatrixMaxNodes nodes of the plan.'));
    if (m == null) return out;
    if (!fresh) out.add(const PlanLine(AppSymbols.clock, 'The nodes or settings changed: these are the last results. Check again to update them.'));
    final links = m.links.toList()
      ..sort((a, b) {
        final ra = a.verdict == null ? -1 : 2 - PlanVerdict.values.indexOf(a.verdict!), rb = b.verdict == null ? -1 : 2 - PlanVerdict.values.indexOf(b.verdict!);
        return rb.compareTo(ra);
      });
    out.add(Column(key: const Key('coverage-matrix'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final l in links) _pairTile(context, l, names, units, t),
    ]));
    if (fresh) {
      final classes = ctx.controller.nodeClasses(matrix: m);
      out.add(const SizedBox(height: Gap.s));
      out.add(Semantics(header: true, child: Text('What each node does for the mesh', style: t.textTheme.titleSmall)));
      out.add(Column(key: const Key('coverage-classes'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final id in m.nodeIds)
          if (classes[id] case final c?)
            PlanLine(
              switch (c.cls) {
                PlanNodeClass.critical => AppSymbols.exclamationTriangle,
                PlanNodeClass.backbone => AppSymbols.starFill,
                PlanNodeClass.redundant => AppSymbols.checkmarkCircleFill,
                PlanNodeClass.marginal => AppSymbols.exclamationCircle,
              },
              '${names[id] ?? id}: ${c.cls.label}. ${c.reason}.',
              key: Key('coverage-class-$id'),
            ),
      ]));
    }
    return out;
  }

  Widget _pairTile(BuildContext context, PlanPairLink l, Map<String, String> names, Units units, ThemeData t) {
    final r = l.result;
    final title = '${names[l.aId] ?? l.aId} and ${names[l.bId] ?? l.bId}';
    if (r == null) {
      return PlanLine(AppSymbols.exclamationCircle, '$title: no terrain (${l.error ?? 'no answer'}).', key: Key('coverage-pair-${l.aId}-${l.bId}'));
    }
    final v = r.verdict;
    return ExpansionTile(
      key: Key('coverage-pair-${l.aId}-${l.bId}'),
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(left: Gap.l, bottom: Gap.s),
      leading: AppSymbolIcon(v == null ? AppSymbols.route : verdictSymbol(v), color: v == PlanVerdict.likely ? t.colorScheme.primary : t.colorScheme.onSurfaceVariant),
      title: Text(title),
      subtitle: Text('${v == null ? 'Unknown' : verdictWords(v)} (Estimate) · ${units.distance(r.km * 1000)}${r.marginDb == null ? '' : ' · ${dbWords(r.marginDb!, signed: true)}'}'),
      children: [
        if (r.fresnelClearancePct != null) PlanFact('Fresnel zone open at the tightest point', '${r.fresnelClearancePct!.toStringAsFixed(0)} %'),
        if (r.odds != null) PlanFact('Terrain odds (Estimate)', '${(r.odds! * 100).clamp(0, 100).toStringAsFixed(0)} %'),
        if (r.tightest != null && r.tightest!.raiseM > 0)
          PlanLine(AppSymbols.arrowUpCircleFill, 'Raise ${names[l.aId] ?? 'the first end'} by ${units.height(r.tightest!.raiseM)} to clear 60 % of the Fresnel zone.'),
        if (r.ridge != null) PlanLine(AppSymbols.flag, 'Blocking ridge ${units.distance(r.ridge!.km * 1000)} from ${names[l.aId] ?? 'the first end'}.'),
        if (l.offlineAsOf != null) const PlanLine(AppSymbols.wifi, 'Offline: from the saved terrain profile.'),
        Text('Worked out on this phone from the terrain profile with the plan\'s radio and clutter.', style: t.textTheme.bodySmall),
      ],
    );
  }
}
