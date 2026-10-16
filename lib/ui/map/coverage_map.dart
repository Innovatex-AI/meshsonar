// CoverageMap: the live wardrive map, reusable on the Drive screen and the drive detail screen.
//
// Usage:
//   CoverageMap(
//     pings: pings,                       // every ping to draw, any order (dots coloured by result)
//     repeaters: state.repeaters,         // RepeaterRef cache: amber beacon markers, name on tap
//     position: LatLng(fix.lat, fix.lon), // optional "you are here"; follow mode keeps it centred
//     repeaterLabel: state.repeaterLabel, // optional: prefix -> display name for the link labels
//   )
//
// Live drive: pass `position` and leave `follow: true`. Dragging the map turns follow off and shows a
// Recenter button. Drive detail: pass `follow: false, fitToPings: true` to frame the whole drive.
//
// What's drawn, bottom to top:
//   1. A chart grid on the map background (so the map looks intentional with no tiles / no signal).
//   2. OpenStreetMap tiles (colour-graded to the theme; cached; failures fall back to the grid, never an error).
//   3. Sonar range rings (1 km, 2 km) around the current position.
//   4. Links from the LATEST ping to each repeater it heard (that we know the location of); they fade over ~15 s.
//   5. Repeaters (amber beacons). Tap one for its name.
//   6. Ping dots: heard = blue→teal→green by best SNR (-10 → +10 dB); heard nothing = red. The newest dot pulses once.
//   7. Current position.
//
// Widget keys (for tests): 'map-ping-<pingId>' (the dot: a DecoratedBox whose BoxDecoration.color is the result),
// 'map-repeater-<key>', 'map-repeater-label', 'map-position', 'map-recenter', 'map-offline', 'map-attribution'.
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/model.dart';
import '../theme.dart';
import '../widgets.dart';

/// A line from a ping to a repeater it heard.
class PingLink {
  final RepeaterRef repeater;
  final double? snr;
  const PingLink(this.repeater, this.snr);
}

/// The cached repeater whose key starts with [prefix], if exactly one matches (prefixes can be 1 byte, so ambiguous
/// matches are skipped rather than guessed).
RepeaterRef? resolveRepeater(List<RepeaterRef> repeaters, String prefix) {
  final p = prefix.toLowerCase();
  if (p.isEmpty) return null;
  RepeaterRef? hit;
  for (final r in repeaters) {
    if (r.key.startsWith(p)) {
      if (hit != null) return null;
      hit = r;
    }
  }
  return hit;
}

/// Links from [ping] to every repeater it heard that has a known location, with that repeater's SNR.
List<PingLink> linksFor(DrivePing ping, List<RepeaterRef> repeaters) {
  final best = <String, double?>{};
  void add(String rep, double? snr) {
    final k = rep.toLowerCase();
    final cur = best[k];
    if (!best.containsKey(k) || (snr != null && (cur == null || snr > cur))) best[k] = snr;
  }

  for (final e in ping.echoes) {
    add(e.repeater, e.snrDb);
  }
  if (ping.neighbor != null) add(ping.neighbor!.repeater, ping.neighbor!.localSnrDb);
  final out = <PingLink>[];
  final seen = <String>{};
  for (final e in best.entries) {
    final r = resolveRepeater(repeaters, e.key);
    if (r != null && seen.add(r.key)) out.add(PingLink(r, e.value));
  }
  return out;
}

/// The colour a ping is drawn in.
Color pingColor(MeshSonarColors c, DrivePing p) => c.forPing(heard: !p.heardNothing, snr: bestSnr(p));

class CoverageMap extends StatefulWidget {
  /// Pings to draw. Order doesn't matter; the newest (by timestamp) gets the links and the pulse.
  final List<DrivePing> pings;

  /// Known repeaters (from the CMAT repeater cache).
  final List<RepeaterRef> repeaters;

  /// Current position, if known.
  final LatLng? position;

  /// Keep [position] centred (until the user drags the map).
  final bool follow;

  /// Frame all pings when the map first opens (drive detail). Ignored if there are fewer than 2 pings.
  final bool fitToPings;

  /// Draw links from the newest ping to the repeaters it heard.
  final bool showLinks;

  /// Sonar range rings around [position].
  final bool showRings;

