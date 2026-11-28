// Plan tab, Where to drive (the Planner's fourth mode): measured-coverage gaps near the phone, from the network coverage
// the app already holds (lib/core/drive_next.dart). A list with distance and direction and "Navigate" into Apple Maps;
// tapping a row shows the place on the Planner's big map (build 77, round 4 P-V3: the panel's own small map and its title
// are gone, the big map already draws the same places). Every state says what to do: no location, loading, failed,
// nothing to find.
import 'package:flutter/material.dart';
import 'package:h3_flutter/h3_flutter.dart' show H3;
import 'package:latlong2/latlong.dart';

import '../../core/drive_next.dart';
import '../../core/heard.dart' show compass;
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/startup_location.dart' show LocationAction;
import '../../core/units.dart' show Units;
import '../../core/plan/plan_model.dart' show PlanNode, PlanNodeStatus;
import '../../core/plan_contract.dart' show PlanSite;
import '../app.dart';
import '../map/layers/registry.dart' show kPlanLayerId;
import '../map/main_map_focus.dart';
import '../nodes/node_actions.dart' show shellControllerFor;
import '../../core/coverage_v2.dart' show CoverageBand;
import '../map/coverage_bands.dart' show CoverageBandColors;
import '../design/app_surfaces.dart';

/// The colour the coverage map draws a "No reply" cell in (band 0), so a target dot matches the map and its key.
Color _noReply(BuildContext context) =>
    CoverageBandColors.of(MeshSonarColors.of(context).palette, Theme.of(context).brightness)[CoverageBand.noReply];

// ---------------------------------------------------------------------------------------------------- targets on the Drive map (J4)

/// Apple Maps directions to [lat], [lon] (the one hand-off every "Navigate" uses); false, with a toast, when Maps could not
/// open.
Future<bool> navigateToPoint(BuildContext context, double lat, double lon, {required String label}) async {
  final s = AppScope.read(context);
  final ok = await s.services.openUrl(appleMapsDirections(lat, lon, label: 'MeshSonar: $label'));
  if (!ok && context.mounted) showAppToast(context, 'Could not open Maps.', kind: AppToastKind.error);
  return ok;
}

/// A Find-sites result as targets for the Drive map, numbered in the order given (#1, #2 ... as on the planner's map).
List<MapFocusTarget> focusTargetsFromSites(Iterable<PlanSite> sites) => [
      for (final e in sites.indexed) MapFocusTarget(id: e.$2.id, at: LatLng(e.$2.at.lat, e.$2.at.lon), label: '#${e.$1 + 1}'),
    ];

/// The plan's sites that are still to be built (planned, not installed or existing) as targets to drive to.
List<MapFocusTarget> focusTargetsFromPlanNodes(Iterable<PlanNode> nodes) => [
      for (final n in nodes)
        if (n.status == PlanNodeStatus.planned) MapFocusTarget(id: n.id, at: LatLng(n.lat, n.lon), label: n.name),
    ];

/// Opens the Drive tab's map with [targets] drawn on its `plan` layer, the camera on the first of them. Closes the sheets
/// and screens above the tabs first. False (nothing happened) with no targets or no shell.
bool showTargetsOnDriveMap(BuildContext context, List<MapFocusTarget> targets, {double zoom = 13}) {
  if (targets.isEmpty) return false;
  final shell = shellControllerFor(context);
  if (shell == null) return false;
  Navigator.maybeOf(context, rootNavigator: true)?.popUntil((r) => r.isFirst);
  MainMapFocus.request(targets.first.at, zoom, showLayers: const {kPlanLayerId}, targets: targets);
  shell.openDrive();
  return true;
}

/// "Navigate" and "Show on the Drive map" for one place (a Find-sites result, a planned spot). Keys
/// `drive-target-navigate`, `drive-target-show-map`. Both outlined (build 77): amber is for warnings only, and the card's
/// own main action leads.
class DriveTargetActions extends StatelessWidget {
  final String name;
  final double lat, lon;

  /// What the Drive map draws; null = just this place.
  final List<MapFocusTarget>? targets;
  const DriveTargetActions({super.key, required this.name, required this.lat, required this.lon, this.targets});

  @override
  Widget build(BuildContext context) => Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        OutlinedButton.icon(
          key: const Key('drive-target-navigate'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.navigation_outlined, size: 18),
          label: const Text('Navigate'),
          onPressed: () => navigateToPoint(context, lat, lon, label: name),
        ),
        OutlinedButton.icon(
          key: const Key('drive-target-show-map'),
          style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(Icons.directions_car_outlined, size: 18),
          label: const Text('Show on the Drive map'),
          onPressed: () => showTargetsOnDriveMap(context, targets ?? [MapFocusTarget(id: 'target-$lat,$lon', at: LatLng(lat, lon), label: name)]),
        ),
      ]);
}

