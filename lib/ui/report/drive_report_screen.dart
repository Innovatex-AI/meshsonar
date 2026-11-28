// After-drive report, the drive's analysis (Round 5 D-10; the detail screen is its home): the verdict as the headline
// with distance, cells, heard % and repeaters under it, a map of the drive's grid cells in the percent-heard teal scale,
// new grids and repeaters, signal over time, the repeaters heard, best and worst spots (each with Show on map), then one
// "Radio details" group whose one-line readings open their charts (noise floor, reply strength, transmit power, echoes,
// signal by distance, heard by speed, GPS), the phone and radio context, weather, and the one Share sheet
// (drive_share.dart). Opened from the drive card, the drive detail screen and the Drive screen's "View drive report".
// The numbers come from lib/core/drive_report.dart, computed once per open (async; fine for drives of thousands of
// pings). The v2 chart sections live in drive_report_sections.dart.
import '../map/main_map_focus.dart' show MainMapFocus;
import '../map/map_preview.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../app/app_state.dart';
import '../../core/drive_report.dart';
import '../../core/drive_stats.dart' show formatDuration, signalWords;
import '../../core/map_tool_style.dart';
import '../../core/model.dart';
import '../../core/privacy_zones.dart' show PrivacyZone, distanceM;
import '../../core/time_format.dart' as tf;
import '../app.dart';
import '../design/app_surfaces.dart' show showAppSheet;
import '../drive_detail_screen.dart' show antennaText;
import '../map/active_map_definition.dart';
import '../map/coverage_map.dart' show CoverageMap;
import '../map/layers/repeater_name_labels.dart' show RepeaterNameLabels;
import '../map/layers/repeater_painter_layer.dart' show RepeaterBadge, RepeaterPainterLayer;
import '../map/layers/repeater_sprites.dart' show RepeaterFreshness;
import '../map/tools/drive_key.dart';
import '../map/tools/zone_layer.dart';
import '../onboarding/ui_prefs.dart' show driveLabel;
import '../widgets.dart';
import 'drive_context_section.dart';
import 'drive_report_sections.dart';
import 'drive_share.dart';
import 'drive_weather_section.dart';

/// The one way to open a drive report (Drive tab finished dock, Drives list, drive detail, progress). On Apple
/// platforms it is a full-height page sheet with a Done button (swipe down also closes); elsewhere a normal page.
Future<void> openDriveReport(BuildContext context, String sessionId) async {
  final apple = const {TargetPlatform.iOS, TargetPlatform.macOS}.contains(Theme.of(context).platform);
  if (apple) {
    await showAppSheet<void>(
      context,
      detents: const [1.0],
      builder: (_, _) => DriveReportScreen(sessionId: sessionId, asSheet: true),
    );
    return;
  }
  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveReportScreen(sessionId: sessionId)));
}

/// Loads the drive, the earlier drives on this phone and builds the report.
Future<DriveReport> loadDriveReport(AppState s, String sessionId) async {
  final store = s.services.store;
  final ses = await store.session(sessionId);
  if (ses == null) throw StateError('This drive is no longer on this phone.');
  final pings = await store.pings(sessionId);
  final earlier = <List<DrivePing>>[];
  for (final x in await store.sessions()) {
    if (x.session.id == sessionId || !x.session.startedAt.isBefore(ses.startedAt)) continue;
    earlier.add(await store.pings(x.session.id));
  }
  return DriveReport.compute(
    session: ses,
    pings: pings,
    earlier: earlier,
    lookup: s.lookup,
    cmatListLoaded: s.repeaters.isNotEmpty,
  );
}

class DriveReportScreen extends StatefulWidget {
  final String sessionId;

  /// True inside the page sheet: a Done button replaces the back arrow.
  final bool asSheet;
  const DriveReportScreen({super.key, required this.sessionId, this.asSheet = false});
  @override
  State<DriveReportScreen> createState() => _DriveReportScreenState();
}

class _DriveReportScreenState extends State<DriveReportScreen> {
  Future<DriveReport>? _report;
  Future<String?>? _battery;

