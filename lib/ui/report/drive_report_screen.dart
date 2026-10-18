// After-drive report: hero numbers, a map of the drive's grid cells coloured by heard %, new grids and repeaters,
// SNR over time, heard/not timeline, hops, a repeater leaderboard, best/worst spots, and "Share report".
// Opened from the drive detail screen ("Report") and from the Drive screen's "View drive report" card.
// The numbers come from drive_report.dart, computed once per open (async; fine for drives of thousands of pings).
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../../app/app_state.dart';
import '../../core/model.dart';
import '../app.dart';
import '../drive_stats.dart' show formatDistance, formatDuration, formatMiles;
import '../map/coverage_map.dart' show CoverageMap;
import '../onboarding/ui_prefs.dart' show driveLabel;
import '../sessions_screen.dart' show HeardStrip;
import '../widgets.dart';
import 'drive_report.dart';

void openDriveReport(BuildContext context, String sessionId) {
  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DriveReportScreen(sessionId: sessionId)));
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

String _mph(double mps) => '${(mps * 2.236936).toStringAsFixed(0)} mph';

class DriveReportScreen extends StatefulWidget {
  final String sessionId;
  const DriveReportScreen({super.key, required this.sessionId});
  @override
  State<DriveReportScreen> createState() => _DriveReportScreenState();
}

class _DriveReportScreenState extends State<DriveReportScreen> {
  Future<DriveReport>? _report;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _report ??= loadDriveReport(AppScope.read(context), widget.sessionId);
  }

  Future<void> _share(DriveReport r, String title) async {
    final s = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await s.services.exportDir();
      final f = File('${dir.path}/meshsonar-report-${widget.sessionId.split('-').first}.txt');
      await f.writeAsString(r.toText(title: 'MeshSonar drive report: $title', distance: formatDistance, duration: formatDuration));
      await s.services.shareFile(f);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Couldn\'t share the report. $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return FutureBuilder<DriveReport>(
      future: _report,
      builder: (context, snap) {
        final r = snap.data;
        final title = r == null
            ? 'Drive report'
            : (driveLabel(s, r.session.id, r.session.label) ?? formatDateTime(r.session.startedAt));
        return Scaffold(
          key: const Key('drive-report'),
          appBar: AppBar(
            title: const Text('Drive report'),
            actions: [
              if (r != null)
                IconButton(
                  key: const Key('report-share'),
                  tooltip: 'Share report',
                  onPressed: () => _share(r, title),
                  icon: const Icon(Icons.ios_share),
                ),
            ],
          ),
          body: snap.hasError
              ? Padding(padding: const EdgeInsets.all(16), child: ErrorBanner('Couldn\'t build the report. ${snap.error}'))
              : r == null
                  ? const Center(child: CircularProgressIndicator())
                  : _ReportBody(report: r, title: title, onShare: () => _share(r, title)),
        );
      },
    );
  }
}

