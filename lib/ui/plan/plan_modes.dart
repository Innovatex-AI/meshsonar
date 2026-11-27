// The Planner's modes (release 0.38, plan §4.1: chips **Link · Coverage · Find sites · Where to drive**). Every mode acts on
// the one Plan the planner holds (lib/core/plan/plan_controller.dart) and is described by a [PlanMode]: its chip label and
// symbol, and [PlanMode.buildSheet], the content of the planner's bottom sheet while the mode is picked. A mode draws on
// the planner's map through [PlanModeContext.setOverlay] (planned links coloured by their Estimate, targets such as Find
// sites results) and can take map gestures through [PlanModeContext.hooks] (a long-press point, a tap on a plan node or a
// target).
//
// Registration: [planModes] below, one entry per chip, in chip order: LinkMode (ui/plan/modes/link_mode.dart),
// CoverageMode (coverage_mode.dart), FindSitesMode (find_sites_mode.dart + wizard.dart) and WhereToDriveMode (this file),
// which hosts the DriveNextCard list (ui/shell/drive_next_card.dart) and opens the Drive map with the targets; it stands on
// its own (build 77, round 4 P-U1: no plan bar, radio row, selected spot or list of spots around it). This file also keeps
// the pieces the modes share: PlanModeContext, the overlay, PlanFact, resultNotes.
//
// Keys: each mode file lists its own; this file's: 'plan-mode-drive' (the Where to drive body), 'drive-next-show-map'.

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart' show LatLng;

import '../../core/drive_next.dart' show driveNextTargets, DriveTarget;
import '../../core/heard.dart' show bearingDeg, compass;
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/plan/plan_api.dart';
import '../../core/plan/plan_controller.dart';
import '../../core/plan_contract.dart';
import '../../core/time_format.dart' show shortDateTime;
import '../../core/units.dart' show Units;
import '../app.dart';
import '../design/app_symbols.dart';
import '../design/tokens.dart';
import '../map/coverage_bands.dart' show CoverageBandColors;
import '../map/layers/plan_overlay.dart' show PlanLinkVerdict, PlanOverlayLink;
import '../map/layers/registry.dart' show kPlanLayerId;
import '../map/main_map_focus.dart';
import '../shell/drive_next_card.dart';
import 'modes/coverage_mode.dart';
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

  /// The one line the sheet shows under the chips: what this mode answers, in plain words (build 76).
  String get what => hint;

  /// Does this mode need spots in the plan before it can show anything? (While the plan is empty the planner shows only
  /// its first-run card instead of the body of a mode that does, round 4 P-V2.)
  bool get needsNodes => true;

  /// Does this mode work on the plan? False (Where to drive): the panel shows only the mode's own body, without the plan's
  /// row, radio row, selected spot and list of spots (round 4 P-U1).
  bool get usesPlan => true;

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

  /// "Add a spot": the planner's crosshair with Set here / Cancel (round 4 P-U3; press and hold still works).
  final VoidCallback addSpot;
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
    required this.addSpot,
  });
}

// ------------------------------------------------------------------------------------------------ registration

/// The planner's chips, in order. A full mode replaces its line here when it lands (A8 link, A9 coverage, A10 find sites).
final List<PlanMode> planModes = [
  const LinkMode(),
  const CoverageMode(),
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

/// "Estimate" words for a verdict (three states with the fade margin, plan §4.3 item 2). One set everywhere in Plan (build
/// 77, round 4 P-U4: Coverage said "Won't work" where Link said "Unlikely" for the same result).
String verdictWords(PlanVerdict v) => switch (v) {
      PlanVerdict.likely => 'Works',
      PlanVerdict.marginal => 'Marginal',
      PlanVerdict.unlikely => 'Unlikely',
    };

/// The colour a verdict's symbol takes. Marginal is the warning amber (the yellow coverage band was too faint on the light
/// panel, round 4); the words themselves are always in the normal text colour.
Color verdictColour(BuildContext context, PlanVerdict? v) {
  final m = MeshSonarColors.of(context);
  final bands = CoverageBandColors.of(m.palette, Theme.of(context).brightness);
  return switch (v) {
    PlanVerdict.likely => bands[5],
    PlanVerdict.marginal => m.warning,
    PlanVerdict.unlikely => bands[1],
    null => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

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

String areaWords(Units units, double km2) => units.area(km2);

String dbWords(double v, {bool signed = false}) => '${signed && v > 0 ? '+' : v < 0 ? '-' : ''}${v.abs().toStringAsFixed(1)} dB';

/// When a stored answer was made, through the app's one formatter (Local / UTC setting).
String _when(DateTime t) => shortDateTime(t);

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

// ------------------------------------------------------------------------------------------------ Where to drive

/// Where to drive (plan §4.1): the DriveNextCard list (a tap on a row centres the big map there) and "Show on the Drive
/// map", which opens the Drive tab's map with the targets drawn on its `plan` layer (MainMapFocus, J5). Nothing else of the
/// plan shows in this mode (round 4 P-U1).
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
  String get what => 'Where should I drive next?';
  @override
  bool get needsNodes => false;
  @override
  bool get usesPlan => false;
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
      DriveNextCard(onShow: (x) => widget.ctx.focusMap(PlanPoint(x.lat, x.lon), zoom: 14)),
      if (me != null && targets.isNotEmpty)
        _primary(context, key: const Key('drive-next-show-map'), label: 'Show on the Drive map', symbol: AppSymbols.car, onPressed: () {
          MainMapFocus.request(me, 13, showLayers: const {kPlanLayerId}, targets: _targets(targets, units, me));
          ShellScope.maybeRead(context)?.openDrive();
        }),
    ]);
  }
}
