// Plan tab, "Where to drive next": measured-coverage gaps near the phone, from the network coverage the app already holds
// (lib/core/drive_next.dart). A small map, a list with distance and direction, and "Navigate" into Apple Maps. Every state
// says what to do: no location, loading, failed, nothing to find.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:h3_flutter/h3_flutter.dart' show H3;
import 'package:latlong2/latlong.dart';

import '../../core/drive_next.dart';
import '../../core/heard.dart' show compass;
import '../../core/hex_cells.dart' show loadHexEngine;
import '../../core/units.dart' show Units;
import '../app.dart';
import '../map/coverage_map.dart' show CoverageMap;

typedef DriveNextMapBuilder = Widget Function(
  BuildContext context,
  LatLng me,
  List<DriveTarget> targets,
);

class DriveNextCard extends StatefulWidget {
  /// Tests replace the tile map for every card (the Plan tab builds it without arguments).
  @visibleForTesting
  static DriveNextMapBuilder? testMap;

  /// Test seam: tiles never load in widget tests.
  final DriveNextMapBuilder? mapBuilder;
  final H3? h3;
  const DriveNextCard({super.key, this.mapBuilder, this.h3});

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

  Widget _frame(BuildContext context, Widget child) {
    final t = Theme.of(context);
    return Card(
      key: const Key('plan-drive-next'),
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: Padding(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.explore_outlined, color: t.colorScheme.primary),
                const SizedBox(width: Gap.s),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      'Where to drive next',
                      style: t.textTheme.titleMedium,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Gap.xs),
            child,
          ],
        ),
      ),
    );
  }

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
          note?.message ?? 'MeshSonar needs your location to find gaps near you. No account needed.',
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
          'No silent or unmapped areas within ${units.distance(15000)} of you in the data we have'
          '. Pick a place on the Map tab to look elsewhere.',
        ),
      );
    }
    final m = MeshSonarColors.of(context);
    return _frame(
      context,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Grey means someone drove there and the mesh heard nothing. Unmapped means nobody has logged a ping yet '
            '(it may not be a road). Within ${units.distance(15000)} of you.',
            style: t.textTheme.bodySmall?.copyWith(
              color: t.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Gap.s),
          (widget.mapBuilder ?? DriveNextCard.testMap ?? _defaultMap)(context, me, targets),
          const SizedBox(height: Gap.xs),
          for (var i = 0; i < targets.length; i++)
            _row(context, i, targets[i], me, units, m),
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
    MeshSonarColors m,
  ) {
    final s = AppScope.of(context);
    final silent = x.kind == DriveTargetKind.silent;
    final dir = compass(
      bearingDegrees(me.latitude, me.longitude, x.lat, x.lon),
    );
    final what = silent
        ? 'Silent area (${x.pings} ping${x.pings == 1 ? '' : 's'}, none heard)'
        : 'Unmapped area';
    return ListTile(
      key: Key('plan-target-$i'),
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: Gap.s,
      leading: Icon(
        silent ? Icons.circle : Icons.circle_outlined,
        color: silent ? m.silent : Theme.of(context).colorScheme.primary,
      ),
      title: Text('${units.distance(x.distanceM)} $dir'),
      subtitle: Text(what),
      trailing: TextButton.icon(
        key: Key('plan-navigate-$i'),
        style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
        icon: const Icon(Icons.navigation_outlined, size: 18),
        label: const Text('Navigate'),
        onPressed: () async {
          final ok = await s.services.openUrl(
            appleMapsDirections(x.lat, x.lon, label: 'MeshSonar: $what'),
          );
          if (!ok && context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not open Maps.')),
            );
          }
        },
      ),
    );
  }

  Widget _defaultMap(
    BuildContext context,
    LatLng me,
    List<DriveTarget> targets,
  ) {
    final m = MeshSonarColors.of(context);
    final cs = Theme.of(context).colorScheme;
    final pts = [me, for (final x in targets) LatLng(x.lat, x.lon)];
    return ClipRRect(
      key: const Key('plan-drive-next-map'),
      borderRadius: BorderRadius.circular(Corners.small),
      child: SizedBox(
        height: 200,
        child: FlutterMap(
          options: MapOptions(
            initialCameraFit: CameraFit.coordinates(
              coordinates: pts,
              padding: const EdgeInsets.all(36),
              maxZoom: 14,
            ),
            backgroundColor: m.mapBackground,
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.none,
            ),
          ),
          children: [
            TileLayer(
              urlTemplate: CoverageMap.tileUrl,
              userAgentPackageName: CoverageMap.userAgentPackageName,
              maxNativeZoom: 19,
              tileBuilder: (context, tile, _) => ColorFiltered(
                colorFilter: ColorFilter.matrix(m.tileMatrix),
                child: tile,
              ),
            ),
            MarkerLayer(
              markers: [
                for (final x in targets)
                  Marker(
                    point: LatLng(x.lat, x.lon),
                    width: 22,
                    height: 22,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: x.kind == DriveTargetKind.silent
                            ? m.silent
                            : Colors.transparent,
                        border: Border.all(
                          color: x.kind == DriveTargetKind.silent
                              ? Colors.white
                              : cs.primary,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                Marker(
                  point: me,
                  width: 20,
                  height: 20,
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF1E6FFF),
                      border: Border.fromBorderSide(
                        BorderSide(color: Colors.white, width: 3),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