  /// Allow pan/zoom.
  final bool interactive;

  /// Load OpenStreetMap tiles. Defaults to on, except under `flutter test` (no network, no plugins there).
  final bool? showTiles;

  /// Prefix -> display name (falls back to the repeater's cached name).
  final String Function(String prefix)? repeaterLabel;

  /// Map used when there's nothing else to centre on (Columbus, Ohio).
  final LatLng fallbackCenter;

  /// Extra space at the edges for overlays drawn on top of the map by the parent (e.g. a chip row).
  final EdgeInsets overlayPadding;

  const CoverageMap({
    super.key,
    required this.pings,
    this.repeaters = const [],
    this.position,
    this.follow = true,
    this.fitToPings = false,
    this.showLinks = true,
    this.showRings = true,
    this.interactive = true,
    this.showTiles,
    this.repeaterLabel,
    this.fallbackCenter = const LatLng(39.9612, -82.9988),
    this.overlayPadding = EdgeInsets.zero,
  });

  /// True unless running under `flutter test`.
  static bool tilesByDefault = () {
    try {
      return !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return true;
    }
  }();

  static const String tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackageName = 'net.innovatexit.meshsonar';

  @override
  State<CoverageMap> createState() => _CoverageMapState();
}

class _CoverageMapState extends State<CoverageMap> {
  final MapController _controller = MapController();
  bool _ready = false;
  late bool _follow = widget.follow;
  String? _selectedRepeater;
  bool _tilesFailing = false;
  int _tileErrors = 0;

  DrivePing? get _latest {
    DrivePing? l;
    for (final p in widget.pings) {
      if (l == null || p.ts.isAfter(l.ts) || (p.ts == l.ts && p.id != l.id && identical(p, widget.pings.first))) l = p;
    }
    return l;
  }

  LatLng get _initialCenter {
    if (widget.position != null) return widget.position!;
    final l = _latest;
    if (l != null) return LatLng(l.lat, l.lon);
    if (widget.repeaters.isNotEmpty) {
      var lat = 0.0, lon = 0.0;
      for (final r in widget.repeaters) {
        lat += r.lat;
        lon += r.lon;
      }
      return LatLng(lat / widget.repeaters.length, lon / widget.repeaters.length);
    }
    return widget.fallbackCenter;
  }

  double get _initialZoom {
    if (widget.position != null || widget.pings.isNotEmpty) return 13.6;
    if (widget.repeaters.isNotEmpty) return 11;
    return 10;
  }

  CameraFit? get _initialFit {
    if (!widget.fitToPings || widget.pings.length < 2) return null;
    return CameraFit.coordinates(
      coordinates: [for (final p in widget.pings) LatLng(p.lat, p.lon)],
      padding: const EdgeInsets.all(40) + widget.overlayPadding,
      maxZoom: 17,
    );
  }

  @override
  void didUpdateWidget(CoverageMap old) {
    super.didUpdateWidget(old);
    if (old.follow != widget.follow) _follow = widget.follow;
    final pos = widget.position;
    // First real location after opening on an overview: zoom in to street level.
    final firstFix =
        (old.position == null && pos != null) || (old.pings.isEmpty && widget.pings.isNotEmpty && pos == null);
    if (_follow && _ready && firstFix) {
      final target = pos ?? LatLng(_latest!.lat, _latest!.lon);
      _controller.move(target, math.max(_controller.camera.zoom, 13.6));
    } else if (_follow && _ready && pos != null && pos != old.position) {
      _controller.move(pos, _controller.camera.zoom);
    } else if (_follow && _ready && pos == null) {
      final l = _latest;
      final ol = old.pings.isEmpty ? null : old.pings.first;
      if (l != null && (ol == null || ol.id != l.id || old.pings.length != widget.pings.length)) {
        _controller.move(LatLng(l.lat, l.lon), _controller.camera.zoom);
      }
    }
  }

  void _recenter() {
    setState(() => _follow = true);
    final target = widget.position ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    if (target != null && _ready) {
      _controller.move(target, math.max(_controller.camera.zoom, 14));
    }
  }

