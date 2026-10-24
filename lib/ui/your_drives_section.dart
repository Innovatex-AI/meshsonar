// "Your drives" section for a repeater (repeater detail screen and the drive repeater sheet): how often, where and how
// well the drives stored on this phone heard it (lib/core/repeater_history.dart). Where = coverage grid cells on a small
// map, never the raw track. Says plainly that it is from drives on this phone; the website's "where MeshSonar drives
// heard it" (repeater-reach) needs an auth the app does not have (stream 5 design doc, server request P1-b).
// Needs AppScope for the drive store; without one (isolated widget tests of a screen) it renders nothing.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/heard.dart';
import '../core/repeater_history.dart';
import 'app.dart';
import 'map/coverage_map.dart' show CoverageMap;
import 'onboarding/ui_prefs.dart' show driveLabel;
import 'report/drive_report_screen.dart' show openDriveReport;
import 'report/local_drives.dart';
import 'widgets.dart';

/// Drives listed under the facts before "and N more".
const int yourDrivesListed = 5;

class YourDrivesSection extends StatefulWidget {
  /// Full key or the id as heard.
  final String repeaterKey;

  /// The repeater's position when known (for "farthest" and the map marker).
  final double? lat, lon;

  /// Draw map tiles (off under `flutter test`).
  final bool mapTiles;
  const YourDrivesSection({super.key, required this.repeaterKey, this.lat, this.lon, bool? mapTiles})
      : mapTiles = mapTiles ?? true;

  @override
  State<YourDrivesSection> createState() => _YourDrivesSectionState();
}

class _YourDrivesSectionState extends State<YourDrivesSection> {
  Future<RepeaterHistory>? _future;
  bool _noScope = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_future != null || _noScope) return;
    if (context.getElementForInheritedWidgetOfExactType<AppScope>() == null) {
      _noScope = true;
      return;
    }
    _future = _load();
  }

  Future<RepeaterHistory> _load() async {
    final s = AppScope.read(context);
    final lookup = s.lookup;
    final local = await loadLocalDrives(s.services.store);
    var lat = widget.lat, lon = widget.lon;
    if (lat == null || lon == null) {
      final ref = lookup.resolve(widget.repeaterKey).ref;
      lat = ref?.lat;
      lon = ref?.lon;
    }
    return RepeaterHistory.compute(widget.repeaterKey, local.drives, lookup: lookup, lat: lat, lon: lon);
  }

  @override
  Widget build(BuildContext context) {
    if (_noScope) return const SizedBox.shrink();
    final t = Theme.of(context);
    return Column(
      key: const Key('your-drives'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Your drives', style: t.textTheme.titleMedium),
        Text('From drives stored on this phone.', style: t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted)),
        const SizedBox(height: Gap.s),
        FutureBuilder<RepeaterHistory>(
          future: _future,
          builder: (context, snap) {
            if (snap.hasError) {
              return Row(children: [
                Expanded(child: Text('Couldn\'t read the drives on this phone. ${snap.error}', key: const Key('your-drives-error'))),
                TextButton(
                  onPressed: () => setState(() {
                    _future = _load();
                  }),
                  child: const Text('Retry'),
                ),
              ]);
            }
            final h = snap.data;
            if (h == null) {
              return const Padding(
                padding: EdgeInsets.all(Gap.s),
                child: LinearProgressIndicator(key: Key('your-drives-loading')),
              );
            }
            return _body(context, h);
          },
        ),
      ],
    );
  }

  Widget _body(BuildContext context, RepeaterHistory h) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final s = AppScope.of(context);
    if (h.drivesSearched == 0) {
      return Text('No drives on this phone yet.', key: const Key('your-drives-none'), style: t.textTheme.bodyMedium);
    }
    if (h.isEmpty) {
      return Text(
          'None of the ${h.drivesSearched} drive${h.drivesSearched == 1 ? '' : 's'} on this phone heard this repeater.',
          key: const Key('your-drives-none'),
          style: t.textTheme.bodyMedium);
    }
    String name(RepeaterDriveHit d) => driveLabel(s, d.session.id, d.session.label) ?? formatDateTime(d.session.startedAt);
    final bestDrive = h.bestSnr == null ? null : h.drives.firstWhere((d) => d.bestSnr == h.bestSnr, orElse: () => h.drives.first);
    final facts = <(String, String, String)>[
      ('heard', 'Heard', '${h.hearings} time${h.hearings == 1 ? '' : 's'} on ${h.drives.length} of ${h.drivesSearched} drives'
          '${h.direct > 0 ? ' (${h.direct} direct)' : ''}'),
      ('best', 'Best SNR', h.bestSnr == null ? 'not measured' : '${h.bestSnr!.toStringAsFixed(1)} dB${bestDrive == null ? '' : ' (${name(bestDrive)})'}'),
      ('last', 'Last heard', formatDateTime(h.lastAt!)),
      ('first', 'First heard', formatDateTime(h.firstAt!)),
      if (h.farthestM != null) ('farthest', 'Farthest', '${u.distance(h.farthestM!)} from the repeater'),
      ('cells', 'Grid cells', '${h.cells.length}'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (id, k, v) in facts)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 100, child: Text(k, style: t.textTheme.labelMedium)),
            Expanded(child: Text(v, key: Key('your-drives-$id'), style: t.textTheme.bodyMedium)),
          ]),
        ),
      if (h.sharedIdHearings > 0)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(
            '${h.sharedIdHearings} of these used a short id that other known repeaters share, so some may be another repeater.',
            key: const Key('your-drives-shared'),
            style: t.textTheme.bodySmall,
          ),
        ),
      const SizedBox(height: Gap.s),
      _CellMap(history: h, lat: widget.lat, lon: widget.lon, tiles: widget.mapTiles && CoverageMap.tilesByDefault),
      const SizedBox(height: Gap.xs),
      Text('Grid cells where your drives heard it (about ${u.shortLength(220)} by ${u.shortLength(210)} each), coloured by the best SNR there.',
          style: t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted)),
      const SizedBox(height: Gap.s),
      for (final d in h.drives.take(yourDrivesListed))
        ListTile(
          key: Key('your-drives-drive-${d.session.id}'),
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(name(d)),
          subtitle: Text('${d.hearings} time${d.hearings == 1 ? '' : 's'} in ${d.cells.length} cell${d.cells.length == 1 ? '' : 's'}'
              ', last ${formatTime(d.lastAt).substring(0, 5)}'),
          trailing: Text(d.bestSnr == null ? 'SNR —' : 'best ${d.bestSnr!.toStringAsFixed(1)} dB'),
          onTap: () => openDriveReport(context, d.session.id),
        ),
      if (h.drives.length > yourDrivesListed)
        Text('and ${h.drives.length - yourDrivesListed} more drive${h.drives.length - yourDrivesListed == 1 ? '' : 's'}',
            key: const Key('your-drives-more'), style: t.textTheme.bodySmall),
    ]);
  }
}

