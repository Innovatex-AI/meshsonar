// Network > Map: the live packet map with replay (AZ-3.3; website twin `/map?panel=live`, a packet's replay link
// `/map?panel=live&t=<time>&packet=<hash>`). On the app's one map stack (MapPreview: our basemap, the Map Definition,
// the credit line), packets are drawn as they propagate, origin to relays to observers, in the packet type colours
// (packet_type_colors.dart, the website's palette): solid for unique hops, dashed for likely ones, faint grey ghost
// segments with ghost marks for hops nobody can place (never a certain line through them), dotted for the route
// still ahead of a direct packet.
//
// One panel at the bottom (design/map_panel.dart, id `live.main`), collapsed on a phone: its header is the whole chrome
// of the map (status dot and wording, packet count, pause / play). Open, it holds the notes that say honestly where the
// packets come from, the scrubber with packet density over the chosen window (dropping it replays from that time), the
// window, speed 0.25x to 8x, jump to live, Filters (a modal form: type, observer, My nodes) and the feed. A packet drawn
// on the map is the transient panel `live.focus` above it. Nothing sits at the top of the map.
//
// Battery: the stream is dropped and nothing animates while the section is off screen (TickerMode), the app is in
// the background, or the battery mode is Saver (a banner offers "Show anyway" for this view); frames are capped at
// the battery profile's map frame rate and the ticker sleeps when nothing moves.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/power_profile.dart';
import '../../../core/region_lookup.dart';
import '../../../core/v1/live_api.dart';
import '../../../core/v1/live_geometry.dart';
import '../../../core/v1/live_replay.dart';
import '../../../core/v1/network_api.dart' show NetworkReadSource;
import '../../../core/v1/nodes_api.dart' show nodesApiFactory;
import '../../../core/v1/packets_api.dart' show packetsApiFactory, packetTypeLabel, packetTypeWireName;
import '../../app.dart';
import '../../design/app_surfaces.dart' show showAppSheet;
import '../../design/map_panel.dart';
import '../../design/tokens.dart';
import '../../map/layers/repeater_map_source.dart' show kRosterLayerId;
import '../../map/main_map_focus.dart';
import '../../map/map_preview.dart';
import '../network_context.dart';
import '../packets/packet_detail_screen.dart';
import '../packets/packet_ui.dart' show ageText, snrText;
import 'live_map_controller.dart';
import 'packet_type_colors.dart';

/// The middle of a region's box; null without one.
LatLng? regionCentre(RegionIndexEntry r) {
  final b = r.bbox;
  if (b == null || b.length != 4) return null;
  return LatLng((b[1] + b[3]) / 2, (b[0] + b[2]) / 2);
}

/// The layers the full map shows for the network (the toolbar's "Open the full map").
const Set<String> networkMapLayers = {kRosterLayerId, 'observers', 'snrlinks', 'estimated'};