  void _onTileError() {
    _tileErrors++;
    if (_tilesFailing || _tileErrors < 2) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tilesFailing) setState(() => _tilesFailing = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final tiles = widget.showTiles ?? CoverageMap.tilesByDefault;
    final latest = _latest;
    final links = (widget.showLinks && latest != null) ? linksFor(latest, widget.repeaters) : const <PingLink>[];
    final heardKeys = {for (final l in links) l.repeater.key};
    final pos = widget.position;

    // Oldest first so the newest dots are on top.
    final sorted = List.of(widget.pings)..sort((a, b) => a.ts.compareTo(b.ts));

    RepeaterRef? selected;
    if (_selectedRepeater != null) {
      for (final r in widget.repeaters) {
        if (r.key == _selectedRepeater) selected = r;
      }
    }

    return Stack(
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: _initialCenter,
            initialZoom: _initialZoom,
            initialCameraFit: _initialFit,
            minZoom: 3,
            maxZoom: 18,
            backgroundColor: mc.mapBackground,
            interactionOptions: InteractionOptions(
              flags: widget.interactive ? (InteractiveFlag.all & ~InteractiveFlag.rotate) : InteractiveFlag.none,
            ),
            onMapReady: () => _ready = true,
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            _ChartGrid(color: mc.mapGrid),
            if (tiles)
              TileLayer(
                urlTemplate: CoverageMap.tileUrl,
                userAgentPackageName: CoverageMap.userAgentPackageName,
                maxNativeZoom: 19,
                tileDisplay: const TileDisplay.fadeIn(),
                evictErrorTileStrategy: EvictErrorTileStrategy.notVisibleRespectMargin,
                errorTileCallback: (_, _, _) => _onTileError(),
                tileBuilder: (context, tile, _) =>
                    ColorFiltered(colorFilter: ColorFilter.matrix(mc.tileMatrix), child: tile),
              ),
            if (widget.showRings && pos != null) _RangeRings(center: pos, color: t.colorScheme.primary),
            if (widget.showRings && pos != null)
              MarkerLayer(
                markers: [
                  for (final m in const [1, 2])
                    Marker(
                      point: _offsetNorth(pos, -m * 1000.0),
                      width: 44,
                      height: 18,
                      child: Center(
                        child: Text(
                          '$m km',
                          style: t.textTheme.labelSmall?.copyWith(
                            color: t.colorScheme.primary.withValues(alpha: 0.8),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            if (links.isNotEmpty)
              TweenAnimationBuilder<double>(
                key: ValueKey('links-${latest!.id}'),
                tween: Tween(begin: 1, end: 0.28),
                duration: const Duration(seconds: 15),
                curve: Curves.easeIn,
                builder: (context, a, child) => Opacity(opacity: a, child: child),
                child: PolylineLayer(
                  polylines: [
                    for (final l in links)
                      Polyline(
                        points: [LatLng(latest.lat, latest.lon), LatLng(l.repeater.lat, l.repeater.lon)],
                        strokeWidth: 3,
                        gradientColors: [
                          mc.forPing(heard: true, snr: l.snr),
                          mc.beacon.withValues(alpha: 0.75),
                        ],
                      ),
                  ],
                ),
              ),
            MarkerLayer(
              markers: [
                for (final r in widget.repeaters)
                  Marker(
                    point: LatLng(r.lat, r.lon),
                    width: 44,
                    height: 44,
                    child: _RepeaterMarker(
                      key: ValueKey('map-repeater-${r.key}'),
                      color: mc.beacon,
                      onColor: mc.onBeacon,
                      lit: heardKeys.contains(r.key),
                      selected: r.key == _selectedRepeater,
                      onTap: () => setState(() => _selectedRepeater = _selectedRepeater == r.key ? null : r.key),
                    ),
                  ),
              ],
            ),
            MarkerLayer(
              markers: [
                for (final p in sorted)
                  Marker(
                    point: LatLng(p.lat, p.lon),
                    width: 40,
                    height: 40,
                    child: IgnorePointer(
                      child: _PingDot(
                        dotKey: ValueKey('map-ping-${p.id}'),
                        color: pingColor(mc, p),
                        ring: t.colorScheme.surface,
                        pulse: identical(p, latest) || p.id == latest?.id,
                      ),
                    ),
                  ),
              ],
            ),
            if (pos != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: pos,
                    width: 48,
                    height: 48,
                    child: IgnorePointer(
                      child: _PositionMarker(
                        key: const Key('map-position'),
                        color: t.colorScheme.primary,
                        ring: t.colorScheme.surface,
                      ),
                    ),
                  ),
                ],
              ),
            if (selected != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: LatLng(selected.lat, selected.lon),
                    width: 220,
                    height: 96,
                    alignment: Alignment.topCenter,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 26),
                        child: _RepeaterLabel(
                          onTap: () => setState(() => _selectedRepeater = null),
                          name: _nameFor(selected),
                          keyHex: selected.key,
                          color: mc.beacon,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        // Attribution (required by the OSM tile licence) and the offline note.
        Positioned(
          left: Gap.s + widget.overlayPadding.left,
          bottom: Gap.s + widget.overlayPadding.bottom,
          right: 72 + widget.overlayPadding.right,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_tilesFailing || !tiles) ...[
                _Pill(
                  key: const Key('map-offline'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_rounded, size: 13, color: mc.textMuted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          'Map offline. Pings still record.',
                          overflow: TextOverflow.ellipsis,
                          style: t.textTheme.labelSmall?.copyWith(fontSize: 11),
                        ),
                      ),
                    ],
                  ),
                ),
                if (tiles) const SizedBox(height: Gap.xs),
              ],
              if (tiles)
                _Pill(
                  key: const Key('map-attribution'),
                  child: Text('© OpenStreetMap contributors', style: t.textTheme.labelSmall?.copyWith(fontSize: 11)),
                ),
            ],
          ),
        ),
        if (!_follow && (pos != null || latest != null))
          Positioned(
            right: Gap.m + widget.overlayPadding.right,
            bottom: Gap.m + widget.overlayPadding.bottom,
            child: FloatingActionButton.small(
              key: const Key('map-recenter'),
              heroTag: null,
              tooltip: 'Recenter',
              onPressed: _recenter,
              child: const Icon(Icons.my_location_rounded),
            ),
          ),
      ],
    );
  }

  String _nameFor(RepeaterRef r) {
    if (r.name.isNotEmpty) return r.name;
    final l = widget.repeaterLabel;
    return l == null ? r.key.substring(0, math.min(8, r.key.length)) : l(r.key);
  }

  static LatLng _offsetNorth(LatLng p, double metres) => LatLng(p.latitude + metres / 111320.0, p.longitude);
}