class _CellMap extends StatelessWidget {
  final RepeaterHistory history;
  final double? lat, lon;
  final bool tiles;
  const _CellMap({required this.history, this.lat, this.lon, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final pts = <LatLng>[
      for (final c in history.cells) ...[LatLng(c.south, c.west), LatLng(c.north, c.east)],
      if (lat != null && lon != null) LatLng(lat!, lon!),
    ];
    final bounds = LatLngBounds.fromPoints(pts);
    return Semantics(
      container: true,
      label: 'Map of ${history.cells.length} grid cells where your drives heard this repeater.',
      excludeSemantics: true,
      child: ClipRRect(
        key: const Key('your-drives-map'),
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          height: 170,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(18), maxZoom: 15),
              backgroundColor: m.mapBackground,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.none),
            ),
            children: [
              if (tiles)
                TileLayer(
                  urlTemplate: CoverageMap.tileUrl,
                  userAgentPackageName: CoverageMap.userAgentPackageName,
                  maxNativeZoom: 19,
                  tileBuilder: (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(m.tileMatrix), child: tile),
                ),
              PolygonLayer(polygons: [
                for (final c in history.cells)
                  Polygon(
                    points: [LatLng(c.south, c.west), LatLng(c.south, c.east), LatLng(c.north, c.east), LatLng(c.north, c.west)],
                    color: m.forPing(heard: true, snr: c.bestSnr).withValues(alpha: 0.55),
                    borderColor: m.forPing(heard: true, snr: c.bestSnr),
                    borderStrokeWidth: 1,
                  ),
              ]),
              if (lat != null && lon != null)
                MarkerLayer(markers: [
                  Marker(point: LatLng(lat!, lon!), width: 24, height: 24, child: Icon(Icons.cell_tower, color: m.beacon, size: 24)),
                ]),
            ],
          ),
        ),
      ),
    );
  }
}

/// Convenience for callers holding a [RepeaterLookup] match: its key when resolved, else the id as heard.
String yourDrivesKey(String id, RepeaterLookup lookup) => lookup.resolve(id).ref?.key ?? id;
