// The Planner's modes (release 0.38, plan §4.1: chips **Link · Coverage · Find sites · Where to drive**). Every mode acts on
// the one Plan the planner holds (lib/core/plan/plan_controller.dart) and is described by a [PlanMode]: its chip label and
// symbol, and [PlanMode.buildSheet], the content of the planner's bottom sheet while the mode is picked. A mode draws on
// the planner's map through [PlanModeContext.setOverlay] (planned links coloured by their Estimate, targets such as Find
// sites results) and can take map gestures through [PlanModeContext.hooks] (a long-press point, a tap on a plan node or a
// target).
//
// Registration: [planModes] below, one entry per chip, in chip order. The Link, Coverage and Find sites modes registered
// here are this file's own compact bodies (pick ends from the plan / one site / the view, run the planner API, show the
// verdict, footprint numbers or ranked sites); the full modes (ui/plan/modes/link_mode.dart, coverage_mode.dart,
// find_sites_mode.dart + wizard.dart) replace their registration line when they land. Where to drive hosts the existing
// DriveNextCard (ui/shell/drive_next_card.dart, unchanged logic) and opens the Drive map with the targets.
//
// Keys: 'plan-mode-<id>' (the body), 'link-a' / 'link-b' (end pickers), 'link-run', 'link-result', 'link-verdict',
// 'coverage-run', 'coverage-result', 'coverage-area', 'sites-goal-<goal>', 'sites-run', 'sites-result', 'site-<id>',
// 'site-add-<id>', 'drive-next-show-map'.
import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../core/drive_next.dart' show driveNextTargets, DriveTarget;
import '../../core/heard.dart' show bearingDeg, compass;
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/plan/link_model.dart' show ftM, haversineKm;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_controller.dart';
import '../../core/plan/plan_model.dart';
import '../../core/plan_contract.dart';
import '../../core/units.dart' show Units;
import '../app.dart';
import '../design/app_haptics.dart';
import '../design/app_surfaces.dart';
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../map/layers/plan_overlay.dart' show PlanLinkVerdict, PlanOverlayLink;
import '../map/layers/registry.dart' show kPlanLayerId;
import '../map/main_map_focus.dart';
import '../shell/drive_next_card.dart';

// ------------------------------------------------------------------------------------------------ the mode interface

enum PlanModeId { link, coverage, findSites, whereToDrive }

/// One chip of the planner. Implementations are stateless descriptors; their sheet content is an ordinary widget that
/// keeps its own state and is rebuilt (fresh state) when the plan's intent changes ([PlanModeContext.intent]).
abstract class PlanMode {
  const PlanMode();
  PlanModeId get id;

  /// The chip's words (vocabulary table, plan §4.5 item 6).
  String get label;
  AppSymbol get symbol;

  /// What the mode does, for VoiceOver on the chip.
  String get hint;

  /// Does this mode need nodes in the plan before it can show anything? (The planner shows its quick starts above the
  /// body of a mode that does while the plan is empty.)
  bool get needsNodes => true;

  /// The sheet content while this mode is picked.
  Widget buildSheet(PlanModeContext context);
}

/// What a mode draws on the planner's map on top of the plan's nodes (layers/plan_overlay.dart vocabulary).
@immutable
class PlanModeOverlay {
  final List<PlanOverlayLink> links;
  final List<MapFocusTarget> targets;
  const PlanModeOverlay({this.links = const [], this.targets = const []});
  static const PlanModeOverlay empty = PlanModeOverlay();

  @override
  bool operator ==(Object other) => other is PlanModeOverlay && listEquals(other.links, links) && listEquals(other.targets, targets);
  @override
  int get hashCode => Object.hash(Object.hashAll(links), Object.hashAll(targets));
}

/// Map gestures a mode may take before the planner's own handling. Each returns true when it consumed the gesture.
class PlanModeHooks {
  /// A long-press on bare map (the planner's default drops a planned node there).
  bool Function(PlanPoint at)? onMapPoint;

  /// A tap on a plan node or a target the mode drew (the planner's default selects the node).
  bool Function(String id)? onNodeTap;

  void clear() {
    onMapPoint = null;
    onNodeTap = null;
  }
}

enum PlanModeIntentKind {
  /// Link mode: [PlanModeIntent.nodeId] is end A; the person picks end B.
  linkFrom,

  /// Link mode: check the link between [PlanModeIntent.nodeId] and [PlanModeIntent.otherId].
  linkPair,

  /// Coverage mode: estimate the coverage of [PlanModeIntent.nodeId] now.
  coverageOf,
}

/// Something the planner asks a mode to do when it opens (a Plan request, a quick start).
@immutable
class PlanModeIntent {
  final PlanModeIntentKind kind;
  final String nodeId;
  final String? otherId;

  /// Changes with every intent, so the same intent twice still restarts the mode body.
  final int seq;
  const PlanModeIntent(this.kind, this.nodeId, {this.otherId, required this.seq});
}