class _Pill extends StatelessWidget {
  final Widget child;
  const _Pill({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.82),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), child: child),
    );
  }
}

class _PingDot extends StatelessWidget {
  final Key dotKey;
  final Color color;
  final Color ring;
  final bool pulse;
  const _PingDot({required this.dotKey, required this.color, required this.ring, required this.pulse});

  @override
  Widget build(BuildContext context) {
    final dot = DecoratedBox(
      key: dotKey,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: ring, width: 2),
      ),
      child: const SizedBox(width: 15, height: 15),
    );
    if (!pulse) return Center(child: dot);
    // One expanding ring when a ping lands (not repeating, so the map is calm between pings).
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 1400),
      curve: Curves.easeOutCubic,
      builder: (context, v, child) => Stack(
        alignment: Alignment.center,
        children: [
          if (v < 1)
            Container(
              width: 15 + 25 * v,
              height: 15 + 25 * v,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: color.withValues(alpha: 1 - v), width: 2.5),
              ),
            ),
          child!,
        ],
      ),
      child: dot,
    );
  }
}

class _PositionMarker extends StatelessWidget {
  final Color color;
  final Color ring;
  const _PositionMarker({super.key, required this.color, required this.ring});
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.18)),
        alignment: Alignment.center,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: color,
            border: Border.all(color: ring, width: 3),
            boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 6)],
          ),
        ),
      ),
    );
  }
}