class _ReportBody extends StatelessWidget {
  final DriveReport report;
  final String title;
  final VoidCallback onShare;
  const _ReportBody({required this.report, required this.title, required this.onShare});

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
          const SizedBox(height: 10),
          _Highlights(report: r),
          if (r.cells.isNotEmpty) ...[
            const _Heading('Grids mapped', icon: Icons.grid_on),
            _CellMap(report: r),
          ],
          const _Heading('The drive', icon: Icons.speed),
          _NumberGrid(report: r),
          if (r.snrSeries.isNotEmpty) ...[
            const _Heading('Signal over the drive', icon: Icons.show_chart),
            _Panel(
              key: const Key('report-snr-chart'),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(height: 170, child: _SnrChart(points: r.snrSeries)),
                const SizedBox(height: 14),
                Text('Heard / not heard, ping by ping', style: Theme.of(context).textTheme.labelMedium),
                const SizedBox(height: 6),
                HeardStrip(
                  timeline: [for (final p in r.snrSeries) p.heard],
                  snr: [for (final p in r.snrSeries) p.snr],
                  height: 22,
                ),
              ]),
            ),
          ],
          if (r.hops.values.any((n) => n > 0)) ...[
            const _Heading('How echoes came back', icon: Icons.alt_route),
            _Hops(hops: r.hops),
          ],
          if (r.repeaters.isNotEmpty) ...[
            _Heading('Repeater leaderboard', icon: Icons.emoji_events_outlined, trailing: '${r.repeaters.length}'),
            _Leaderboard(report: r),
          ],
          if (r.bestCell != null || r.worstCell != null) ...[
            const _Heading('Best and worst spots', icon: Icons.place_outlined),
            _Spots(report: r),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            key: const Key('report-share-button'),
            onPressed: onShare,
            icon: const Icon(Icons.ios_share),
            label: const Text('Share report'),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- pieces

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
    final sub = <String>[
      if (title != formatDateTime(r.session.startedAt)) formatDateTime(r.session.startedAt),
      formatDuration(r.duration),
      if (r.session.antenna.type != null) '${r.session.antenna.type} antenna',
    ].join(' · ');
    return Container(
      key: const Key('report-hero'),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
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
        Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: t.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 2),
        Text(sub, style: t.textTheme.bodySmall?.copyWith(color: c.onPrimaryContainer.withValues(alpha: 0.8))),
        const SizedBox(height: 14),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatDistance(r.distanceM), key: const Key('report-distance'), style: numberStyle(context, size: 52)),
            const SizedBox(width: 10),
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(formatMiles(r.distanceM),
                  style: numberStyle(context, size: 22, color: c.onSurfaceVariant, weight: FontWeight.w600)),
            ),
          ]),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-grids'),
              value: '${r.gridsMapped}',
              label: 'grids mapped',
              badge: r.newGrids > 0 ? '+${r.newGrids} new' : null,
            ),
          ),
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-heard'),
              value: r.heardPercent == null ? '—' : '${r.heardPercent}%',
              label: 'pings heard',
            ),
          ),
          Expanded(
            child: _HeroStat(
              valueKey: const Key('report-repeaters'),
              value: '${r.repeaters.length}',
              label: 'repeaters',
              badge: r.newRepeaters.isNotEmpty ? '+${r.newRepeaters.length} new' : null,
              beacon: true,
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
  final bool beacon;
  const _HeroStat({required this.valueKey, required this.value, required this.label, this.badge, this.beacon = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final color = beacon ? m.beacon : t.colorScheme.primary;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(value, key: valueKey, style: numberStyle(context, size: 34)),
      ),
      Text(label, style: t.textTheme.labelMedium),
      const SizedBox(height: 4),
      SizedBox(
        height: 22,
        child: badge == null
            ? null
            : Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(badge!, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
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
      items.add((Icons.flag_outlined, c.primary, 'First drive on this phone: every grid is new.'));
    } else if (r.newGrids > 0) {
      items.add((Icons.grid_on, c.primary, '${r.newGrids} grid${r.newGrids == 1 ? '' : 's'} you\'d never driven before.'));
    }
    final newReps = r.newRepeaters;
    if (newReps.isNotEmpty && r.earlierDrives > 0) {
      final names = newReps.take(3).map((x) => s.repeaterName(x.id) ?? x.label).join(', ');
      items.add((Icons.cell_tower, m.beacon,
          'New repeater${newReps.length == 1 ? '' : 's'} heard: $names${newReps.length > 3 ? ' +${newReps.length - 3} more' : ''}.'));
    }
    final f = r.farthest;
    if (f != null) {
      items.add((Icons.wifi_tethering, m.snrStrong, 'Farthest: ${s.repeaterName(f.id) ?? f.label}, ${formatDistance(f.farthestM!)} away.'));
    }
    if (r.cmatChecked && r.unknownToCmat.isNotEmpty) {
      items.add((Icons.help_outline, c.tertiary,
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

/// Heard fraction 0..1 → colour: silent red at 0, then weak blue → teal → green.
Color heardColor(MeshSonarColors m, ReportCell c) {
  if (c.heard == 0) return m.silent;
  final f = c.heardFraction;
  return f < 0.5 ? Color.lerp(m.snrWeak, m.snrMid, f * 2)! : Color.lerp(m.snrMid, m.snrStrong, (f - 0.5) * 2)!;
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
    final tiles = CoverageMap.tilesByDefault;
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(Corners.card),
        child: SizedBox(
          key: const Key('report-map'),
          height: 260,
          child: FlutterMap(
            options: MapOptions(
              initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds(LatLng(south, west), LatLng(north, east)),
                padding: const EdgeInsets.all(28),
                maxZoom: 16,
              ),
              backgroundColor: m.mapBackground,
              interactionOptions: const InteractionOptions(flags: InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom),
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
                for (final c in r.cells)
                  Polygon(
                    points: [LatLng(c.south, c.west), LatLng(c.north, c.west), LatLng(c.north, c.east), LatLng(c.south, c.east)],
                    color: heardColor(m, c).withValues(alpha: 0.55),
                    borderColor: c.isNew ? t.colorScheme.onSurface.withValues(alpha: 0.75) : heardColor(m, c),
                    borderStrokeWidth: c.isNew ? 1.6 : 1,
                  ),
              ]),
              MarkerLayer(markers: [
                for (final x in reps)
                  Marker(
                    point: LatLng(x.match.ref!.lat, x.match.ref!.lon),
                    width: 26,
                    height: 26,
                    child: Tooltip(
                      message: s.repeaterName(x.id) ?? x.label,
                      child: Container(
                        decoration: BoxDecoration(
                          color: m.beacon,
                          shape: BoxShape.circle,
                          border: Border.all(color: m.onBeacon, width: 2),
                        ),
                        child: Icon(Icons.cell_tower, size: 14, color: m.onBeacon),
                      ),
                    ),
                  ),
              ]),
              if (tiles)
                const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
            ],
          ),
        ),
      ),
      const SizedBox(height: 8),
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
                gradient: LinearGradient(colors: [m.snrWeak, m.snrMid, m.snrStrong]),
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
          '${r.gridsMapped} cells (≈220 m, the same grid as MeshSonar\'s coverage map) · ${r.gridsWithCoverage} with coverage · '
          '${r.newGrids} new',
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
    final tiles = <(String, String, String)>[
      ('Avg speed', r.avgSpeedMps == null ? '—' : _mph(r.avgSpeedMps!), 'report-avg-speed'),
      ('Top speed', r.maxSpeedMps == null ? '—' : _mph(r.maxSpeedMps!), 'report-max-speed'),
      ('Pings', '${r.txPings}', 'report-pings'),
      ('Heard', '${r.heardPings}', 'report-heard-count'),
      ('Best SNR', r.bestSnr == null ? '—' : '${r.bestSnr!.toStringAsFixed(1)} dB', 'report-best-snr'),
      ('With coverage', '${r.gridsWithCoverage} / ${r.gridsMapped}', 'report-covered'),
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

/// SNR (best echo per ping) over time; pings that heard nothing are red ticks on the floor.
class _SnrChart extends StatelessWidget {
  final List<SnrPoint> points;
  const _SnrChart({required this.points});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return CustomPaint(
      size: Size.infinite,
      painter: _SnrPainter(
        points: points,
        m: MeshSonarColors.of(context),
        grid: t.colorScheme.outlineVariant,
        label: t.textTheme.labelSmall!.copyWith(color: t.colorScheme.onSurfaceVariant),
        line: t.colorScheme.primary,
      ),
    );
  }
}

class _SnrPainter extends CustomPainter {
  final List<SnrPoint> points;
  final MeshSonarColors m;
  final Color grid, line;
  final TextStyle label;
  _SnrPainter({required this.points, required this.m, required this.grid, required this.label, required this.line});

  void _text(Canvas canvas, String s, Offset at, {bool right = false, bool center = false}) {
    final tp = TextPainter(text: TextSpan(text: s, style: label), textDirection: TextDirection.ltr)..layout();
    final dx = right ? at.dx - tp.width : (center ? at.dx - tp.width / 2 : at.dx);
    tp.paint(canvas, Offset(dx, at.dy - tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    const left = 34.0, bottom = 22.0, top = 18.0;
    final w = size.width - left - 4, h = size.height - bottom - top;
    var lo = -15.0, hi = 12.0;
    for (final p in points) {
      if (p.snr != null) {
        lo = math.min(lo, p.snr!.floorToDouble());
        hi = math.max(hi, p.snr!.ceilToDouble());
      }
    }
    double y(double snr) => top + h * (1 - (snr - lo) / (hi - lo));
    final t0 = points.first.ts.millisecondsSinceEpoch.toDouble();
    final span = math.max(1.0, points.last.ts.millisecondsSinceEpoch - t0);
    double x(DateTime ts) => left + w * ((ts.millisecondsSinceEpoch - t0) / span);

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [-10.0, 0.0, 10.0]) {
      if (v < lo || v > hi) continue;
      final yy = y(v);
      if (v == 0) {
        // dashed zero line
        for (var xx = left; xx < left + w; xx += 8) {
          canvas.drawLine(Offset(xx, yy), Offset(math.min(xx + 4, left + w), yy), gp..strokeWidth = 1.4);
        }
        gp.strokeWidth = 1;
      } else {
        canvas.drawLine(Offset(left, yy), Offset(left + w, yy), gp);
      }
      _text(canvas, '${v > 0 ? '+' : ''}${v.toStringAsFixed(0)}', Offset(left - 6, yy), right: true);
    }
    _text(canvas, 'SNR dB', Offset(4, 6));

    // Heard points as a line + soft fill.
    final heard = [for (final p in points) if (p.snr != null) p];
    if (heard.length >= 2) {
      final path = Path()..moveTo(x(heard.first.ts), y(heard.first.snr!));
      for (final p in heard.skip(1)) {
        path.lineTo(x(p.ts), y(p.snr!));
      }
      final fill = Path.from(path)
        ..lineTo(x(heard.last.ts), top + h)
        ..lineTo(x(heard.first.ts), top + h)
        ..close();
      canvas.drawPath(
          fill,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [line.withValues(alpha: 0.30), line.withValues(alpha: 0.02)],
            ).createShader(Rect.fromLTWH(left, top, w, h)));
      canvas.drawPath(
          path,
          Paint()
            ..color = line.withValues(alpha: 0.85)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.6
            ..strokeJoin = StrokeJoin.round);
    }
    final dotR = points.length > 400 ? 1.6 : 3.0;
    for (final p in points) {
      if (p.snr != null) {
        canvas.drawCircle(Offset(x(p.ts), y(p.snr!)), dotR, Paint()..color = m.forPing(heard: true, snr: p.snr));
      } else {
        final xx = x(p.ts);
        canvas.drawLine(
            Offset(xx, top + h - 7),
            Offset(xx, top + h),
            Paint()
              ..color = (p.heard ? m.snrMid : m.silent).withValues(alpha: 0.9)
              ..strokeWidth = 2);
      }
    }
    canvas.drawLine(Offset(left, top + h), Offset(left + w, top + h), gp);
    _text(canvas, formatTime(points.first.ts).substring(0, 5), Offset(left, size.height - 8));
    _text(canvas, formatTime(points.last.ts).substring(0, 5), Offset(left + w, size.height - 8), right: true);
    _text(canvas, 'red ticks = heard nothing', Offset(left + w / 2, size.height - 8), center: true);
  }

  @override
  bool shouldRepaint(_SnrPainter old) => old.points != points || old.m != m || old.line != line;
}

class _Hops extends StatelessWidget {
  final Map<int, int> hops;
  const _Hops({required this.hops});
  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final c = Theme.of(context).colorScheme;
    final parts = <(String, int, Color)>[
      ('Direct', hops[1] ?? 0, m.snrStrong),
      ('2 hops', hops[2] ?? 0, m.snrMid),
      ('3+ hops', hops[3] ?? 0, m.snrWeak),
      ('Unknown', hops[0] ?? 0, c.outline),
    ];
    final total = parts.fold<int>(0, (n, p) => n + p.$2);
    return _Panel(
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
              if (x.bestSnr != null) 'best ${x.bestSnr!.toStringAsFixed(1)} dB',
              if (x.farthestM != null) 'up to ${formatDistance(x.farthestM!)}',
              if (name != null) x.id,
            ].join(' · ');
            return Padding(
              key: ValueKey('report-rep-${x.id}'),
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(children: [
                SizedBox(
                  width: 28,
                  child: Text('${i + 1}',
                      style: numberStyle(context, size: 22, color: i < 3 ? m.beacon : t.colorScheme.onSurfaceVariant)),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      Text(name ?? x.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                      if (x.isNew && report.earlierDrives > 0)
                        _Tag('NEW', m.beacon, key: ValueKey('report-new-${x.id}')),
                      if (x.unknownToCmat) _Tag('not on MeshSonar', t.colorScheme.tertiary, key: ValueKey('report-unknown-${x.id}')),
                    ]),
                    if (details.isNotEmpty) Text(details, style: t.textTheme.bodySmall),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: x.timesHeard / max, minHeight: 5, color: m.beacon),
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
              Text('${c.centerLat.toStringAsFixed(4)}, ${c.centerLon.toStringAsFixed(4)}',
                  style: Theme.of(context).textTheme.labelSmall),
            ]),
          ),
        );
    final b = report.bestCell, w = report.worstCell;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (b != null)
        card('report-best-spot', 'Best spot', Icons.trending_up, b, m.snrStrong,
            b.bestSnr == null ? 'SNR not measured' : 'Best SNR ${b.bestSnr!.toStringAsFixed(1)} dB'),
      if (b != null && w != null) const SizedBox(width: 8),
      if (w != null)
        card('report-worst-spot', 'Dead spot', Icons.trending_down, w, m.silent,
            '${w.pings - w.heard} ping${w.pings - w.heard == 1 ? '' : 's'} unanswered'),
    ]);
  }
}