/// A Flutter [Listenable] over the pure-Dart [PlanController] (it has the same addListener / removeListener shape).
class PlanListenable implements Listenable {
  final PlanController controller;
  const PlanListenable(this.controller);
  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) => controller.removeListener(listener);
}

/// Everything a mode's sheet content gets from the planner.
class PlanModeContext {
  final PlanController controller;

  /// Fires on every change of the plan.
  final Listenable plan;
  final PlanApi api;
  final String? selectedNodeId;
  final ValueChanged<String?> selectNode;
  final ValueChanged<PlanModeOverlay> setOverlay;

  /// Moves the planner's map to [at] (kept clear of the sheet).
  final void Function(PlanPoint at, {double? zoom}) focusMap;

  /// The part of the world above the sheet, or null before the map has laid out.
  final PlanBounds? Function() visibleBounds;
  final PlanModeHooks hooks;
  final PlanModeIntent? intent;
  final ValueChanged<PlanModeId> switchMode;

  /// Opens the existing-node picker (repeaters from the network, the person's radios).
  final VoidCallback openNodePicker;

  /// Opens the node editor for [nodeId].
  final ValueChanged<String> editNode;
  const PlanModeContext({
    required this.controller,
    required this.plan,
    required this.api,
    required this.selectedNodeId,
    required this.selectNode,
    required this.setOverlay,
    required this.focusMap,
    required this.visibleBounds,
    required this.hooks,
    required this.intent,
    required this.switchMode,
    required this.openNodePicker,
    required this.editNode,
  });
}

// ------------------------------------------------------------------------------------------------ registration

/// The planner's chips, in order. A full mode replaces its line here when it lands (A8 link, A9 coverage, A10 find sites).
final List<PlanMode> planModes = [
  const _LinkMode(),
  const _CoverageMode(),
  const _FindSitesMode(),
  const WhereToDriveMode(),
];

PlanMode planModeOf(PlanModeId id) => planModes.firstWhere((m) => m.id == id);

// ------------------------------------------------------------------------------------------------ shared helpers

/// The glyph an [AppSymbol] uses on this platform, for the kit rows that take an IconData (settings_kit InfoTile/SliderTile).
IconData symbolData(BuildContext context, AppSymbol s) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS ? s.apple : s.material;
}

/// "Estimate" words for a verdict (three states with the fade margin, plan §4.3 item 2).
String verdictWords(PlanVerdict v) => switch (v) {
      PlanVerdict.likely => 'Works',
      PlanVerdict.marginal => 'Marginal',
      PlanVerdict.unlikely => "Won't work",
    };

AppSymbol verdictSymbol(PlanVerdict v) => switch (v) {
      PlanVerdict.likely => AppSymbols.checkmarkCircleFill,
      PlanVerdict.marginal => AppSymbols.exclamationTriangle,
      PlanVerdict.unlikely => AppSymbols.xmarkCircleFill,
    };

PlanLinkVerdict overlayVerdict(PlanVerdict? v) => switch (v) {
      PlanVerdict.likely => PlanLinkVerdict.likely,
      PlanVerdict.marginal => PlanLinkVerdict.marginal,
      PlanVerdict.unlikely => PlanLinkVerdict.unlikely,
      null => PlanLinkVerdict.unknown,
    };

String areaWords(Units units, double km2) => units.distanceImperial ? '${(km2 * 0.386102).toStringAsFixed(1)} sq mi' : '${km2.toStringAsFixed(1)} km²';

String dbWords(double v, {bool signed = false}) => '${signed && v > 0 ? '+' : v < 0 ? '-' : ''}${v.abs().toStringAsFixed(1)} dB';

String _when(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
}

/// One line with a symbol and text (every state has an icon AND words, plan §4.5 item 8).
class PlanLine extends StatelessWidget {
  final AppSymbol symbol;
  final String text;
  final Color? color;
  final TextStyle? style;
  const PlanLine(this.symbol, this.text, {super.key, this.color, this.style});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: MergeSemantics(
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: AppSymbolIcon(symbol, size: 18, color: color ?? t.colorScheme.onSurfaceVariant)),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(text, style: style ?? t.textTheme.bodyMedium)),
        ]),
      ),
    );
  }
}