  /// [_battery] once it has loaded: the exports never wait for it (an export made before it loads has no line).
  String? _batteryLine;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _report ??= loadDriveReport(AppScope.read(context), widget.sessionId);
    _battery ??= driveBatteryLine(AppScope.read(context), widget.sessionId)..then((v) => _batteryLine = v, onError: (Object _) => null);
  }

  Future<void> _openShare(DriveReport r) => showDriveShareSheet(context, widget.sessionId, report: r, battery: _batteryLine);

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return FutureBuilder<DriveReport>(
      future: _report,
      builder: (context, snap) {
        final r = snap.data;
        final title = r == null
            ? 'Drive report'
            : (driveLabel(s, r.session.id, r.session.label) ?? tf.dateTime(r.session.startedAt, weekday: true));
        return Scaffold(
          key: const Key('drive-report'),
          appBar: AppBar(
            title: const Text('Drive report'),
            automaticallyImplyLeading: !widget.asSheet,
            leading: widget.asSheet
                ? TextButton(
                    key: const Key('report-done'),
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Done'),
                  )
                : null,
            leadingWidth: widget.asSheet ? 88 : null,
            actions: [
              if (r != null)
                IconButton(
                  key: const Key('report-export'),
                  tooltip: 'Share',
                  icon: const Icon(Icons.ios_share),
                  onPressed: () => _openShare(r),
                ),
            ],
          ),
          body: snap.hasError
              ? Padding(padding: const EdgeInsets.all(16), child: ErrorBanner('Couldn\'t build the report. ${snap.error}'))
              : r == null
                  ? const Center(child: CircularProgressIndicator())
                  : _ReportBody(report: r, battery: _battery, title: title, onShare: () => _openShare(r)),
        );
      },
    );
  }
}

class _ReportBody extends StatelessWidget {
  final DriveReport report;
  final Future<String?>? battery;
  final String title;
  final VoidCallback onShare;
  const _ReportBody({required this.report, this.battery, required this.title, required this.onShare});

