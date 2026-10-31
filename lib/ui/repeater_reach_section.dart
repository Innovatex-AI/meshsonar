// "Where MeshSonar drives heard this repeater": the measured reach from ALL MeshSonar drivers' public drives
// (`repeater-reach` with the approved driver key, lib/core/repeater_reach.dart). Shown under "Your drives" on the Region
// tab's repeater screen and the drive repeater sheet, and labelled as the network-wide numbers so they are never
// mistaken for the phone-only ones. Privacy as the server applies it: public drives only, each drive's start and end
// trimmed and privacy zones removed, cells instead of tracks, times rounded to the hour. Every state is explicit.
// Needs AppScope; without one (isolated widget tests) it renders nothing.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../core/api.dart' show CmatException;
import '../core/region_cache.dart' show asOfLabel;
import '../core/repeater_reach.dart';
import '../core/units.dart';
import 'app.dart';
import 'charts/bar_chart.dart';
import 'charts/chart_frame.dart';
import 'map/coverage_map.dart' show CoverageMap;
import 'region/region_dataset_view.dart' show FigureStrip;
import 'settings_screen.dart' show DriverKeyScreen;
import 'widgets.dart';

final _hex = RegExp(r'^[0-9a-fA-F]{8,64}$');

/// True when [id] can be asked of the server (a full public key, at least 8 hex characters).
bool reachKeyUsable(String id) => _hex.hasMatch(id);

/// "under 1.0 km", "1.0 km to 2.0 km", "20 km and more" (in the person's units).
String reachBandLabel(ReachBandRow b, Units u) {
  if (b.fromKm == 0 && b.toKm != null) return 'under ${u.distance(b.toKm! * 1000)}';
  if (b.toKm == null) return '${u.distance(b.fromKm * 1000)} and more';
  return '${u.distance(b.fromKm * 1000)} to ${u.distance(b.toKm! * 1000)}';
}

/// The words for a failed ask (also used by tests). [retry] = a Retry button makes sense.
({String text, bool retry}) reachFailureText(Object error) {
  if (error is CmatException) {
    return switch (error.status) {
      401 => (text: 'The server doesn\'t recognise your driver key, so the network-wide numbers can\'t load. Check the key in Settings.', retry: true),
      403 => (text: 'The server hasn\'t accepted your driver key yet, so the network-wide numbers can\'t load.', retry: true),
      429 => (text: 'The server asked for a pause (too many requests). Try again in a minute.', retry: true),
      404 => (text: 'The server has no reach figures for this repeater.', retry: false),
      null => (text: 'No connection, and nothing is saved for this repeater yet. Retry when you are online.', retry: true),
      final c => (text: 'The server answered with an error ($c), so there are no network-wide numbers to show.', retry: true),
    };
  }
  return (text: 'Couldn\'t load where MeshSonar drives heard this repeater.', retry: true);
}

class RepeaterReachSection extends StatefulWidget {
  /// The repeater's full public key (hex).
  final String repeaterKey;

  /// The repeater's own position when known (the server measures "farthest" and the distance bands from it).
  final double? lat, lon;
  final bool mapTiles;
  const RepeaterReachSection({super.key, required this.repeaterKey, this.lat, this.lon, bool? mapTiles}) : mapTiles = mapTiles ?? true;

  @override
  State<RepeaterReachSection> createState() => _RepeaterReachSectionState();
}

class _RepeaterReachSectionState extends State<RepeaterReachSection> {
  Future<ReachResult>? _future;
  bool _asked = false;

  void _ask() {
    final s = AppScope.read(context);
    _future = s.repeaterReach(widget.repeaterKey.toLowerCase(), lat: widget.lat, lon: widget.lon);
  }

  @override
  void didUpdateWidget(RepeaterReachSection old) {
    super.didUpdateWidget(old);
    if (old.repeaterKey != widget.repeaterKey || old.lat != widget.lat || old.lon != widget.lon) _asked = false;
  }