class _RepeaterMarker extends StatelessWidget {
  final Color color;
  final Color onColor;
  final bool lit;
  final bool selected;
  final VoidCallback onTap;
  const _RepeaterMarker({
    super.key,
    required this.color,
    required this.onColor,
    required this.lit,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final big = lit || selected;
    final size = big ? 30.0 : 24.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Center(
        child: Transform.rotate(
          angle: math.pi / 4,
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: big ? color : Color.alphaBlend(color.withValues(alpha: 0.85), Colors.black),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Theme.of(context).colorScheme.surface, width: 2),
              boxShadow: lit ? [BoxShadow(color: color.withValues(alpha: 0.6), blurRadius: 12, spreadRadius: 1)] : null,
            ),
            child: Transform.rotate(
              angle: -math.pi / 4,
              child: Icon(Icons.cell_tower_rounded, size: big ? 18 : 14, color: onColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _RepeaterLabel extends StatelessWidget {
  final String name;
  final String keyHex;
  final Color color;
  final VoidCallback onTap;
  const _RepeaterLabel({required this.name, required this.keyHex, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final box = Container(
      key: const Key('map-repeater-label'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: t.colorScheme.surface,
        borderRadius: BorderRadius.circular(Corners.small),
        border: Border.all(color: color, width: 1.5),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 10)],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: t.textTheme.titleSmall),
          Text(keyHex.substring(0, math.min(8, keyHex.length)), style: t.textTheme.labelSmall),
        ],
      ),
    );
    return GestureDetector(onTap: onTap, child: box);
  }
}

/// A faint lat/lon grid that moves with the map: the "chart paper" you see when tiles can't load.
class _ChartGrid extends StatelessWidget {
  final Color color;
  const _ChartGrid({required this.color});
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(painter: _GridPainter(camera, color), size: Size.infinite),
    );
  }
}

class _GridPainter extends CustomPainter {
  final MapCamera camera;
  final Color color;
  _GridPainter(this.camera, this.color);

  static const _steps = [0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0];

  @override
  void paint(Canvas canvas, Size size) {
    final pxPerDeg = 256 * math.pow(2, camera.zoom) / 360;
    var step = _steps.last;
    for (final s in _steps) {
      if (s * pxPerDeg >= 70) {
        step = s;
        break;
      }
    }
    final b = camera.visibleBounds;
    final minor = Paint()
      ..color = color.withValues(alpha: 0.07)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = color.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    final west = b.west - step, east = b.east + step;
    final south = math.max(-85.0, b.south - step), north = math.min(85.0, b.north + step);
    var i = (south / step).floor();
    for (var lat = i * step; lat <= north; lat += step, i++) {
      final a = camera.latLngToScreenOffset(LatLng(lat, west.clamp(-180.0, 180.0)));
      final c = camera.latLngToScreenOffset(LatLng(lat, east.clamp(-180.0, 180.0)));
      canvas.drawLine(a, c, i % 5 == 0 ? major : minor);
    }
    var j = (west / step).floor();
    for (var lon = j * step; lon <= east; lon += step, j++) {
      final a = camera.latLngToScreenOffset(LatLng(south, lon));
      final c = camera.latLngToScreenOffset(LatLng(north, lon));
      canvas.drawLine(a, c, j % 5 == 0 ? major : minor);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.camera.center != camera.center ||
      old.camera.zoom != camera.zoom ||
      old.color != color ||
      old.camera.size != camera.size;
}

/// Dashed range rings (1 km, 2 km) around the current position, drawn directly so they stay crisp at any zoom.
class _RangeRings extends StatelessWidget {
  final LatLng center;
  final Color color;
  const _RangeRings({required this.center, required this.color});
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(painter: _RingPainter(camera, center, color), size: Size.infinite),
    );
  }
}

class _RingPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng center;
  final Color color;
  _RingPainter(this.camera, this.center, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = camera.latLngToScreenOffset(center);
    for (final m in const [1000.0, 2000.0]) {
      final edge = camera.latLngToScreenOffset(LatLng(center.latitude + m / 111320.0, center.longitude));
      final r = (c - edge).distance;
      if (r < 6 || r > 6000) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: m == 1000 ? 0.55 : 0.35);
      // Dashes: ~60 per ring, capped so small rings stay readable.
      final n = (2 * math.pi * r / 14).clamp(24, 160).round();
      for (var i = 0; i < n; i++) {
        final a0 = 2 * math.pi * i / n;
        canvas.drawArc(Rect.fromCircle(center: c, radius: r), a0, math.pi / n, false, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.center != center ||
      old.color != color ||
      old.camera.center != camera.center ||
      old.camera.zoom != camera.zoom;
}