  @override
  Widget build(BuildContext context) {
    final r = report;
    return SafeArea(
      top: false,
      child: ListView(
        key: const Key('report-list'),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
        children: [
          _Hero(report: r, title: title),
          DriveBatteryLine(line: battery),
          const SizedBox(height: 10),
          _Highlights(report: r),
          if (r.cells.isNotEmpty) ...[
            const _Heading('Where you mapped', icon: Icons.grid_on),
            _CellMap(report: r),
          ],
          const _Heading('The drive', icon: Icons.speed),
          _NumberGrid(report: r),
          if (r.snrSeries.isNotEmpty) ...[
            const _Heading('Signal over the drive', icon: Icons.show_chart),
            _Panel(key: const Key('report-snr-chart'), child: SnrSection(report: r)),
          ],
          // Build 76: what a driver asks first (which repeaters, where it worked) comes before the radio charts; it used to
          // sit ten screens down, after noise floor, RSSI, hops, speed, GPS, context and weather.
          if (r.repeaters.isNotEmpty) ...[
            _Heading('Repeaters heard', icon: Icons.emoji_events_outlined, trailing: '${r.repeaters.length}'),
            _Leaderboard(report: r),
          ],
          if (r.bestCell != null || r.worstCell != null) ...[
            const _Heading('Best and worst spots', icon: Icons.place_outlined),
            _Spots(report: r),
          ],
          // Round 5 D-11: the radio charts fold into one group; each row is a one-line reading that opens its chart.
          const _Heading('Radio details', icon: Icons.graphic_eq),
          _RadioDetails(report: r),
          DriveContextSection(sessionId: r.session.id, pings: r.sortedPings),
          DriveWeatherSection(sessionId: r.session.id, pings: r.sortedPings),
          const SizedBox(height: 18),
          // The same Share sheet as the app bar, the drive card and the detail screen (Round 5 D-6).
          FilledButton.icon(
            key: const Key('report-share-button'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            onPressed: onShare,
            icon: const Icon(Icons.ios_share),
            label: const Text('Share'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- pieces

/// The phone battery headline under the hero (build 70): "Battery: 82% → 61% (−21% in 1 h 40 min, −12.6%/h), mode
/// Balanced". Hidden when the drive has fewer than 2 battery samples (category Phone battery off, or a short drive).
class DriveBatteryLine extends StatelessWidget {
  final Future<String?>? line;
  const DriveBatteryLine({super.key, required this.line});

  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(
        future: line,
        builder: (context, snap) {
          final line = snap.data;
          if (line == null) return const SizedBox.shrink();
          final t = Theme.of(context);
          return Padding(
            padding: const EdgeInsets.fromLTRB(6, 10, 6, 0),
            child: Row(children: [
              Icon(Icons.battery_std_outlined, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(line, key: const Key('report-battery-line'), style: t.textTheme.bodyMedium)),
            ]),
          );
        },
      );
}

class _Heading extends StatelessWidget {
  final String text;
  final IconData icon;
  final String? trailing;
  const _Heading(this.text, {required this.icon, this.trailing});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
      child: Row(children: [
        Icon(icon, size: 18, color: t.colorScheme.primary),
        const SizedBox(width: 8),
        Text(text.toUpperCase(),
            style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          Text(trailing!, style: t.textTheme.labelLarge?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        ],
      ]),
    );
  }
}

class _Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const _Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14)});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(Corners.card),
        border: Border.all(color: t.colorScheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _Hero extends StatelessWidget {
  final DriveReport report;
  final String title;
  const _Hero({required this.report, required this.title});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    final r = report;
    final when = tf.dateTime(r.session.startedAt, weekday: true);
    final sub = <String>[
      if (title != when) when,
      formatDuration(r.duration),
      ?antennaText(r.session.antenna.type),
    ].join(' · ');
    return Container(
      key: const Key('report-hero'),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Corners.card),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [c.primaryContainer, Color.alphaBlend(c.primary.withValues(alpha: 0.10), c.surface)],
        ),
        border: Border.all(color: c.primary.withValues(alpha: 0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall?.copyWith(color: c.onPrimaryContainer)),
        const SizedBox(height: 4),
        // Round 5 D-1: the verdict is the headline (build 76 led with a very large distance).
        Text(r.verdict.line, key: const Key('report-verdict'), style: t.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text(sub, style: t.textTheme.bodySmall?.copyWith(color: c.onPrimaryContainer.withValues(alpha: 0.8))),
        const SizedBox(height: 14),
        // Distance joins the stat row.
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: _HeroStat(valueKey: const Key('report-distance'), value: AppScope.unitsOf(context).distance(r.distanceM), label: 'driven'),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-grids'),
              value: '${r.gridsMapped}',
              label: 'cells mapped',
              badge: r.newGrids > 0 ? '+${r.newGrids} new' : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-heard'),
              value: r.heardPercent == null ? '—' : '${r.heardPercent}%',
              label: 'pings heard',
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-repeaters'),
              value: '${r.repeaters.length}',
              label: 'repeaters',
              badge: r.newRepeaters.isNotEmpty ? '+${r.newRepeaters.length} new' : null,
              repeater: true,
            ),
          ),
        ]),
      ]),
    );
  }
}

class _HeroStat extends StatelessWidget {
  final Key valueKey;
  final String value;
  final String label;
  final String? badge;

  /// The badge is about repeaters: the repeater colour (slate), not the old amber.
  final bool repeater;
  const _HeroStat({required this.valueKey, required this.value, required this.label, this.badge, this.repeater = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final color = repeater ? m.repeater : t.colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(value, key: valueKey, style: numberStyle(context, size: 26)),
      ),
      Text(label, style: t.textTheme.labelMedium, maxLines: 1, overflow: TextOverflow.ellipsis),
      const SizedBox(height: 4),
      SizedBox(
        height: 22,
        child: badge == null
            ? null
            : FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: repeater ? m.repeaterTint : color.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(badge!, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
                ),
              ),
      ),
    ]);
  }
}

