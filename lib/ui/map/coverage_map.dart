// CoverageMap: the live wardrive map, reusable on the Drive screen, the full-screen map and the drive detail screen.
//
// Usage:
//   CoverageMap(
//     pings: pings,                       // every ping to draw, any order (dots coloured by result or SNR)
//     repeaters: state.repeaters,         // RepeaterRef cache: amber beacon markers, name on tap
//     position: LatLng(fix.lat, fix.lon), // optional "you are here"; follow mode keeps it centred
//     repeaterLabel: state.repeaterLabel, // optional: prefix -> display name for the link labels
//     heard: heardSnapshot(state.heard),  // optional: live/holding/stale repeaters (Drive screen)
//     layers: const MapLayers(),          // optional: which layers to draw
//   )
//
// Live drive: pass `position` and leave `follow: true`. Dragging the map turns follow off and shows a
// Recenter button. Drive detail: pass `follow: false, fitToPings: true` to frame the whole drive.
//
// What's drawn, bottom to top:
//   1. A chart grid on the map background (so the map looks intentional with no tiles / no signal).
//   2. OpenStreetMap tiles (colour-graded to the theme; cached; failures fall back to the grid, never an error).
//   3. Sonar range rings (1 km, 2 km) around the current position.
//   4. Links. With [heard]: from the current position to every LIVE heard repeater with a known location, solid
//      when heard on the latest ping, dashed while it is holding, each with a distance label. Without [heard]:
//      from the latest ping to each repeater it heard; they fade over ~15 s.
//   5. Repeaters (amber beacons). Heard ones pop up and glow while live, then grey out when stale. Tap for the name.
//   6. Ping dots: heard = blue→teal→green by best SNR (-10 → +10 dB) or plain green in "result" mode; heard nothing
//      = red. The newest dot pulses once.
//   7. Current position.
//
// Efficiency: inputs are snapshots taken once per ping (the heard list, the ping list); derived lists (sorted pings,
// the repeater marker set) are memoised on input identity, so a rebuild between pings costs nothing new. Markers are
// culled to the visible bounds by flutter_map's MarkerLayer.
//
// Widget keys (for tests): 'map-ping-<pingId>' (the dot: a DecoratedBox whose BoxDecoration.color is the result),
// 'map-repeater-<key>' (+ 'map-repeater-state-<key>-<fresh|holding|stale|idle>'), 'map-repeater-label',
// 'map-heard-label-<key>', 'map-link-distance-<key>', 'map-position', 'map-recenter', 'map-compass', 'map-offline',
// 'map-attribution', 'map-simulated'.
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../core/heard.dart' show haversineM;
import '../../core/model.dart';
import '../theme.dart';
import '../widgets.dart';
import 'map_layers.dart';

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
Color pingColor(MeshSonarColors c, DrivePing p, [PingColorMode mode = PingColorMode.snr]) =>
    mode == PingColorMode.result
    ? (p.heardNothing ? c.silent : c.snrStrong)
    : c.forPing(heard: !p.heardNothing, snr: bestSnr(p));

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

  /// Allow two-finger rotation; shows a compass that turns the map back to north-up.
  final bool rotatable;

  /// Load OpenStreetMap tiles. Defaults to on, except under `flutter test` (no network, no plugins there).
  final bool? showTiles;

  /// Prefix -> display name (falls back to the repeater's cached name).
  final String Function(String prefix)? repeaterLabel;

  /// Map used when there's nothing else to centre on (Columbus, Ohio).
  final LatLng fallbackCenter;

  /// Extra space at the edges for overlays drawn on top of the map by the parent (e.g. a chip row).
  final EdgeInsets overlayPadding;

  /// Who's in range this drive (live first). When set, repeater markers and links follow it.
  final List<HeardView>? heard;

  /// Which layers to draw.
  final MapLayers layers;

  /// Repeater (map key) to highlight and bring into view, e.g. tapped in the heard box.
  final String? highlightKey;

  /// Called when a repeater marker is tapped (null = selection cleared).
  final ValueChanged<String?>? onSelectRepeater;

  /// Show the "SIMULATED GPS & RADIO" tag.
  final bool simulated;

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
    this.rotatable = false,
    this.showTiles,
    this.repeaterLabel,
    this.fallbackCenter = const LatLng(39.9612, -82.9988),
    this.overlayPadding = EdgeInsets.zero,
    this.heard,
    this.layers = const MapLayers(),
    this.highlightKey,
    this.onSelectRepeater,
    this.simulated = false,
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
  static final StrokePattern _dashed = StrokePattern.dashed(segments: const [10, 8]);
  final MapController _controller = MapController();
  bool _ready = false;
  late bool _follow = widget.follow;
  String? _selectedRepeater;
  bool _tilesFailing = false;
  int _tileErrors = 0;
  double _rotation = 0;

  // Memoised on input identity (see the header comment).
  List<DrivePing>? _sortedSrc;
  List<DrivePing> _sorted = const [];
  DrivePing? _latestCache;
  List<RepeaterRef>? _markerSrcRepeaters;
  List<HeardView>? _markerSrcHeard;
  List<RepeaterRef> _markerRepeaters = const [];
  Map<String, HeardView> _heardByKey = const {};

  DrivePing? get _latest {
    _ensureSorted();
    return _latestCache;
  }

  void _ensureSorted() {
    if (identical(_sortedSrc, widget.pings)) return;
    _sortedSrc = widget.pings;
    // Oldest first so the newest dots are on top.
    _sorted = List.of(widget.pings)..sort((a, b) => a.ts.compareTo(b.ts));
    DrivePing? l;
    for (final p in widget.pings) {
      if (l == null || p.ts.isAfter(l.ts) || (p.ts == l.ts && p.id != l.id && identical(p, widget.pings.first))) l = p;
    }
    _latestCache = l;
  }

  void _ensureMarkers() {
    if (identical(_markerSrcRepeaters, widget.repeaters) && identical(_markerSrcHeard, widget.heard)) return;
    _markerSrcRepeaters = widget.repeaters;
    _markerSrcHeard = widget.heard;
    final byKey = <String, HeardView>{};
    final extra = <RepeaterRef>[];
    final known = {for (final r in widget.repeaters) r.key};
    for (final h in widget.heard ?? const <HeardView>[]) {
      final ref = h.ref;
      if (ref == null) continue;
      byKey.putIfAbsent(ref.key, () => h);
      // Heard repeaters found in another directory (not CMAT's list) still get a marker.
      if (known.add(ref.key)) extra.add(ref);
    }
    _heardByKey = byKey;
    _markerRepeaters = extra.isEmpty ? widget.repeaters : [...widget.repeaters, ...extra];
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
      maxZoom: 15.5, // a short drive should still show its streets, not upscaled blurry tiles
    );
  }

  @override
  void initState() {
    super.initState();
    _selectedRepeater = widget.highlightKey;
  }

  @override
  void didUpdateWidget(CoverageMap old) {
    super.didUpdateWidget(old);
    if (old.follow != widget.follow) _follow = widget.follow;
    if (old.highlightKey != widget.highlightKey) {
      _selectedRepeater = widget.highlightKey;
      if (widget.highlightKey != null) _focusRepeater(widget.highlightKey!);
      return;
    }
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

  RepeaterRef? _refFor(String key) {
    _ensureMarkers();
    for (final r in _markerRepeaters) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// Frames the repeater together with where we are (stops following until Recenter).
  void _focusRepeater(String key) {
    final r = _refFor(key);
    if (r == null || !_ready) return;
    final here = widget.position ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    final pts = [LatLng(r.lat, r.lon), ?here];
    _follow = false;
    if (pts.length == 1) {
      _controller.move(pts.single, math.max(_controller.camera.zoom, 13));
    } else {
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: pts,
          padding: const EdgeInsets.fromLTRB(115, 150, 115, 70) + widget.overlayPadding,
          maxZoom: 15,
        ),
      );
    }
  }

  void _recenter() {
    setState(() => _follow = true);
    final target = widget.position ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    if (target != null && _ready) {
      _controller.move(target, math.max(_controller.camera.zoom, 14));
    }
  }

  void _northUp() {
    if (!_ready) return;
    _controller.rotate(0);
    setState(() => _rotation = 0);
  }

  void _select(String? key) {
    setState(() => _selectedRepeater = key);
    widget.onSelectRepeater?.call(key);
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
    final layers = widget.layers;
    _ensureSorted();
    _ensureMarkers();
    final latest = _latestCache;
    final pos = widget.position;
    final heardMode = widget.heard != null;
    final showLinks = widget.showLinks && layers.links;

    // Legacy links (no heard list): from the newest ping to what it heard.
    final links = (!heardMode && showLinks && latest != null)
        ? linksFor(latest, widget.repeaters)
        : const <PingLink>[];
    final legacyLit = {for (final l in links) l.repeater.key};

    // Heard links: from here to every live heard repeater with a known position.
    final origin = pos ?? (latest == null ? null : LatLng(latest.lat, latest.lon));
    final liveLinks = <HeardView>[
      if (heardMode && showLinks && origin != null)
        for (final h in widget.heard!)
          if (h.live && h.ref != null) h,
    ];

    RepeaterRef? selected;
    if (_selectedRepeater != null) selected = _refFor(_selectedRepeater!);

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
              flags: !widget.interactive
                  ? InteractiveFlag.none
                  : (widget.rotatable ? InteractiveFlag.all : (InteractiveFlag.all & ~InteractiveFlag.rotate)),
            ),
            onMapReady: () {
              _ready = true;
              if (_selectedRepeater != null && widget.highlightKey == _selectedRepeater) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _focusRepeater(_selectedRepeater!);
                });
              }
            },
            onPositionChanged: (camera, hasGesture) {
              final rot = camera.rotation;
              final rotChanged = widget.rotatable && (rot - _rotation).abs() > 0.5;
              if ((hasGesture && _follow) || rotChanged) {
                setState(() {
                  if (hasGesture) _follow = false;
                  _rotation = rot;
                });
              }
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
            if (widget.showRings && layers.rings && pos != null) _RangeRings(center: pos, color: t.colorScheme.primary),
            if (widget.showRings && layers.rings && pos != null)
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
            if (liveLinks.isNotEmpty)
              PolylineLayer(
                polylines: [
                  for (final h in liveLinks)
                    Polyline(
                      points: [origin!, LatLng(h.ref!.lat, h.ref!.lon)],
                      strokeWidth: h.phase == HeardPhase.fresh ? 3 : 2,
                      pattern: h.phase == HeardPhase.fresh
                          ? const StrokePattern.solid()
                          : _dashed,
                      gradientColors: h.phase == HeardPhase.fresh
                          ? [mc.forPing(heard: true, snr: h.snrDb), mc.beacon.withValues(alpha: 0.85)]
                          : null,
                      color: h.phase == HeardPhase.fresh ? Colors.transparent : mc.beacon.withValues(alpha: 0.45),
                    ),
                ],
              ),
            if (layers.repeaters)
              MarkerLayer(
                markers: [
                  for (final r in _markerRepeaters)
                    Marker(
                      point: LatLng(r.lat, r.lon),
                      width: 56,
                      height: 56,
                      child: _RepeaterMarker(
                        key: ValueKey('map-repeater-${r.key}'),
                        repeaterKey: r.key,
                        color: mc.beacon,
                        onColor: mc.onBeacon,
                        greyColor: t.colorScheme.outline,
                        phase: heardMode ? _heardByKey[r.key]?.phase : (legacyLit.contains(r.key) ? HeardPhase.fresh : null),
                        heardAt: _heardByKey[r.key]?.lastPingIndex,
                        selected: r.key == _selectedRepeater,
                        onTap: () => _select(_selectedRepeater == r.key ? null : r.key),
                      ),
                    ),
                ],
              ),
            if (layers.pings)
              MarkerLayer(
                markers: [
                  for (final p in _sorted)
                    Marker(
                      point: LatLng(p.lat, p.lon),
                      width: 40,
                      height: 40,
                      child: IgnorePointer(
                        child: _PingDot(
                          dotKey: ValueKey('map-ping-${p.id}'),
                          color: pingColor(mc, p, layers.pingColors),
                          ring: t.colorScheme.surface,
                          pulse: identical(p, latest) || p.id == latest?.id,
                        ),
                      ),
                    ),
                ],
              ),
            if (liveLinks.isNotEmpty)
              MarkerLayer(
                markers: [
                  for (final h in liveLinks)
                    Marker(
                      point: LatLng(
                        (origin!.latitude + h.ref!.lat) / 2,
                        (origin.longitude + h.ref!.lon) / 2,
                      ),
                      width: 80,
                      height: 24,
                      child: IgnorePointer(
                        child: Center(
                          child: _MapTag(
                            key: ValueKey('map-link-distance-${h.ref!.key}'),
                            text: formatDistance(haversineM(origin.latitude, origin.longitude, h.ref!.lat, h.ref!.lon)),
                            color: h.phase == HeardPhase.fresh ? mc.beacon : t.colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            if (layers.repeaters && heardMode)
              MarkerLayer(
                markers: [
                  for (final h in widget.heard!)
                    if (h.live && h.ref != null && h.ref!.key != _selectedRepeater)
                      Marker(
                        point: LatLng(h.ref!.lat, h.ref!.lon),
                        width: 150,
                        height: 22,
                        alignment: const Alignment(0, 2.6),
                        child: IgnorePointer(
                          child: Center(
                            child: _MapTag(
                              key: ValueKey('map-heard-label-${h.ref!.key}'),
                              text: h.snrDb == null ? h.label : '${h.label}  ${formatSnrShort(h.snrDb!)}',
                              color: h.phase == HeardPhase.fresh ? mc.beacon : t.colorScheme.outline,
                              strong: h.phase == HeardPhase.fresh,
                            ),
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
                    height: 104,
                    alignment: Alignment.topCenter,
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 30),
                        child: _RepeaterLabel(
                          onTap: () => _select(null),
                          name: _nameFor(selected),
                          keyHex: selected.key,
                          detail: _detailFor(selected, origin),
                          color: mc.beacon,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        // Attribution (required by the OSM tile licence), the offline note and the simulator tag.
        Positioned(
          left: Gap.s + widget.overlayPadding.left,
          bottom: Gap.s + widget.overlayPadding.bottom,
          right: 72 + widget.overlayPadding.right,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.simulated) ...[
                const SimulatedTag(key: Key('map-simulated')),
                const SizedBox(height: Gap.xs),
              ],
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
        Positioned(
          right: Gap.m + widget.overlayPadding.right,
          bottom: Gap.m + widget.overlayPadding.bottom,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.rotatable) ...[
                _Compass(rotation: _rotation, onPressed: _northUp),
                const SizedBox(height: Gap.s),
              ],
              if (!_follow && (pos != null || latest != null))
                FloatingActionButton.small(
                  key: const Key('map-recenter'),
                  heroTag: null,
                  tooltip: 'Recenter and follow',
                  onPressed: _recenter,
                  child: const Icon(Icons.my_location_rounded),
                ),
            ],
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

  /// "Heard 2 pings ago · +4.5 dB · 2.3 km", or just the distance for a repeater not heard this drive.
  String? _detailFor(RepeaterRef r, LatLng? here) {
    final h = _heardByKey[r.key];
    final parts = <String>[];
    if (h != null) {
      parts.add(h.pingsAgo == 0 ? 'Heard now' : (h.live ? 'Heard ${h.pingsAgo} ping${h.pingsAgo == 1 ? '' : 's'} ago' : 'Not heard lately'));
      if (h.snrDb != null) parts.add('${formatSnrShort(h.snrDb!)} dB');
    }
    if (here != null) parts.add(formatDistance(haversineM(here.latitude, here.longitude, r.lat, r.lon)));
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static LatLng _offsetNorth(LatLng p, double metres) => LatLng(p.latitude + metres / 111320.0, p.longitude);
}

/// The small "this isn't real" tag shown on the map and the connection chip in Simulator mode.
class SimulatedTag extends StatelessWidget {
  final bool dense;
  const SimulatedTag({super.key, this.dense = false});
  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    return Tooltip(
      message: 'Simulator mode: the position moves along a demo route and the radio is simulated.',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: mc.beacon.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: dense ? 4 : 7, vertical: dense ? 1 : 3),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.science_rounded, size: dense ? 10 : 13, color: mc.onBeacon),
              SizedBox(width: dense ? 2 : 4),
              Text(
                'SIMULATED GPS & RADIO',
                style: t.textTheme.labelSmall?.copyWith(
                  color: mc.onBeacon,
                  fontSize: dense ? 9 : 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.6,
                  height: 1.1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Compass extends StatelessWidget {
  final double rotation;
  final VoidCallback onPressed;
  const _Compass({required this.rotation, required this.onPressed});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final northUp = rotation.abs() < 0.5;
    return FloatingActionButton.small(
      key: const Key('map-compass'),
      heroTag: null,
      tooltip: northUp ? 'North up' : 'Turn map north up',
      onPressed: onPressed,
      child: Transform.rotate(
        angle: rotation * math.pi / 180,
        child: Icon(Icons.navigation_rounded, color: northUp ? t.colorScheme.onSurface : t.colorScheme.error),
      ),
    );
  }
}

/// A small text pill drawn on the map (distance on a link, a heard repeater's name).
class _MapTag extends StatelessWidget {
  final String text;
  final Color color;
  final bool strong;
  const _MapTag({super.key, required this.text, required this.color, this.strong = false});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: t.colorScheme.surface.withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withValues(alpha: strong ? 0.9 : 0.5), width: strong ? 1.4 : 1),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: numberStyle(
            context,
            size: 12.5,
            weight: FontWeight.w600,
            color: strong ? t.colorScheme.onSurface : t.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
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

/// A repeater beacon. [phase] null = not heard this drive (dim amber); fresh = pops up and glows; holding = lit,
/// no glow; stale = greyed out. [heardAt] changes every time it's heard again, which replays the pop-up.
class _RepeaterMarker extends StatelessWidget {
  final String repeaterKey;
  final Color color;
  final Color onColor;
  final Color greyColor;
  final HeardPhase? phase;
  final int? heardAt;
  final bool selected;
  final VoidCallback onTap;
  const _RepeaterMarker({
    super.key,
    required this.repeaterKey,
    required this.color,
    required this.onColor,
    required this.greyColor,
    required this.phase,
    required this.heardAt,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    final fresh = phase == HeardPhase.fresh;
    final holding = phase == HeardPhase.holding;
    final stale = phase == HeardPhase.stale;
    final big = fresh || holding || selected;
    final size = fresh ? 32.0 : (big ? 28.0 : 22.0);
    final Color fill = stale
        ? Color.alphaBlend(greyColor.withValues(alpha: 0.55), surface)
        : (big ? color : Color.alphaBlend(color.withValues(alpha: 0.7), Colors.black));
    final diamond = Transform.rotate(
      angle: math.pi / 4,
      child: Container(
        key: ValueKey('map-repeater-state-$repeaterKey-${phase?.name ?? 'idle'}'),
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? Theme.of(context).colorScheme.onSurface : surface, width: 2),
          boxShadow: fresh
              ? [BoxShadow(color: color.withValues(alpha: 0.7), blurRadius: 16, spreadRadius: 2)]
              : (holding ? [BoxShadow(color: color.withValues(alpha: 0.3), blurRadius: 8)] : null),
        ),
        child: Transform.rotate(
          angle: -math.pi / 4,
          child: Icon(Icons.cell_tower_rounded, size: big ? 18 : 13, color: stale ? surface : onColor),
        ),
      ),
    );
    Widget child = Center(child: diamond);
    if (fresh) {
      // Pop up and send one ring out each time it's heard.
      child = TweenAnimationBuilder<double>(
        key: ValueKey('pop-$heardAt'),
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 1100),
        builder: (context, v, d) {
          final scale = v < 0.35 ? 0.6 + 0.75 * Curves.easeOut.transform(v / 0.35) : 1.35 - 0.35 * Curves.easeInOut.transform((v - 0.35) / 0.65);
          return Stack(
            alignment: Alignment.center,
            children: [
              if (v < 1)
                Container(
                  width: 30 + 26 * v,
                  height: 30 + 26 * v,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: (1 - v) * 0.9), width: 2.5),
                  ),
                ),
              Transform.scale(scale: scale, child: d),
            ],
          );
        },
        child: diamond,
      );
    }
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child);
  }
}

class _RepeaterLabel extends StatelessWidget {
  final String name;
  final String keyHex;
  final String? detail;
  final Color color;
  final VoidCallback onTap;
  const _RepeaterLabel({required this.name, required this.keyHex, this.detail, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final box = Container(
      key: const Key('map-repeater-label'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
          Text(
            detail == null ? keyHex.substring(0, math.min(8, keyHex.length)) : '${keyHex.substring(0, math.min(4, keyHex.length))} · $detail',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: t.textTheme.labelSmall,
          ),
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
      old.camera.rotation != camera.rotation ||
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
