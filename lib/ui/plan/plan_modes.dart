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
import '../../core/plan/link_model.dart' show ftM;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_controller.dart';
import '../../core/plan_contract.dart';
import '../../core/units.dart' show Units;
import '../app.dart';
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import '../design/tokens.dart';
import '../map/layers/plan_overlay.dart' show PlanLinkVerdict, PlanOverlayLink;
import '../map/layers/registry.dart' show kPlanLayerId;
import '../map/main_map_focus.dart';
import '../shell/drive_next_card.dart';
import 'modes/find_sites_mode.dart';
import 'modes/link_mode.dart';

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
  const LinkMode(),
  const _CoverageMode(),
  const FindSitesMode(),
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