/// Short sentences for the things worth celebrating.
class _Highlights extends StatelessWidget {
  final DriveReport report;
  const _Highlights({required this.report});
  @override
  Widget build(BuildContext context) {
    final r = report;
    final s = AppScope.of(context);
    final m = MeshSonarColors.of(context);
    final c = Theme.of(context).colorScheme;
    final items = <(IconData, Color, String)>[];
    if (r.earlierDrives == 0 && r.cells.isNotEmpty) {
      items.add((Icons.flag_outlined, c.primary, 'First drive on this phone: every cell is new.'));
    } else if (r.newGrids > 0) {
      items.add((Icons.grid_on, c.primary, '${r.newGrids} cell${r.newGrids == 1 ? '' : 's'} you had never driven before.'));
    }
    final newReps = r.newRepeaters;
    if (newReps.isNotEmpty && r.earlierDrives > 0) {
      final names = newReps.take(3).map((x) => s.repeaterName(x.id) ?? x.label).join(', ');
      items.add((Icons.cell_tower, m.repeater,
          'New repeater${newReps.length == 1 ? '' : 's'} heard: $names${newReps.length > 3 ? ' +${newReps.length - 3} more' : ''}.'));
    }
    final f = r.farthest;
    if (f != null) {
      items.add((Icons.wifi_tethering, c.primary, 'Farthest: ${s.repeaterName(f.id) ?? f.label}, ${s.units.distance(f.farthestM!)} away.'));
    }
    if (r.cmatChecked && r.unknownToCmat.isNotEmpty) {
      items.add((Icons.help_outline, c.onSurfaceVariant,
          '${r.unknownToCmat.length} repeater${r.unknownToCmat.length == 1 ? ' isn\'t' : 's aren\'t'} on MeshSonar\'s list yet.'));
    }
    if (items.isEmpty) return const SizedBox.shrink();
    return _Panel(
      key: const Key('report-highlights'),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Column(children: [
        for (final (icon, color, text) in items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
                child: Icon(icon, size: 17, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
            ]),
          ),
      ]),
    );
  }
}

/// Heard fraction 0..1 → colour: the No-reply colour (silent) at 0, then the percent-heard teal scale (Round 5 D-14: the
/// signal ramp means signal strength only).
Color heardColor(MeshSonarColors m, ReportCell c) {
  if (c.heard == 0) return m.silent;
  return m.heardAt(c.heardFraction);
}

/// The zones whose circle reaches the part of the world the report map frames (a zone of another city is neither drawn nor counted
/// in the key), and only when the definition carries the tool style: without it the report map draws no zone, as in build 73.
List<PrivacyZone> _zonesOnMap(List<PrivacyZone> all, double south, double north, double west, double east) {
  if (MapToolStyle.of(ActiveMapDefinition.current) == null || south > north) return const [];
  return [
    for (final z in all)
      if (distanceM(z.lat.clamp(south, north).toDouble(), z.lon.clamp(west, east).toDouble(), z.lat, z.lon) <= z.radiusM) z,
  ];
}