  @override
  Widget build(BuildContext context) {
    if (context.getElementForInheritedWidgetOfExactType<AppScope>() == null) return const SizedBox.shrink();
    final s = AppScope.of(context);
    if (!s.serverHasReach || !reachKeyUsable(widget.repeaterKey)) return const SizedBox.shrink();
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: MeshSonarColors.of(context).textMuted);
    final header = <Widget>[
      Semantics(header: true, child: Text('Where MeshSonar drives heard this repeater', style: t.textTheme.titleMedium)),
      Text(
        'All MeshSonar drivers, from public drives only (the start and end of every drive are trimmed). '
        'Not the same as "Your drives", which counts only this phone.',
        style: muted,
      ),
      const SizedBox(height: Gap.s),
    ];
    Widget body;
    if (!s.keyApproved) {
      body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Once your driver key is ready (Settings), you can see where all MeshSonar drivers heard this repeater.',
            key: const Key('reach-needs-key'), style: t.textTheme.bodyMedium),
        TextButton.icon(
          key: const Key('reach-open-key-settings'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DriverKeyScreen())),
          icon: const Icon(Icons.vpn_key_outlined),
          label: const Text('Open driver key settings'),
        ),
      ]);
    } else {
      if (!_asked) {
        _asked = true;
        _ask();
      }
      body = FutureBuilder<ReachResult>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(padding: EdgeInsets.all(Gap.s), child: LinearProgressIndicator(key: Key('reach-loading')));
          }
          if (snap.hasError) {
            final f = reachFailureText(snap.error!);
            final st = snap.error is CmatException ? (snap.error as CmatException).status : null;
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(f.text, key: Key('reach-error-${st ?? 'offline'}'))),
              if (f.retry)
                TextButton(
                  key: const Key('reach-retry'),
                  onPressed: () => setState(_ask),
                  child: const Text('Retry'),
                ),
            ]);
          }
          return _body(context, snap.data!);
        },
      );
    }
    return Column(key: const Key('reach'), crossAxisAlignment: CrossAxisAlignment.start, children: [...header, body]);
  }

  Widget _body(BuildContext context, ReachResult res) {
    final t = Theme.of(context);
    final u = AppScope.unitsOf(context);
    final m = MeshSonarColors.of(context);
    final r = res.reach;
    final now = AppScope.read(context).services.clock().toUtc();
    final muted = t.textTheme.bodySmall?.copyWith(color: m.textMuted);
    final offline = res.offline
        ? Padding(
            padding: const EdgeInsets.only(bottom: Gap.s),
            child: Row(key: const Key('reach-offline'), children: [
              Icon(Icons.cloud_off, size: 16, color: t.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(child: Text('${asOfLabel(res.fetchedAt, now, offline: true)}. Retry when back online.', style: muted)),
              TextButton(key: const Key('reach-retry'), onPressed: () => setState(_ask), child: const Text('Retry')),
            ]),
          )
        : const SizedBox.shrink();
    if (r.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        offline,
        Text(
          'No MeshSonar drive has heard this repeater directly yet. Only public drives count, and the start and end of each '
          'drive are left out, so a repeater heard near where drives begin or end can show nothing here.',
          key: const Key('reach-empty'),
          style: t.textTheme.bodyMedium,
        ),
      ]);
    }
    final tot = r.totals;
    String snr(double? v) => v == null ? '—' : '${v.toStringAsFixed(1)} dB';
    final withBands = r.snrByDistance.where((b) => b.pings > 0).toList();
    final means = [for (final b in withBands) if (b.medianSnr != null) b.medianSnr!];
    final base = math.min(-20.0, means.isEmpty ? -20.0 : (means.reduce(math.min) / 5).floor() * 5.0 - 5);
    final cellH = r.cellDeg * 111195;
    final cellW = r.cells.isEmpty ? cellH : r.cellDeg * 111195 * math.cos(r.cells.first.lat * math.pi / 180);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      offline,
      FigureStrip([
        ('Heard', '${tot.heardPings}', 'pings, direct'),
        ('Drives', '${tot.drives}', '${tot.drivers} driver${tot.drivers == 1 ? '' : 's'}'),
        ('Best SNR', snr(tot.bestSnr), null),
        ('Median SNR', snr(tot.medianSnr), null),
        ('Farthest', tot.farthestKm == null ? '—' : u.distance(tot.farthestKm! * 1000), tot.farthestKm == null ? 'needs the repeater position' : 'from the repeater'),
        ('Last heard', tot.lastHeardAt == null ? '—' : formatDateTime(tot.lastHeardAt!), 'rounded to the hour'),
      ]),
      const SizedBox(height: Gap.s),
      if (r.cells.isNotEmpty) ...[
        _ReachMap(reach: r, lat: widget.lat, lon: widget.lon, tiles: widget.mapTiles && CoverageMap.tilesByDefault),
        const SizedBox(height: Gap.xs),
        Text(
          '${r.cells.length} cell${r.cells.length == 1 ? '' : 's'} where drives heard it (about ${u.shortLength(cellH)} by '
          '${u.shortLength(cellW)} each, never raw tracks), coloured by the best SNR there.',
          key: const Key('reach-map-caption'),
          style: muted,
        ),
        const SizedBox(height: Gap.s),
      ],
      if (r.snrByDistance.isEmpty)
        Text(
          widget.lat == null || widget.lon == null
              ? 'No signal-by-distance chart: this repeater\'s position is not known, and the distances are measured from it.'
              : 'No signal-by-distance chart yet: it needs this repeater heard by public drives.',
          key: const Key('reach-no-bands'),
          style: muted,
        )
      else
        ChartFrame(
          id: 'reach-bands',
          title: 'Signal by distance from this repeater (median SNR, dB)',
          summary: withBands.isEmpty
              ? 'No band has a reading.'
              : [for (final b in withBands) '${reachBandLabel(b, u)}: median ${snr(b.medianSnr)} from ${b.pings} ping${b.pings == 1 ? '' : 's'}.'].join(' '),
          caption: 'Direct replies from all MeshSonar drivers. Bars start at ${base.round()} dB; taller is a stronger signal.',
          table: ChartTable(head: const ['Distance', 'Pings', 'Median SNR (dB)'], rows: [
            for (final b in r.snrByDistance) [reachBandLabel(b, u), '${b.pings}', b.medianSnr == null ? '—' : b.medianSnr!.toStringAsFixed(1)],
          ]),
          chart: BarChart(
            labels: [for (final b in r.snrByDistance) b.toKm == null ? '> ${u.distance(b.fromKm * 1000)}' : '≤ ${u.distance(b.toKm! * 1000)}'],
            series: [BarSeries(name: 'Median SNR', values: [for (final b in r.snrByDistance) b.medianSnr], color: m.snrStrong)],
            base: base,
            yLabel: 'SNR dB',
          ),
        ),
    ]);
  }
}