class DriveNextCard extends StatefulWidget {
  /// A tap on a place's row (the Planner centres its big map on it). Null: the rows only offer Navigate.
  final ValueChanged<DriveTarget>? onShow;

  /// Test seam: the hex engine.
  final H3? h3;
  const DriveNextCard({super.key, this.onShow, this.h3});

  @override
  State<DriveNextCard> createState() => _DriveNextCardState();
}

class _DriveNextCardState extends State<DriveNextCard> {
  late final H3? _h3 = widget.h3 ?? loadHexEngine();
  bool _asked = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_asked) return;
    _asked = true;
    final s = AppScope.read(context);
    if (s.networkCoverage == null && !s.networkCoverageLoading) {
      // Not during build: the refresh notifies the app state's listeners at once.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) s.refreshNetworkCoverage();
      });
    }
  }

  /// The list straight under the Planner's question line: no card, no title of its own (the question says it).
  Widget _frame(BuildContext context, Widget child) => KeyedSubtree(key: const Key('plan-drive-next'), child: child);

  Widget _note(BuildContext context, String text, {Widget? action}) {
    final t = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          style: t.textTheme.bodyMedium?.copyWith(
            color: t.colorScheme.onSurfaceVariant,
          ),
        ),
        if (action != null) ...[const SizedBox(height: Gap.s), action],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final fix = s.phoneFix;
    if (fix == null) {
      final note = s.locationNote;
      return _frame(
        context,
        _note(
          context,
          note == null
              ? 'Waiting for your location to find gaps near you.'
              : note.action == LocationAction.ask
                  ? 'Allow location to see the gaps near you: places where no repeater answered, and places nobody has driven.'
                  : 'Location is off for MeshSonar. Turn it on in Settings to see the gaps near you.',
          action: note?.actionLabel == null
              ? null
              : FilledButton.tonal(
                  key: const Key('plan-drive-next-location'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: s.resolveLocationNote,
                  child: Text(note!.actionLabel!),
                ),
        ),
      );
    }
    final cov = s.networkCoverage;
    if (cov == null) {
      if (s.networkCoverageFailed) {
        return _frame(
          context,
          _note(
            context,
            'Could not load the coverage data. Check your connection.',
            action: FilledButton.tonal(
              key: const Key('plan-drive-next-retry'),
              style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
              onPressed: () => s.refreshNetworkCoverage(),
              child: const Text('Try again'),
            ),
          ),
        );
      }
      return _frame(
        context,
        _note(context, 'Loading measured coverage near you…'),
      );
    }
    final me = LatLng(fix.fix.lat, fix.fix.lon);
    final targets = driveNextTargets(
      coverage: cov,
      lat: me.latitude,
      lon: me.longitude,
      h3: _h3,
    );
    final units = AppScope.unitsOf(context);
    final t = Theme.of(context);
    if (targets.isEmpty) {
      return _frame(
        context,
        _note(
          context,
          'Nothing to drive to within ${units.distance(15000)} of you: every place near you has been driven and answered.',
        ),
      );
    }
    return _frame(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dot: driven, but no repeater answered. Ring: nobody has driven there yet. '
            'Nearest first, within ${units.distance(15000)}.${widget.onShow == null ? '' : ' Tap a place to see it on the map.'}',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          for (var i = 0; i < targets.length; i++)
            _row(context, i, targets[i], me, units),
          if (fix.fix.lat != 0 && s.phoneFixNote != null)
            Padding(
              padding: const EdgeInsets.only(top: Gap.xs),
              child: Text(s.phoneFixNote!, style: t.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context,
    int i,
    DriveTarget x,
    LatLng me,
    Units units,
  ) {
    final silent = x.kind == DriveTargetKind.silent;
    final dir = compass(
      bearingDegrees(me.latitude, me.longitude, x.lat, x.lon),
    );
    final what = silent
        ? 'No reply (${x.pings} ping${x.pings == 1 ? '' : 's'}, no repeater answered)'
        : 'Nobody has driven here yet';
    final show = widget.onShow;
    return ListTile(
      key: Key('plan-target-$i'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: Gap.s,
      onTap: show == null ? null : () => show(x),
      leading: Icon(
        silent ? Icons.circle : Icons.circle_outlined,
        color: silent ? _noReply(context) : Theme.of(context).colorScheme.primary,
      ),
      title: Text('${units.distance(x.distanceM)} $dir'),
      subtitle: Text(what),
      trailing: TextButton.icon(
        key: Key('plan-navigate-$i'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.navigation_outlined, size: 18),
        label: const Text('Navigate'),
        onPressed: () => navigateToPoint(context, x.lat, x.lon, label: what),
      ),
    );
  }
}