class _CellMap extends StatelessWidget {
  final DriveReport report;
  const _CellMap({required this.report});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final m = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final r = report;
    var south = 90.0, north = -90.0, west = 180.0, east = -180.0;
    for (final c in r.cells) {
      south = math.min(south, c.south);
      north = math.max(north, c.north);
      west = math.min(west, c.west);
      east = math.max(east, c.east);
    }
    final reps = [
      for (final x in r.repeaters)
        if (x.match.ref != null) x,
    ];
    final badges = [
      for (final x in reps)
        RepeaterBadge(
          key: x.match.ref!.key,
          name: s.repeaterName(x.id) ?? x.label,
          lat: x.match.ref!.lat,
          lon: x.match.ref!.lon,
          isRoom: x.match.ref!.isRoom,
          freshness: RepeaterFreshness.fresh,
          heard: true,
        ),
    ];
    final tiles = CoverageMap.tilesByDefault;
    final zones = _zonesOnMap(s.privacyZones.zones, south, north, west, east);
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(Corners.card),
        child: SizedBox(
          key: const Key('report-map'),
          height: 260,
          child: MapPreview(
            fit: CameraFit.bounds(
              bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
              padding: const EdgeInsets.all(28),
              maxZoom: 16,
            ),
            interaction: MapPreviewInteraction.zoom,
            tiles: tiles,
            openAt: LatLng((south + north) / 2, (west + east) / 2),
            overlays: [
              // The phone's privacy zones over the cells, from the definition's `symbols.tools.zone` (nothing without it: build 73 drew none).
              if (zones.isNotEmpty) ZoneLayer(zones: zones),
              PolygonLayer(polygons: [
                for (final c in r.cells)
                  Polygon(
                    points: [LatLng(c.south, c.west), LatLng(c.north, c.west), LatLng(c.north, c.east), LatLng(c.south, c.east)],
                    color: heardColor(m, c).withValues(alpha: 0.55),
                    borderColor: c.isNew ? t.colorScheme.onSurface.withValues(alpha: 0.75) : heardColor(m, c),
                    borderStrokeWidth: c.isNew ? 1.6 : 1,
                  ),
              ]),
              // The repeaters this drive heard: the same badges and names as the Drive map (one painter, plan 6.1).
              RepeaterPainterLayer(sources: const [], badges: badges),
              // Names beside the repeaters (the "Repeater names" map setting), so none needs a tap to be identified.
              if (s.settings.mapRepeaterLabels)
                RepeaterNameLabels(
                  inset: const EdgeInsets.only(bottom: 20),
                  sources: const [],
                  badges: badges,
                  pill: tiles,
                ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
      if (zones.isNotEmpty) ...[
        Align(alignment: Alignment.centerLeft, child: DriveKey(dots: false, zones: zones.length)),
        const SizedBox(height: 8),
      ],
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(children: [
          Text('Heard', style: t.textTheme.labelMedium),
          const SizedBox(width: 8),
          Container(
            width: 18,
            height: 12,
            decoration: BoxDecoration(color: m.silent.withValues(alpha: 0.8), borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 4),
          Text('0%', style: t.textTheme.labelSmall),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 12,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                gradient: LinearGradient(colors: m.heardStops),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text('100%', style: t.textTheme.labelSmall),
          const SizedBox(width: 14),
          Container(
            width: 14,
            height: 12,
            decoration: BoxDecoration(border: Border.all(color: t.colorScheme.onSurface, width: 2), borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 4),
          Text('new', style: t.textTheme.labelSmall),
        ]),
      ),
      const SizedBox(height: 4),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          '${r.gridsMapped} cell${r.gridsMapped == 1 ? '' : 's'} · ${r.gridsWithCoverage} heard · ${r.newGrids} new',
          key: const Key('report-grid-caption'),
          style: t.textTheme.bodySmall,
        ),
      ),
    ]);
  }
}

class _NumberGrid extends StatelessWidget {
  final DriveReport report;
  const _NumberGrid({required this.report});
  @override
  Widget build(BuildContext context) {
    final r = report;
    final units = AppScope.unitsOf(context);
    // Round 5 D-10: no Pings / Heard tiles here (the headline and the row under it have them).
    final tiles = <(String, String, String)>[
      ('Avg speed', r.avgSpeedMps == null ? '—' : units.speed(r.avgSpeedMps!), 'report-avg-speed'),
      ('Top speed', r.maxSpeedMps == null ? '—' : units.speed(r.maxSpeedMps!), 'report-max-speed'),
      ('Best signal', signalWords(r.bestSnr), 'report-best-snr'),
      ('Cells with a reply', '${r.gridsWithCoverage} of ${r.gridsMapped}', 'report-covered'),
    ];
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth > 600 ? 3 : 2;
      final w = (box.maxWidth - (cols - 1) * 8) / cols;
      return Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (label, value, key) in tiles)
          SizedBox(
            width: w,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(Corners.chip),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 4),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(value, key: Key(key), style: numberStyle(context, size: 26)),
                ),
              ]),
            ),
          ),
      ]);
    });
  }
}