/// A label and its value on one line (the value moves under the label with large text).
class PlanFact extends StatelessWidget {
  final String label, value;
  const PlanFact(this.label, this.value, {super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Wrap(alignment: WrapAlignment.spaceBetween, spacing: Gap.m, children: [
          Text(label, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          Text(value, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

/// The "offline, saved result" / "worked out on the phone" notes under a result.
List<Widget> resultNotes<T>(BuildContext context, PlanResult<T> r) => [
      if (r.offlineAsOf != null) PlanLine(AppSymbols.wifi, 'Offline: this is the saved result from ${_when(r.offlineAsOf!)}.', key: const Key('plan-offline-note')),
      if (r.onDevice) const PlanLine(AppSymbols.antenna, 'Worked out on this phone from the terrain profile (the planner server did not answer).', key: Key('plan-ondevice-note')),
    ];

Widget _primary(BuildContext context, {required Key key, required String label, required AppSymbol symbol, required VoidCallback? onPressed, bool busy = false}) =>
    FilledButton.icon(
      key: key,
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(Hit.min + 8)),
      onPressed: busy ? null : onPressed,
      icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : AppSymbolIcon(symbol, size: 18),
      label: Text(label),
    );

// ------------------------------------------------------------------------------------------------ Link (compact)

class _LinkMode extends PlanMode {
  const _LinkMode();
  @override
  PlanModeId get id => PlanModeId.link;
  @override
  String get label => 'Link';
  @override
  AppSymbol get symbol => AppSymbols.route;
  @override
  String get hint => 'Will one node hear another: pick two nodes of the plan.';
  @override
  Widget buildSheet(PlanModeContext context) => _LinkBody(context, key: ValueKey('plan-mode-body-link-${context.intent?.seq}'));
}

class _LinkBody extends StatefulWidget {
  final PlanModeContext ctx;
  const _LinkBody(this.ctx, {super.key});
  @override
  State<_LinkBody> createState() => _LinkBodyState();
}

class _LinkBodyState extends State<_LinkBody> {
  String? _a, _b;
  bool _pickA = false;
  bool _loading = false;
  PlanResult<PlanLinkResult>? _res;
  String? _resKey, _askedKey;
  int _seq = 0;

  PlanModeContext get ctx => widget.ctx;

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
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeRun());
  }

  @override
  void dispose() {
    ctx.plan.removeListener(_onPlan);
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    super.dispose();
  }

  bool _onNodeTap(String id) {
    if (ctx.controller.plan.node(id) == null) return false;
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
    final p = ctx.controller.plan;
    setState(() {
      if (_a != null && p.node(_a!) == null) _a = null;
      if (_b != null && p.node(_b!) == null) _b = null;
      // A node that joins a plan with an end free fills it.
      _a ??= p.nodes.where((n) => n.id != _b).firstOrNull?.id;
      _b ??= p.nodes.where((n) => n.id != _a).firstOrNull?.id;
    });
    _maybeRun();
  }

  PlanLinkRequest? get _request {
    final p = ctx.controller.plan;
    final a = _a == null ? null : p.node(_a!), b = _b == null ? null : p.node(_b!);
    if (a == null || b == null || a.id == b.id) return null;
    return PlanLinkRequest(
      a: a.point,
      b: b.point,
      haM: a.antennaM,
      hbM: b.antennaM,
      radio: p.radio,
      clutter: p.clutter,
      aKey: a.existingKey,
      bKey: b.existingKey,
    );
  }

  double? get _km {
    final p = ctx.controller.plan;
    final a = _a == null ? null : p.node(_a!), b = _b == null ? null : p.node(_b!);
    return a == null || b == null ? null : haversineKm(a.lat, a.lon, b.lat, b.lon);
  }

  bool get _inRange {
    final km = _km;
    return km != null && km >= 0.1 && km <= 40;
  }

  void _maybeRun() {
    final r = _request;
    if (r == null || !_inRange) {
      _publish();
      return;
    }
    final key = PlanApi.linkKey(r);
    if (key == _askedKey) {
      _publish();
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    final r = _request;
    if (r == null || !_inRange) return;
    final p = ctx.controller.plan;
    final a = p.node(_a!)!, b = p.node(_b!)!;
    final key = PlanApi.linkKey(r);
    final n = ++_seq;
    setState(() {
      _loading = true;
      _askedKey = key;
    });
    _publish();
    final res = await ctx.api.link(r, aTxDbm: a.effectiveTxDbm, bTxDbm: b.effectiveTxDbm, aGainDbi: a.effectiveGainDbi, bGainDbi: b.effectiveGainDbi);
    if (!mounted || n != _seq) return;
    setState(() {
      _loading = false;
      _res = res;
      _resKey = key;
    });
    _publish();
  }

  void _publish() {
    if (_a == null || _b == null) {
      ctx.setOverlay(PlanModeOverlay.empty);
      return;
    }
    final current = _res?.ok == true && _request != null && _resKey == PlanApi.linkKey(_request!);
    ctx.setOverlay(PlanModeOverlay(links: [PlanOverlayLink(fromId: _a!, toId: _b!, verdict: current ? overlayVerdict(_res!.data!.verdict) : PlanLinkVerdict.unknown)]));
  }

  Widget _end(BuildContext context, String label, String? value, ValueChanged<String?> onChanged, Key key) {
    final nodes = ctx.controller.nodes;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.xs),
      child: DropdownButtonFormField<String>(
        key: key,
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [for (final n in nodes) DropdownMenuItem(value: n.id, child: Text(n.name, overflow: TextOverflow.ellipsis))],
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final nodes = ctx.controller.nodes;
    if (nodes.length < 2) {
      return AppEmptyView(
        key: const Key('plan-mode-link'),
        symbol: AppSymbols.route,
        title: nodes.isEmpty ? 'Add two nodes to check a link' : 'Add one more node to check a link',
        message: 'Long-press the map to drop a planned node, or add a repeater from the network.',
        actionLabel: 'Add from the network',
        onAction: ctx.openNodePicker,
      );
    }
    final km = _km;
    final req = _request;
    final res = _res;
    final current = res != null && req != null && _resKey == PlanApi.linkKey(req);
    return Column(key: const Key('plan-mode-link'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _end(context, 'End A', _a, (v) {
        setState(() {
          _a = v;
          if (_b == v) _b = null;
        });
        _maybeRun();
      }, Key('link-a-$_a')),
      _end(context, 'End B', _b, (v) {
        setState(() {
          _b = v;
          if (_a == v) _a = null;
        });
        _maybeRun();
      }, Key('link-b-$_b')),
      Text('Tip: tap a node on the map to make it an end.', style: t.textTheme.bodySmall),
      if (km != null) PlanFact('Straight line', units.distance(km * 1000)),
      if (km != null && km > 40)
        PlanLine(AppSymbols.exclamationTriangle, 'The ends are ${units.distance(km * 1000)} apart; a link check reads terrain for up to ${units.distance(40000)}.', key: const Key('link-toofar')),
      if (km != null && km < 0.1)
        PlanLine(AppSymbols.exclamationTriangle, 'The ends are less than ${units.distance(100)} apart. Move one of them.', key: const Key('link-tooclose')),
      const SizedBox(height: Gap.s),
      _primary(context,
          key: const Key('link-run'),
          label: _loading ? 'Reading the terrain…' : current ? 'Check again' : 'Check this link',
          symbol: AppSymbols.route,
          busy: _loading,
          onPressed: req != null && _inRange ? () => unawaited(_run()) : null),
      const SizedBox(height: Gap.s),
      if (_loading && !current) ConstrainedBox(constraints: const BoxConstraints(minHeight: 120), child: AppLoadingView(label: 'Reading the terrain between the two ends…', timeout: Duration(seconds: 50))),
      if (res != null && !res.ok && current)
        AppErrorView(key: const Key('link-error'), title: 'Could not check the link', message: res.error, onRetry: () => unawaited(_run())),
      if (res != null && res.ok) _result(context, res, current, units),
    ]);
  }

  Widget _result(BuildContext context, PlanResult<PlanLinkResult> r, bool current, Units units) {
    final t = Theme.of(context);
    final d = r.data!;
    final v = d.verdict;
    final p = ctx.controller.plan;
    final aName = _a == null ? 'A' : p.node(_a!)?.name ?? 'A';
    return Semantics(
      container: true,
      child: Column(key: const Key('link-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!current) const PlanLine(AppSymbols.clock, 'The ends or settings changed: this is the last result. Check again to update it.', key: Key('link-stale')),
        if (v != null)
          PlanLine(verdictSymbol(v), '${verdictWords(v)} (Estimate)',
              key: const Key('link-verdict'), color: t.colorScheme.primary, style: t.textTheme.titleLarge),
        if (d.odds != null) PlanFact('Terrain odds (Estimate)', '${(d.odds! * 100).clamp(0, 100).toStringAsFixed(0)} %'),
        PlanFact('Distance', units.distance(d.km * 1000)),
        if (d.fresnelClearancePct != null) PlanFact('Fresnel zone open at the tightest point', '${d.fresnelClearancePct!.toStringAsFixed(0)} %'),
        if (d.marginDb != null) PlanFact('Link margin (Estimate)', dbWords(d.marginDb!, signed: true)),
        if (d.tightest != null && d.tightest!.raiseM > 0)
          PlanLine(AppSymbols.arrowUpCircleFill, 'Raise $aName by ${units.height(d.tightest!.raiseM)} to clear 60 % of the Fresnel zone.', key: const Key('link-raise')),
        if (d.ridge != null) PlanLine(AppSymbols.flag, 'Blocking ridge ${units.distance(d.ridge!.km * 1000)} from $aName.', key: const Key('link-ridge')),
        if (d.measured != null)
          PlanLine(
            AppSymbols.waveform,
            'Measured: ${d.measured!.echoes} ${d.measured!.echoes == 1 ? 'echo' : 'echoes'}'
            '${d.measured!.meanSnr == null ? '' : ', mean SNR ${dbWords(d.measured!.meanSnr!)}'}'
            '${d.measured!.lastAt == null ? '' : ', last ${_when(d.measured!.lastAt!)}'} (${d.measured!.source}).',
            key: const Key('link-measured'),
          )
        else
          const PlanLine(AppSymbols.waveform, 'Measured: no packets or drives recorded between these two yet.', key: Key('link-measured-none')),
        ...resultNotes(context, r),
        Text(
          'Estimate from bare-earth terrain${d.provenance.terrain.isEmpty ? '' : ' (${d.provenance.terrain})'}; trees use the plan\'s clutter setting. Not a promise.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
      ]),
    );
  }
}

// ------------------------------------------------------------------------------------------------ Coverage (compact)

class _CoverageMode extends PlanMode {
  const _CoverageMode();
  @override
  PlanModeId get id => PlanModeId.coverage;
  @override
  String get label => 'Coverage';
  @override
  AppSymbol get symbol => AppSymbols.antenna;
  @override
  String get hint => 'What a repeater at a node of the plan would cover.';
  @override
  Widget buildSheet(PlanModeContext context) => _CoverageBody(context, key: ValueKey('plan-mode-body-coverage-${context.intent?.seq}'));
}

/// The numbers the compact coverage body shows, from plan-verify or, when that endpoint is not there, the website's
/// coverage painter (`/api/cmh/coverage`, the same model).
class _CoverageView {
  final double coveredKm2;
  final List<(String id, String label, double km2)> bands;
  final double? newAreaKm2;
  final int? newPeople;
  final List<(String key, String name, double km, double marginDb)> links;
  final String note;
  const _CoverageView({required this.coveredKm2, required this.bands, this.newAreaKm2, this.newPeople, required this.links, required this.note});

  static _CoverageView ofVerify(PlanVerifyResult r) => _CoverageView(
        coveredKm2: r.coveredKm2,
        bands: [for (final b in r.bands) (b.id, b.label, b.areaKm2)],
        newAreaKm2: r.newAreaKm2,
        newPeople: r.newPeople,
        links: [for (final l in r.links) (l.publicKey, l.name, l.km, l.marginDb)],
        note: r.provenance.terrain.isEmpty ? '' : 'Terrain: ${r.provenance.terrain}.',
      );

  static _CoverageView ofPainter(PainterResult r) => _CoverageView(
        coveredKm2: r.coveredKm2,
        bands: [for (final b in r.bands) (b.id, b.label, b.areaKm2)],
        newPeople: r.peopleNew,
        links: [for (final l in r.links) (l.publicKey, l.name, l.km, l.marginDb)],
        note: '${r.note} Terrain: ${r.terrainSource}.',
      );
}

class _CoverageBody extends StatefulWidget {
  final PlanModeContext ctx;
  const _CoverageBody(this.ctx, {super.key});
  @override
  State<_CoverageBody> createState() => _CoverageBodyState();
}

class _CoverageBodyState extends State<_CoverageBody> {
  String? _node;
  bool _loading = false;
  PlanResult<_CoverageView>? _res;
  String? _resKey;
  int _seq = 0;

  PlanModeContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    final i = ctx.intent;
    _node = i?.kind == PlanModeIntentKind.coverageOf ? i!.nodeId : (ctx.selectedNodeId ?? ctx.controller.nodes.firstOrNull?.id);
    ctx.hooks.onNodeTap = _onNodeTap;
    ctx.plan.addListener(_onPlan);
    ctx.setOverlay(PlanModeOverlay.empty);
    if (i?.kind == PlanModeIntentKind.coverageOf) WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_run()));
  }

  @override
  void dispose() {
    ctx.plan.removeListener(_onPlan);
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    super.dispose();
  }

  void _onPlan() {
    if (!mounted) return;
    setState(() {
      if (_node != null && ctx.controller.plan.node(_node!) == null) _node = ctx.controller.nodes.firstOrNull?.id;
      _node ??= ctx.controller.nodes.firstOrNull?.id;
    });
  }

  bool _onNodeTap(String id) {
    if (ctx.controller.plan.node(id) == null) return false;
    setState(() => _node = id);
    ctx.selectNode(id);
    return true;
  }

  PlanVerifyRequest? get _request {
    final p = ctx.controller.plan;
    final n = _node == null ? null : p.node(_node!);
    if (n == null) return null;
    return PlanVerifyRequest(
      site: n.point,
      radio: p.radio,
      antennaM: n.antennaM,
      txDbm: n.effectiveTxDbm,
      gainDbi: n.effectiveGainDbi,
      clutter: p.clutter,
      receiverM: p.receiverM,
      mount: n.mount,
    );
  }

  Future<void> _run() async {
    final r = _request;
    if (r == null) return;
    final key = PlanApi.verifyKey(r);
    final n = ++_seq;
    setState(() => _loading = true);
    final s = AppScope.read(context);
    final v = await ctx.api.verify(r);
    PlanResult<_CoverageView> out;
    if (v.ok) {
      out = PlanResult.ok(_CoverageView.ofVerify(v.data!), at: v.at, offlineAsOf: v.offlineAsOf);
    } else if (v.unavailable) {
      // The planner endpoint is not on this server yet: the website's coverage painter runs the same model.
      final p = await CoveragePainterApi(s.planBaseUrl, s.planStore).paint(PainterParams(
        lat: r.site.lat,
        lon: r.site.lon,
        antennaFt: (r.antennaM / ftM).clamp(6, 200).toDouble(),
        txDbm: r.txDbm.clamp(0, 30).toDouble(),
        gainDbi: r.gainDbi.clamp(-3, 12).toDouble(),
      ));
      out = p.ok ? PlanResult.ok(_CoverageView.ofPainter(p.data!), at: p.at, offlineAsOf: p.offlineAsOf) : PlanResult.fail(p.error ?? v.error ?? 'No answer.');
    } else {
      out = PlanResult.fail(v.error ?? 'No answer.');
    }
    if (!mounted || n != _seq) return;
    setState(() {
      _loading = false;
      _res = out;
      _resKey = key;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final nodes = ctx.controller.nodes;
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
    final p = ctx.controller.plan;
    final node = _node == null ? null : p.node(_node!);
    final req = _request;
    final current = _res != null && req != null && _resKey == PlanApi.verifyKey(req);
    return Column(key: const Key('plan-mode-coverage'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Gap.xs),
        child: DropdownButtonFormField<String>(
          key: Key('coverage-node-$_node'),
          initialValue: _node,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Site', border: OutlineInputBorder()),
          items: [for (final n in nodes) DropdownMenuItem(value: n.id, child: Text(n.name, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() => _node = v),
        ),
      ),
      if (node != null)
        PlanFact('Antenna', '${units.height(node.antennaM)} above ground, ${node.effectiveTxDbm.round()} dBm, ${node.effectiveGainDbi.toStringAsFixed(1)} dBi'),
      if (node != null)
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
      _primary(context,
          key: const Key('coverage-run'),
          label: _loading ? 'Estimating coverage…' : current ? 'Estimate again' : 'Estimate coverage',
          symbol: AppSymbols.antenna,
          busy: _loading,
          onPressed: req == null ? null : () => unawaited(_run())),
      if (_loading) const PlanLine(AppSymbols.clock, 'The model reads terrain tiles and sweeps the area; the first run for a place can take up to a minute.'),
      const SizedBox(height: Gap.s),
      if (_res != null && !_res!.ok)
        AppErrorView(key: const Key('coverage-error'), title: 'Could not estimate coverage', message: _res!.error, onRetry: () => unawaited(_run())),
      if (_res != null && _res!.ok) _result(context, _res!, current, units, t),
    ]);
  }

  Widget _result(BuildContext context, PlanResult<_CoverageView> r, bool current, Units units, ThemeData t) {
    final d = r.data!;
    final bandWords = {'below': 'No decode', 'fringe': 'Fringe (0 to 6 dB margin)', 'usable': 'Usable (6 to 12 dB)', 'solid': 'Solid (over 12 dB)'};
    final heard = d.links.where((l) => l.$4 >= 0).toList();
    return Column(key: const Key('coverage-result'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!current) const PlanLine(AppSymbols.clock, 'The site or settings changed: this is the last result. Estimate again to update it.', key: Key('coverage-stale')),
      Semantics(
        label: 'Covered area, Estimate: ${areaWords(units, d.coveredKm2)}',
        excludeSemantics: true,
        child: Text(areaWords(units, d.coveredKm2), key: const Key('coverage-area'), style: numberStyle(context, size: 30)),
      ),
      Text('Estimate: area where a handheld can decode this site', style: t.textTheme.bodySmall),
      const SizedBox(height: Gap.s),
      for (final b in d.bands)
        if (b.$1 != 'below') PlanFact(bandWords[b.$1] ?? b.$2, areaWords(units, b.$3)),
      if (d.newAreaKm2 != null) PlanFact('New area not covered today', areaWords(units, d.newAreaKm2!)),
      if (d.newPeople != null) PlanFact('People not covered by a live repeater today', '${d.newPeople}'),
      const SizedBox(height: Gap.s),
      if (heard.isEmpty)
        const PlanLine(AppSymbols.antenna, 'No live repeater is predicted to hear this site.', key: Key('coverage-nolinks'))
      else ...[
        Semantics(header: true, child: Text('Predicted links to live repeaters', style: t.textTheme.titleSmall)),
        for (final l in heard.take(8)) PlanFact('${l.$2} · ${units.distance(l.$3 * 1000)}', dbWords(l.$4, signed: true)),
      ],
      ...resultNotes(context, r),
      if (d.note.isNotEmpty) Text('Estimate, not a measurement. ${d.note}', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ Find sites (compact)

class _FindSitesMode extends PlanMode {
  const _FindSitesMode();
  @override
  PlanModeId get id => PlanModeId.findSites;
  @override
  String get label => 'Find sites';
  @override
  AppSymbol get symbol => AppSymbols.magnifyingglass;
  @override
  String get hint => 'Where a new repeater would help most, in the part of the map you are looking at.';
  @override
  bool get needsNodes => false;
  @override
  Widget buildSheet(PlanModeContext context) => _FindSitesBody(context, key: const ValueKey('plan-mode-body-sites'));
}

String goalWords(PlanGoal g) => switch (g) {
      PlanGoal.overall => 'Best overall',
      PlanGoal.coverage => 'Coverage',
      PlanGoal.links => 'Links',
      PlanGoal.redundancy => 'Redundancy',
    };

class _FindSitesBody extends StatefulWidget {
  final PlanModeContext ctx;
  const _FindSitesBody(this.ctx, {super.key});
  @override
  State<_FindSitesBody> createState() => _FindSitesBodyState();
}

class _FindSitesBodyState extends State<_FindSitesBody> {
  bool _loading = false;
  PlanResult<PlanSuggestResult>? _res;
  String? _noView;
  int _seq = 0;

  PlanModeContext get ctx => widget.ctx;

  @override
  void initState() {
    super.initState();
    ctx.hooks.onNodeTap = _onNodeTap;
    ctx.setOverlay(PlanModeOverlay.empty);
  }

  @override
  void dispose() {
    if (ctx.hooks.onNodeTap == _onNodeTap) ctx.hooks.onNodeTap = null;
    super.dispose();
  }

  List<PlanSite> get _sites => _res?.data?.sites ?? const [];

  bool _onNodeTap(String id) {
    if (!id.startsWith('site-')) return false;
    final s = _sites.where((x) => 'site-${x.id}' == id).firstOrNull;
    if (s == null) return false;
    _add(s);
    return true;
  }

  void _publish() => ctx.setOverlay(PlanModeOverlay(targets: [
        for (var i = 0; i < _sites.length; i++)
          MapFocusTarget(id: 'site-${_sites[i].id}', at: LatLng(_sites[i].at.lat, _sites[i].at.lon), label: '#${i + 1}'),
      ]));

  Future<void> _run() async {
    final b = ctx.visibleBounds();
    if (b == null) {
      setState(() => _noView = 'The map has not opened yet. Try again in a moment.');
      return;
    }
    final p = ctx.controller.plan;
    final n = ++_seq;
    setState(() {
      _loading = true;
      _noView = null;
    });
    final r = await ctx.api.suggest(PlanSuggestRequest(bounds: b, goal: p.goal, radio: p.radio, clutter: p.clutter, receiverM: p.receiverM));
    if (!mounted || n != _seq) return;
    setState(() {
      _loading = false;
      _res = r;
    });
    _publish();
  }

  void _add(PlanSite s) {
    final i = _sites.indexOf(s);
    try {
      final node = ctx.controller.addNode(name: 'Site ${i + 1}', lat: s.at.lat, lon: s.at.lon, mount: s.mount, heightM: s.heightAboveM == null ? null : plannedHeightM);
      ctx.selectNode(node.id);
      unawaited(AppHaptics.success());
      showAppToast(context, 'Added ${node.name} to the plan.', kind: AppToastKind.success, actionLabel: 'Undo', onAction: ctx.controller.undo);
    } on PlanFullException catch (e) {
      showAppToast(context, e.toString(), kind: AppToastKind.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final units = AppScope.unitsOf(context);
    final goal = ctx.controller.plan.goal;
    final r = _res;
    return Column(key: const Key('plan-mode-sites'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Ranks places in the part of the map above this sheet. Only the view and the plan\'s radio settings are sent.', style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.s),
      Semantics(header: true, child: Text('Goal', style: t.textTheme.titleSmall)),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        for (final g in const [PlanGoal.overall, PlanGoal.coverage, PlanGoal.links, PlanGoal.redundancy])
          ChoiceChip(
            key: Key('sites-goal-${g.wire}'),
            label: Text(goalWords(g)),
            selected: goal == g,
            onSelected: (_) => setState(() => ctx.controller.setGoal(g)),
          ),
      ]),
      const SizedBox(height: Gap.s),
      _primary(context, key: const Key('sites-run'), label: _loading ? 'Finding sites…' : 'Find sites in this view', symbol: AppSymbols.magnifyingglass, busy: _loading, onPressed: () => unawaited(_run())),
      const SizedBox(height: Gap.s),
      if (_noView != null) PlanLine(AppSymbols.infoCircle, _noView!),
      if (_loading && r == null) ConstrainedBox(constraints: const BoxConstraints(minHeight: 120), child: AppLoadingView(label: 'Ranking places from the network data…', timeout: Duration(seconds: 35))),
      if (r != null && !r.ok)
        AppErrorView(
          key: const Key('sites-error'),
          title: r.unavailable ? 'Find sites is not on this region\'s server yet' : 'Could not find sites',
          message: r.unavailable ? '${r.error} Your plan, Link and Coverage keep working; try again later.' : r.error,
          onRetry: () => unawaited(_run()),
        ),
      if (r != null && r.ok && r.data!.preparing)
        const AppEmptyView(
            key: Key('sites-preparing'),
            symbol: AppSymbols.clock,
            title: 'This region\'s site table is being built',
            message: 'The server is preparing the candidates for this region. Try again in a few minutes.'),
      if (r != null && r.ok && !r.data!.preparing && r.data!.sites.isEmpty)
        AppEmptyView(
            key: const Key('sites-empty'),
            symbol: AppSymbols.magnifyingglass,
            title: 'No sites in this view',
            message: 'Zoom out or move the map, then find sites again.',
            actionLabel: 'Try again',
            onAction: () => unawaited(_run())),
      if (r != null && r.ok && r.data!.sites.isNotEmpty) ...[
        ...resultNotes(context, r),
        Column(key: const Key('sites-result'), children: [
          for (var i = 0; i < r.data!.sites.length; i++) _site(context, i, r.data!.sites[i], units),
        ]),
        Text('Estimates ranked from measured coverage, the network and terrain; tap Add to put a site in the plan.',
            style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      ],
    ]);
  }

  Widget _site(BuildContext context, int i, PlanSite s, Units units) {
    final t = Theme.of(context);
    return ListTile(
      key: Key('site-${s.id}'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: Gap.s,
      leading: CircleAvatar(radius: 16, child: Text('${i + 1}')),
      title: Text('Score ${s.score.round()}${s.heightAboveM == null ? '' : ' · ${units.height(s.heightAboveM!)} above the area'}'),
      subtitle: Text(s.reason.isEmpty ? 'Site ${i + 1}' : s.reason),
      onTap: () => ctx.focusMap(s.at, zoom: 14),
      trailing: TextButton(
        key: Key('site-add-${s.id}'),
        style: TextButton.styleFrom(minimumSize: const Size(Hit.min, Hit.min)),
        onPressed: () => _add(s),
        child: Text('Add', semanticsLabel: 'Add site ${i + 1} to the plan', style: TextStyle(color: t.colorScheme.primary)),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ Where to drive

/// Where to drive (plan §4.1): the DriveNextCard as it was on the old Plan tab, plus "Show on the Drive map", which opens
/// the Drive tab's map with the targets drawn on its `plan` layer (MainMapFocus, J5).
class WhereToDriveMode extends PlanMode {
  const WhereToDriveMode();
  @override
  PlanModeId get id => PlanModeId.whereToDrive;
  @override
  String get label => 'Where to drive';
  @override
  AppSymbol get symbol => AppSymbols.car;
  @override
  String get hint => 'Places near you that nobody has measured yet.';
  @override
  bool get needsNodes => false;
  @override
  Widget buildSheet(PlanModeContext context) => _WhereToDriveBody(context, key: const ValueKey('plan-mode-body-drive'));
}

class _WhereToDriveBody extends StatefulWidget {
  final PlanModeContext ctx;
  const _WhereToDriveBody(this.ctx, {super.key});
  @override
  State<_WhereToDriveBody> createState() => _WhereToDriveBodyState();
}

class _WhereToDriveBodyState extends State<_WhereToDriveBody> {
  late final h3 = loadHexEngine();
  String _shown = '';

  @override
  void initState() {
    super.initState();
    widget.ctx.setOverlay(PlanModeOverlay.empty);
  }

  List<MapFocusTarget> _targets(List<DriveTarget> ts, Units units, LatLng me) => [
        for (var i = 0; i < ts.length; i++)
          MapFocusTarget(
            id: 'drive-$i',
            at: LatLng(ts[i].lat, ts[i].lon),
            label: '${units.distance(ts[i].distanceM)} ${compass(bearingDeg(me.latitude, me.longitude, ts[i].lat, ts[i].lon))}',
          ),
      ];

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final units = AppScope.unitsOf(context);
    final fix = s.phoneFix;
    final cov = s.networkCoverage;
    final me = fix == null ? null : LatLng(fix.fix.lat, fix.fix.lon);
    final targets = me == null || cov == null ? const <DriveTarget>[] : driveNextTargets(coverage: cov, lat: me.latitude, lon: me.longitude, h3: h3);
    final sig = [for (final x in targets) '${x.lat},${x.lon}'].join(';');
    if (sig != _shown) {
      _shown = sig;
      final ov = me == null ? PlanModeOverlay.empty : PlanModeOverlay(targets: _targets(targets, units, me));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.ctx.setOverlay(ov);
      });
    }
    return Column(key: const Key('plan-mode-drive'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const DriveNextCard(),
      if (me != null && targets.isNotEmpty)
        _primary(context, key: const Key('drive-next-show-map'), label: 'Show on the Drive map', symbol: AppSymbols.car, onPressed: () {
          MainMapFocus.request(me, 13, showLayers: const {kPlanLayerId}, targets: _targets(targets, units, me));
          ShellScope.maybeRead(context)?.openDrive();
        }),
    ]);
  }
}