class _ReachMap extends StatelessWidget {
  final RepeaterReach reach;
  final double? lat, lon;
  final bool tiles;
  const _ReachMap({required this.reach, this.lat, this.lon, required this.tiles});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final h = reach.cellDeg / 2;
    final pts = <LatLng>[
      for (final c in reach.cells) ...[LatLng(c.lat - h, c.lon - h), LatLng(c.lat + h, c.lon + h)],
      if (lat != null && lon != null) LatLng(lat!, lon!),
    ];
    return Semantics(
      container: true,
      label: 'Map of ${reach.cells.length} grid cells where MeshSonar drivers heard this repeater.',
      excludeSemantics: true,
      child: ClipRRect(
        key: const Key('reach-map'),
        borderRadius: BorderRadius.circular(Corners.small),
        child: SizedBox(
          height: 190,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(bounds: LatLngBounds.fromPoints(pts), padding: const EdgeInsets.all(18), maxZoom: 15),
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
                for (final c in reach.cells)
                  Polygon(
                    points: [LatLng(c.lat - h, c.lon - h), LatLng(c.lat - h, c.lon + h), LatLng(c.lat + h, c.lon + h), LatLng(c.lat + h, c.lon - h)],
                    color: m.forPing(heard: true, snr: c.bestSnr).withValues(alpha: 0.55),
                    borderColor: m.forPing(heard: true, snr: c.bestSnr),
                    borderStrokeWidth: 1,
                  ),
              ]),
              if (lat != null && lon != null)
                MarkerLayer(markers: [Marker(point: LatLng(lat!, lon!), width: 24, height: 24, child: Icon(Icons.cell_tower, color: m.beacon, size: 24))]),
            ],
          ),
        ),
      ),
    );
  }
}