class _Hops extends StatelessWidget {
  final Map<int, int> hops;
  const _Hops({required this.hops});
  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final c = Theme.of(context).colorScheme;
    // Teal tints, strongest for Direct (Round 5 D-14): hops are not a signal reading.
    final parts = <(String, int, Color)>[
      ('Direct', hops[1] ?? 0, m.heardStops.last),
      ('2 hops', hops[2] ?? 0, m.heardStops[m.heardStops.length ~/ 2]),
      ('3+ hops', hops[3] ?? 0, m.heardStops.first),
      ('Unknown', hops[0] ?? 0, c.outline),
    ];
    final total = parts.fold<int>(0, (n, p) => n + p.$2);
    return Container(
      key: const Key('report-hops'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 18,
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (_, n, color) in parts)
                if (n > 0) Expanded(flex: n, child: ColoredBox(color: color)),
            ]),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 16, runSpacing: 6, children: [
          for (final (label, n, color) in parts)
            if (n > 0)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                const SizedBox(width: 6),
                Text('$label ', style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('$n · ${(100 * n / total).round()}%', style: Theme.of(context).textTheme.bodySmall),
              ]),
        ]),
        const SizedBox(height: 6),
        Text('Direct echoes measure your link to the repeater; multi-hop ones came back through other repeaters.',
            style: Theme.of(context).textTheme.bodySmall),
      ]),
    );
  }
}

class _Leaderboard extends StatelessWidget {
  final DriveReport report;
  const _Leaderboard({required this.report});
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final list = report.repeaters.take(15).toList();
    final max = list.first.timesHeard;
    return _Panel(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(children: [
        for (var i = 0; i < list.length; i++)
          Builder(builder: (context) {
            final x = list[i];
            final name = s.repeaterName(x.id);
            final details = [
              if (x.bestSnr != null) 'best ${signalWords(x.bestSnr)}',
              if (x.farthestM != null) 'up to ${s.units.distance(x.farthestM!)}',
              if (name != null) x.id.toUpperCase(),
            ].join(' · ');
            return Padding(
              key: ValueKey('report-rep-${x.id}'),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(children: [
                SizedBox(
                  width: 28,
                  child: Text('${i + 1}',
                      style: numberStyle(context, size: 22, color: i < 3 ? m.repeater : t.colorScheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(name ?? x.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (x.isNew && report.earlierDrives > 0)
                        _Tag('NEW', m.repeater, key: ValueKey('report-new-${x.id}')),
                      if (x.unknownToCmat) _Tag('not on MeshSonar', t.colorScheme.onSurfaceVariant, key: ValueKey('report-unknown-${x.id}')),
                    ]),
                    if (details.isNotEmpty) Text(details, style: t.textTheme.bodySmall),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: x.timesHeard / max, minHeight: 5, color: m.repeater, backgroundColor: m.repeaterTint),
                    ),
                  ]),
                ),
                const SizedBox(width: 12),
                Text('${x.timesHeard}×', key: ValueKey('report-rep-count-${x.id}'), style: numberStyle(context, size: 22)),
              ]),
            );
          }),
        if (report.repeaters.length > list.length)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text('+${report.repeaters.length - list.length} more', style: t.textTheme.bodySmall),
          ),
      ]),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  const _Tag(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4)),
      );
}

/// Opens the main map (the Drive tab) at [lat], [lon], the way the cell map's "Open the map" does (map_preview.dart).
void showSpotOnMap(BuildContext context, double lat, double lon) {
  MainMapFocus.request(LatLng(lat, lon), 16);
  final shell = ShellScope.maybeOf(context);
  if (shell == null) return;
  shell.select(AppTab.drive);
  Navigator.of(context).popUntil((r) => r.isFirst);
}