/// "14:02:05" in the phone's time.
String clockText(DateTime t) {
  final l = t.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

const Map<String, String> _windowLabels = {'1h': '1 h', '6h': '6 h', '24h': '24 h', '7d': '7 d', '30d': '30 d'};

class NetworkLiveMap extends StatefulWidget {
  final RegionIndexEntry region;

  /// The request that opened the map (a packet to draw, a time); null = plain live.
  final NetworkRequest? request;

  /// Test seams.
  final LiveMapController? controller;
  final bool showBasemap;
  const NetworkLiveMap({super.key, required this.region, this.request, this.controller, this.showBasemap = true});

  @override
  State<NetworkLiveMap> createState() => _NetworkLiveMapState();
}

class _NetworkLiveMapState extends State<NetworkLiveMap> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final LiveMapController _c;
  late final Ticker _ticker;
  final MapController _map = MapController();
  bool _mapReady = false;
  Duration _lastFrame = Duration.zero, _lastTick = Duration.zero;
  bool _foreground = true, _visible = true, _saverOverride = false;
  NetworkFavouritesStore? _favs;
  final Map<String, GeoPoint> _observerPos = {};
  String? _focusError;

  /// One open panel on this map; the Live panel's resting height (the drawn packet sits on top of it).
  final MapPanelGroup _panels = MapPanelGroup();
  double? _mainExtent;

  bool get _saver => PowerProfile.current.mode == BatteryMode.saver;
  bool get _active => _foreground && _visible && (!_saver || _saverOverride);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c = widget.controller ?? LiveMapController(baseUrl: widget.region.url, regionSlug: widget.region.slug);
    _c.addListener(_changed);
    _ticker = createTicker(_onTick);
    PowerProfile.addListener(_powerChanged);
    _c.start();
    unawaited(_loadObservers());
    final r = widget.request;
    if (r?.packetHash != null) unawaited(_loadFocus(r!.packetHash!, r.mapTime));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final v = TickerMode.valuesOf(context).enabled;
    if (v != _visible) _visible = v;
    final f = networkFavourites(context);
    if (!identical(f, _favs)) {
      _favs?.removeListener(_favsChanged);
      _favs = f..addListener(_favsChanged);
    }
    _c.setMyNodes(myNodesOf(context));
    _updatePositions();
    _sync();
  }

  void _favsChanged() {
    if (mounted) _c.setMyNodes(myNodesOf(context));
  }

  void _powerChanged() {
    if (mounted) setState(_sync);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  void _sync() {
    _c.setActive(_active);
    _wake();
  }

  void _changed() {
    if (!mounted) return;
    _wake();
    setState(() {});
  }

  /// Runs the ticker only while something moves (it sleeps when idle).
  void _wake() {
    final need = _active && (_c.animating || _c.mode == LiveMode.replay);
    if (need && !_ticker.isActive) {
      _lastFrame = Duration.zero;
      _lastTick = Duration.zero;
      _ticker.start();
    } else if (!need && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _onTick(Duration elapsed) {
    final fps = PowerProfile.current.mapFps.clamp(15, 120);
    final frameUs = 1000000 ~/ fps;
    if (_lastTick != Duration.zero && (elapsed - _lastFrame).inMicroseconds < frameUs) return;
    final dt = _lastTick == Duration.zero ? Duration.zero : elapsed - _lastTick;
    _lastTick = elapsed;
    _lastFrame = elapsed;
    PowerCounters.inc(PowerCounters.mapFrame);
    _c.tick(dt > const Duration(milliseconds: 250) ? const Duration(milliseconds: 250) : dt);
  }

  // ---- positions: the app's node roster, the hop candidates in each packet, the observer list
  void _updatePositions() {
    final s = AppScope.maybeOf(context);
    final nodes = <String, GeoPoint>{};
    if (s != null) {
      for (final r in [...s.globalRepeaterSet.rows, ...s.regionRepeaterSet.rows]) {
        nodes[r.key.toLowerCase()] = GeoPoint(r.lat, r.lon);
      }
    }
    _c.setPositions(LivePositions(node: (k) => nodes[k], observer: (id) => _observerPos[id] ?? _observerPos[id.toLowerCase()] ?? nodes[id.toLowerCase()]));
  }

  Future<void> _loadObservers() async {
    final api = nodesApiFactory(widget.region.url);
    try {
      final page = await api.observers();
      for (final o in page.rows) {
        if (o.position != null) _observerPos[o.id] = GeoPoint(o.position!.lat, o.position!.lon);
      }
      if (mounted) _updatePositions();
    } catch (_) {
      // Observers without positions are simply not drawn; the feed still lists who heard each packet.
    } finally {
      api.close();
    }
  }

  Future<void> _loadFocus(String hash, DateTime? at) async {
    final api = packetsApiFactory(widget.region.url);
    try {
      final d = await api.detail(hash);
      if (!mounted) return;
      _c.showPacket(LiveV2Packet.fromDetail(d.detail, fallbackTime: at));
      _fitFocus();
    } on V1Error catch (e) {
      if (mounted) setState(() => _focusError = e.notFound ? 'That packet is not on record here.' : e.message);
    } finally {
      api.close();
    }
  }

  void _fitFocus() {
    final d = _c.focusDrawing;
    if (d == null || !_mapReady) return;
    final pts = [for (final p in d.points) LatLng(p.lat, p.lon)];
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _map.move(pts.first, 12);
    } else {
      _map.fitCamera(CameraFit.coordinates(coordinates: pts, padding: EdgeInsets.fromLTRB(40, 40, 40, (_mainExtent ?? kMapPanelHeader) + kMapPanelHeader + 100), maxZoom: 13));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    PowerProfile.removeListener(_powerChanged);
    _favs?.removeListener(_favsChanged);
    _c.removeListener(_changed);
    _ticker.dispose();
    if (widget.controller == null) _c.dispose();
    _panels.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- drawing

  List<Widget> _overlays(BuildContext context) {
    final lines = <Polyline>[];
    final circles = <CircleMarker>[];
    final ghost = ghostColor(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dot = dark ? Colors.white : Colors.black87;

    void draw(LiveDrawing d, Color color, double progress, double alpha) {
      for (final s in d.segments) {
        if (progress <= s.step) continue;
        final f = (progress - s.step).clamp(0.0, 1.0);
        final end = s.a.lerp(s.b, f);
        final pts = [LatLng(s.a.lat, s.a.lon), LatLng(end.lat, end.lon)];
        switch (s.style) {
          case SegmentStyle.solid:
            lines.add(Polyline(points: pts, color: color.withValues(alpha: 0.25 * alpha), strokeWidth: 6, strokeCap: StrokeCap.round));
            lines.add(Polyline(points: pts, color: color.withValues(alpha: 0.9 * alpha), strokeWidth: 2.5));
          case SegmentStyle.dashed:
            lines.add(Polyline(points: pts, color: color.withValues(alpha: 0.85 * alpha), strokeWidth: 2, pattern: StrokePattern.dashed(segments: const [8, 6])));
          case SegmentStyle.ghost:
            lines.add(Polyline(points: pts, color: ghost.withValues(alpha: 0.45 * alpha), strokeWidth: 1.5, pattern: StrokePattern.dashed(segments: const [4, 6])));
          case SegmentStyle.ahead:
            lines.add(Polyline(points: pts, color: color.withValues(alpha: 0.7 * alpha), strokeWidth: 2, pattern: const StrokePattern.dotted()));
        }
        if (f < 1 && s.style != SegmentStyle.ghost) {
          circles.add(CircleMarker(point: pts.last, radius: 4, color: dot.withValues(alpha: alpha), borderColor: color, borderStrokeWidth: 2));
        }
      }
      for (final m in d.marks) {
        if (m.kind == MarkKind.ghost && progress <= m.step) continue;
        final p = LatLng(m.point.lat, m.point.lon);
        switch (m.kind) {
          case MarkKind.ghost:
            circles.add(CircleMarker(point: p, radius: 3, color: ghost.withValues(alpha: 0.6 * alpha)));
          case MarkKind.observer:
            circles.add(CircleMarker(point: p, radius: 5, color: Theme.of(context).colorScheme.surface.withValues(alpha: alpha), borderColor: color.withValues(alpha: alpha), borderStrokeWidth: 2));
          case MarkKind.origin:
            circles.add(CircleMarker(point: p, radius: 6, color: color.withValues(alpha: alpha), borderColor: dot.withValues(alpha: alpha), borderStrokeWidth: 1.5));
          case MarkKind.hop:
          case MarkKind.likelyHop:
            circles.add(CircleMarker(
                point: p,
                radius: 4,
                color: color.withValues(alpha: (m.kind == MarkKind.hop ? 0.9 : 0.5) * alpha),
                borderColor: dot.withValues(alpha: 0.6 * alpha),
                borderStrokeWidth: 1));
        }
      }
    }

    final fd = _c.focusDrawing;
    if (fd != null) draw(fd, packetTypeColor(context, _c.focus!.type), 1e9, 1);
    for (final a in _c.animations) {
      final (prog, alpha) = _c.progressOf(a);
      draw(a.drawing, packetTypeColor(context, a.packet.type), prog, alpha);
    }
    return [
      PolylineLayer(key: const Key('live-map-lines'), polylines: lines),
      CircleLayer(key: const Key('live-map-marks'), circles: circles),
    ];
  }

  // ---------------------------------------------------------------- UI
  //
  // One panel (rules in design/map_panel.dart). Collapsed, the whole chrome of the Live map is its 56 pt header: the status
  // dot and wording, the packet count, play / pause. Nothing sits at the top of the map. Open: notes, the scrubber, the
  // window, speed, Filters (a modal form), the full map, and the feed. A drawn packet is the transient panel above it.

  @override
  Widget build(BuildContext context) {
    final centre = regionCentre(widget.region) ?? const LatLng(39.96, -83.0);
    final focus = _c.focus;
    final rest = _mainExtent ?? kMapPanelHeader + MediaQuery.paddingOf(context).bottom;
    return MapPanelScope(
      group: _panels,
      child: Stack(
        key: const Key('live-map'),
        children: [
          Positioned.fill(
            child: MapPreview(
              mapKey: const Key('live-map-canvas'),
              controller: _map,
              center: centre,
              zoom: 9,
              interaction: MapPreviewInteraction.edit,
              tiles: widget.showBasemap,
              overlays: _overlays(context),
              // A tap on empty map closes the transient panel (the drawn packet).
              onTap: (_, _) {
                if (_c.focus != null) _c.clearFocus();
              },
              onMapReady: () {
                _mapReady = true;
                if (_c.focus != null) _fitFocus();
              },
            ),
          ),
          Positioned.fill(child: _mainPanel(context)),
          if (focus != null) Positioned.fill(bottom: rest, child: _focusPanel(context, focus)),
        ],
      ),
    );
  }

  (String, Color) _status(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_saver && !_saverOverride) return ('Paused in Saver mode', cs.outline);
    if (!_foreground) return ('Paused (app in background)', cs.outline);
    switch (_c.mode) {
      case LiveMode.paused:
        return (_c.missedWhilePaused > 0 ? 'Paused · +${_c.missedWhilePaused} new' : 'Paused', cs.outline);
      case LiveMode.replay:
        final c = _c.replayClock;
        return ('Replay ${replaySpeedLabel(_c.speed)} · ${c == null ? '' : clockText(c.playhead)}', cs.tertiary);
      case LiveMode.live:
        break;
    }
    return switch (_c.streamState) {
      NetLiveState.live => (_c.observersOnline == null ? 'Live' : 'Live · ${_c.observersOnline} observers online', cs.primary),
      NetLiveState.connecting || NetLiveState.idle => ('Connecting', cs.outline),
      NetLiveState.reconnecting => (_c.allPackets.isEmpty ? 'Live needs a connection, retrying' : 'Reconnecting, showing earlier packets', cs.error),
      NetLiveState.paused => ('Paused', cs.outline),
    };
  }

  Widget _mainPanel(BuildContext context) {
    final (label, color) = _status(context);
    final paused = _c.mode == LiveMode.paused;
    final feed = _c.feed;
    return MapPanel(
      id: 'live.main',
      title: label,
      headerKey: const Key('live-panel-header'),
      leading: Icon(Icons.circle, size: 10, color: color),
      // The panel's own content count (rule 8), never a message count.
      status: Text('${feed.length} packet${feed.length == 1 ? '' : 's'}', key: const Key('live-map-count')),
      action: IconButton(
        key: Key(paused ? 'live-map-play' : 'live-map-pause'),
        tooltip: paused ? 'Play' : 'Pause',
        constraints: const BoxConstraints(minWidth: Hit.min, minHeight: Hit.min),
        icon: Icon(paused ? Icons.play_arrow : Icons.pause),
        onPressed: paused ? _c.play : _c.pause,
      ),
      onExtent: (e) => setState(() => _mainExtent = e),
      child: _body(context, label, feed),
    );
  }

  Widget _body(BuildContext context, String label, List<LiveV2Packet> feed) {
    final t = Theme.of(context);
    final notes = <String>[
      if (_c.source == NetworkReadSource.legacy) "Today's live feed: only hops the server could place are sent, so unresolved hops are not drawn.",
      if (_c.nodeListTrusted == false) _c.nodeListReason ?? 'The node list is not complete here, so no hop is named with more than "likely".',
      ?_c.note,
      ?_c.replayError,
      ?_focusError,
    ];
    final now = DateTime.now().toUtc();
    return CustomScrollView(
      key: const Key('live-panel-body'),
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, Layout.screenMargin, 4),
          sliver: SliverList.list(children: [
            // The header's wording in full (it is one line up there).
            Text(label, key: const Key('live-map-status'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
            if (_saver && !_saverOverride)
              Row(key: const Key('live-saver-banner'), children: [
                Expanded(child: Text('Saver mode stops the live map to save battery.', style: t.textTheme.bodySmall)),
                TextButton(
                  key: const Key('live-saver-override'),
                  onPressed: () => setState(() {
                    _saverOverride = true;
                    _sync();
                  }),
                  child: const Text('Show anyway'),
                ),
              ]),
            for (final n in notes) Padding(padding: const EdgeInsets.only(top: 4), child: Text(n, style: t.textTheme.bodySmall)),
            const SizedBox(height: 6),
            _Scrubber(controller: _c),
            const SizedBox(height: 4),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                for (final w in liveWindows.keys)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      key: Key('live-window-$w'),
                      label: Text(_windowLabels[w] ?? w),
                      selected: _c.window == w,
                      onSelected: (_) => unawaited(_c.setWindow(w)),
                    ),
                  ),
              ]),
            ),
            // Wrap, not Row: at large text sizes the controls take a second line instead of clipping.
            Wrap(spacing: 4, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              TextButton(
                key: const Key('live-map-speed'),
                onPressed: _cycleSpeed,
                child: Text(replaySpeedLabel(_c.speed), semanticsLabel: 'Replay speed ${_c.speed} times'),
              ),
              if (_c.mode != LiveMode.live)
                TextButton.icon(
                  key: const Key('live-map-jump-live'),
                  icon: const Icon(Icons.skip_next),
                  label: const Text('Live'),
                  onPressed: _c.jumpToLive,
                ),
              TextButton.icon(
                key: const Key('live-map-filters'),
                icon: Icon(_c.filter.isEmpty ? Icons.filter_list : Icons.filter_list_alt),
                label: const Text('Filters'),
                onPressed: () => _openFilters(context),
              ),
              TextButton.icon(
                key: const Key('live-map-open-full'),
                icon: const Icon(Icons.layers_outlined),
                label: const Text('Coverage map'),
                onPressed: () {
                  final c = regionCentre(widget.region);
                  if (c != null) MainMapFocus.request(c, 10, showLayers: networkMapLayers);
                  ShellScope.maybeRead(context)?.openDrive();
                },
              ),
            ]),
            const _Legend(),
            const SizedBox(height: 8),
            Semantics(
              header: true,
              child: Text(feed.isEmpty ? 'Waiting for packets' : 'Feed · newest first', style: t.textTheme.titleSmall),
            ),
          ]),
        ),
        SliverList.builder(
          key: const Key('live-feed-list'),
          itemCount: feed.length,
          itemBuilder: (ctx, i) => _FeedRow(
            packet: feed[i],
            now: now,
            onOpen: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => NetworkPacketScreen(baseUrl: widget.region.url, regionSlug: widget.region.slug, hash: feed[i].hash))),
            onDraw: () {
              _c.showPacket(feed[i]);
              _fitFocus();
            },
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
      ],
    );
  }

  /// The drawn packet: a transient panel above the Live panel. Closed with its X or a tap on empty map.
  Widget _focusPanel(BuildContext context, LiveV2Packet p) {
    final t = Theme.of(context);
    final d = _c.focusDrawing!;
    final heard = '${p.observations.length} heard';
    return MapPanel(
      key: const Key('live-focus-card'),
      id: 'live.focus',
      title: '${packetTypeLabel(p.typeName)} · ${p.hash.substring(0, 8)}',
      leading: Container(width: 10, height: 10, decoration: BoxDecoration(color: packetTypeColor(context, p.type), shape: BoxShape.circle)),
      status: Text(heard),
      bottomSafe: false,
      onClose: _c.clearFocus,
      closeKey: const Key('live-focus-close'),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Layout.screenMargin, 0, 4, 8),
        child: Row(children: [
          Expanded(
            child: Text(
              [
                heard,
                if (d.unplaced > 0) '${d.unplaced} hop${d.unplaced == 1 ? '' : 's'} not placed',
                if (d.isEmpty) 'no known positions to draw',
              ].join(' · '),
              style: t.textTheme.bodySmall,
            ),
          ),
          TextButton(
            key: const Key('live-focus-replay'),
            onPressed: () {
              final at = p.firstSeen.subtract(const Duration(seconds: 30));
              _c.clearFocus();
              unawaited(_c.replayFrom(at));
            },
            child: const Text('Replay here'),
          ),
        ]),
      ),
    );
  }

  void _cycleSpeed() {
    final i = replaySpeeds.indexOf(_c.speed);
    _c.setSpeed(replaySpeeds[(i + 1) % replaySpeeds.length]);
  }

  /// Filters are a form: a modal sheet (rule 9).
  void _openFilters(BuildContext context) {
    final observers = <String, String>{};
    for (final p in _c.allPackets) {
      for (final o in p.observations) {
        observers[o.observer.id] = o.observer.name;
      }
    }
    showAppSheet<void>(
      context,
      detents: const [0.6, 0.92],
      builder: (ctx, sc) => ListenableBuilder(
        listenable: _c,
        builder: (ctx, _) => _FilterSheet(controller: sc, live: _c, observers: observers),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend();
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final muted = t.textTheme.labelSmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    return Semantics(
      label: 'Legend: solid line, hop known for sure. Dashed, likely hop. Faint grey, hops nobody can place.',
      excludeSemantics: true,
      child: Wrap(spacing: 12, runSpacing: 2, children: [
        Text('━ unique hop', style: muted),
        Text('╌ likely hop', style: muted),
        Text('┈ unplaced (ghost) hops', style: muted?.copyWith(color: ghostColor(context))),
      ]),
    );
  }
}

/// The density bars and the playhead; drag and drop to replay from a time.
class _Scrubber extends StatefulWidget {
  final LiveMapController controller;
  const _Scrubber({required this.controller});
  @override
  State<_Scrubber> createState() => _ScrubberState();
}

class _ScrubberState extends State<_Scrubber> {
  double? _drag; // 0..1 while dragging

  LiveMapController get c => widget.controller;

  double _playheadFrac() {
    final (from, to) = c.windowRange();
    if (c.mode == LiveMode.live) return 1;
    final at = c.replayClock?.playhead ?? to;
    return (at.difference(from).inMilliseconds / to.difference(from).inMilliseconds).clamp(0.0, 1.0);
  }

  DateTime _timeAt(double f) {
    final (from, to) = c.windowRange();
    return from.add(Duration(milliseconds: (to.difference(from).inMilliseconds * f).round()));
  }

  void _drop(double f) {
    setState(() => _drag = null);
    if (f >= 0.995) {
      c.jumpToLive();
    } else {
      unawaited(c.replayFrom(_timeAt(f)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final frac = _drag ?? _playheadFrac();
    final label = _drag != null ? clockText(_timeAt(_drag!)) : (c.mode == LiveMode.live ? 'Live' : clockText(_timeAt(frac)));
    return Semantics(
      key: const Key('live-map-scrubber'),
      slider: true,
      label: 'Replay time, drag to replay from a moment',
      value: label,
      increasedValue: clockText(_timeAt((frac + 0.05).clamp(0, 1))),
      decreasedValue: clockText(_timeAt((frac - 0.05).clamp(0, 1))),
      onIncrease: () => _drop((frac + 0.05).clamp(0.0, 1.0)),
      onDecrease: () => _drop((frac - 0.05).clamp(0.0, 1.0)),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth;
        double f(Offset p) => (p.dx / w).clamp(0.0, 1.0);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) => setState(() => _drag = f(d.localPosition)),
          onHorizontalDragUpdate: (d) => setState(() => _drag = f(d.localPosition)),
          onHorizontalDragEnd: (_) => _drop(_drag ?? 1),
          onTapUp: (d) => _drop(f(d.localPosition)),
          child: SizedBox(
            height: 44,
            child: CustomPaint(
              painter: _DensityPainter(
                counts: c.density?.counts.map((e) => e.$2).toList() ?? const [],
                playhead: frac,
                bar: t.colorScheme.primary.withValues(alpha: 0.45),
                head: t.colorScheme.onSurface,
                base: t.colorScheme.outlineVariant,
              ),
              child: Align(
                alignment: Alignment.topRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    c.density == null && !c.densityLoading ? '$label · no density from the server' : label,
                    style: t.textTheme.labelSmall,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class _DensityPainter extends CustomPainter {
  final List<int> counts;
  final double playhead;
  final Color bar, head, base;
  const _DensityPainter({required this.counts, required this.playhead, required this.bar, required this.head, required this.base});

  @override
  void paint(Canvas canvas, Size size) {
    final top = 14.0;
    final h = size.height - top;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = base);
    if (counts.isNotEmpty) {
      final mx = counts.fold<int>(1, math.max);
      final bw = size.width / counts.length;
      final p = Paint()..color = bar;
      for (var i = 0; i < counts.length; i++) {
        final bh = counts[i] / mx * h;
        if (bh <= 0) continue;
        canvas.drawRect(Rect.fromLTWH(i * bw + 0.5, size.height - bh, math.max(1, bw - 1), bh), p);
      }
    }
    final x = playhead * size.width;
    canvas.drawLine(Offset(x, top - 2), Offset(x, size.height), Paint()
      ..color = head
      ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_DensityPainter old) => old.counts != counts || old.playhead != playhead || old.bar != bar;
}

class _FeedRow extends StatelessWidget {
  final LiveV2Packet packet;
  final DateTime now;
  final VoidCallback onOpen, onDraw;
  const _FeedRow({required this.packet, required this.now, required this.onOpen, required this.onDraw});

  @override
  Widget build(BuildContext context) {
    final p = packet;
    final text = p.message?.hidden == true ? 'Message hidden by a moderator' : p.message?.text;
    return ListTile(
      key: Key('live-feed-row-${p.hash}'),
      leading: Container(width: 12, height: 12, decoration: BoxDecoration(color: packetTypeColor(context, p.type), shape: BoxShape.circle)),
      title: Text(
        p.origin?.name != null ? '${packetTypeLabel(p.typeName)}: ${p.origin!.name}' : (p.channel != null ? '${packetTypeLabel(p.typeName)} on ${p.channel!.label}' : packetTypeLabel(p.typeName)),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text([
        if (text != null) (text.length > 60 ? '${text.substring(0, 60)}…' : text),
        [
          '${p.hops} hop${p.hops == 1 ? '' : 's'}',
          '${p.observations.length} heard',
          if (p.bestSnr != null) 'best ${snrText(p.bestSnr)}',
          ageText(p.firstSeen, now),
        ].join(' · '),
      ].join('\n')),
      isThreeLine: text != null,
      onTap: onOpen,
      trailing: IconButton(key: Key('live-feed-draw-${p.hash}'), tooltip: 'Draw on the map', icon: const Icon(Icons.route), onPressed: onDraw),
    );
  }
}

class _FilterSheet extends StatelessWidget {
  final ScrollController controller;
  final LiveMapController live;
  final Map<String, String> observers;
  const _FilterSheet({required this.controller, required this.live, required this.observers});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final f = live.filter;
    return ListView(
      key: const Key('live-filter-sheet'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Semantics(header: true, child: Text('Filters', style: t.textTheme.titleLarge)),
        const SizedBox(height: 8),
        SwitchListTile(
          key: const Key('live-filter-mine'),
          contentPadding: EdgeInsets.zero,
          title: const Text('My nodes'),
          subtitle: Text(live.myNodes.isEmpty
              ? 'Star nodes or observers under Nodes, or claim your radio, to use this.'
              : 'Only packets from, through or heard by your starred and claimed nodes.'),
          value: f.myNodesOnly,
          onChanged: (v) => live.setFilter(f.copyWith(myNodesOnly: v)),
        ),
        const SizedBox(height: 8),
        Text('Packet types', style: t.textTheme.titleSmall),
        const SizedBox(height: 4),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final ty in livePacketTypes)
            FilterChip(
              key: Key('live-filter-type-$ty'),
              avatar: CircleAvatar(backgroundColor: packetTypeColor(context, ty), radius: 6),
              label: Text(packetTypeLabel(packetTypeWireName(ty))),
              selected: f.types.contains(ty),
              onSelected: (on) => live.setFilter(f.copyWith(types: on ? {...f.types, ty} : ({...f.types}..remove(ty)))),
            ),
        ]),
        const SizedBox(height: 12),
        Text('Observer', style: t.textTheme.titleSmall),
        if (observers.isEmpty) Text('Observers appear here once packets arrive.', style: t.textTheme.bodySmall),
        RadioGroup<String?>(
          groupValue: f.observerId,
          onChanged: (v) => live.setFilter(v == null ? f.copyWith(clearObserver: true) : f.copyWith(observerId: v)),
          child: Column(children: [
            if (observers.isNotEmpty) const RadioListTile<String?>(key: Key('live-filter-observer-all'), contentPadding: EdgeInsets.zero, title: Text('All observers'), value: null),
            for (final e in observers.entries)
              RadioListTile<String?>(key: Key('live-filter-observer-${e.key}'), contentPadding: EdgeInsets.zero, title: Text(e.value), value: e.key),
          ]),
        ),
        if (!f.isEmpty)
          TextButton(key: const Key('live-filter-clear'), onPressed: () => live.setFilter(LiveFilter.none), child: const Text('Clear filters')),
      ],
    );
  }
}