class _Spots extends StatelessWidget {
  final DriveReport report;
  const _Spots({required this.report});
  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    Widget card(String key, String title, IconData icon, ReportCell c, Color color, String line) => Expanded(
          child: _Panel(
            key: Key(key),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, color: color, size: 20),
                const SizedBox(width: 6),
                Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              ]),
              const SizedBox(height: 8),
              Text('${c.heardPercent}%', style: numberStyle(context, size: 30, color: color)),
              Text('heard (${c.heard}/${c.pings})', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(line, style: Theme.of(context).textTheme.bodySmall),
              // Round 5 D-8: a way to see the spot instead of raw coordinates (kept in the button's tooltip).
              Tooltip(
                message: '${c.centerLat.toStringAsFixed(4)}, ${c.centerLon.toStringAsFixed(4)}',
                child: TextButton.icon(
                  key: Key('$key-map'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44), padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
                  onPressed: () => showSpotOnMap(context, c.centerLat, c.centerLon),
                  icon: const Icon(Icons.map_outlined, size: 18),
                  label: const Text('Show on map'),
                ),
              ),
            ]),
          ),
        );
    final b = report.bestCell, w = report.worstCell;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (b != null)
        // Percent heard in its teal (not the signal green); the dead spot in the No-reply colour.
        card('report-best-spot', 'Best spot', Icons.trending_up, b, m.heardAt(b.heardFraction),
            b.bestSnr == null ? 'Signal not measured' : bestSignalReading(b.bestSnr)),
      if (b != null && w != null) const SizedBox(width: 8),
      if (w != null)
        card('report-worst-spot', 'Dead spot', Icons.trending_down, w, m.silent,
            '${w.pings - w.heard} ping${w.pings - w.heard == 1 ? '' : 's'} unanswered'),
    ]);
  }
}

/// Round 5 D-11: one group for the radio charts. Each row is a one-line reading; tapping it opens (and closes) its chart
/// under it. Only the rows the drive has data for are listed; the noise floor row is always there.
class _RadioDetails extends StatefulWidget {
  final DriveReport report;
  const _RadioDetails({required this.report});
  @override
  State<_RadioDetails> createState() => _RadioDetailsState();
}

class _RadioDetailsState extends State<_RadioDetails> {
  final Set<String> _open = {};

  @override
  Widget build(BuildContext context) {
    final r = widget.report;
    final rf = r.rf;
    final u = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final rows = <(String, IconData, String, Widget)>[
      ('noise', Icons.graphic_eq, noiseReading(rf), NoiseSection(key: const Key('report-noise'), report: r)),
      if (rf.rssiSeries.isNotEmpty) ('rssi', Icons.network_cell, rssiReading(rf), RssiSection(key: const Key('report-rssi'), report: r)),
      if (rf.txPowerChanges.isNotEmpty) ('txpower', Icons.bolt, txPowerReading(rf), TxPowerSection(report: r)),
      if (r.hops.values.any((n) => n > 0)) ('hops', Icons.alt_route, hopsReading(r.hops), _Hops(hops: r.hops)),
      if (rf.hasDistanceData)
        ('distance', Icons.social_distance, distanceReading(rf, u), DistanceSection(key: const Key('report-distance-bands'), report: r)),
      if (rf.hasSpeedData) ('speed', Icons.speed, speedReading(rf, u), SpeedSection(key: const Key('report-speed-bands'), report: r)),
      if (rf.gps != null) ('gps', Icons.gps_fixed, gpsReading(rf.gps!, u), GpsSection(key: const Key('report-gps'), gps: rf.gps!)),
    ];
    return _Panel(
      key: const Key('report-radio-details'),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 14, endIndent: 14),
          Builder(builder: (context) {
            final (id, icon, reading, chart) = rows[i];
            final open = _open.contains(id);
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              InkWell(
                key: Key('radio-row-$id'),
                onTap: () => setState(() => open ? _open.remove(id) : _open.add(id)),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 48),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    child: Row(children: [
                      Icon(icon, size: 20, color: t.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 12),
                      Expanded(child: Text(reading, key: Key('radio-reading-$id'), style: t.textTheme.bodyLarge)),
                      Icon(open ? Icons.expand_less : Icons.expand_more, color: t.colorScheme.onSurfaceVariant),
                    ]),
                  ),
                ),
              ),
              if (open) Padding(padding: const EdgeInsets.fromLTRB(14, 0, 14, 14), child: chart),
            ]);
          }),
        ],
      ]),
    );
  }
}
