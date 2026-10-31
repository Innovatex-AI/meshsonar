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
//     networkCells: cells,                // optional: network-wide coverage cells (GET public-coverage)
//   )
//
// Live drive: pass `position` and leave `follow: true`. Dragging the map turns follow off and shows a
// Recenter button. Drive detail: pass `follow: false, fitToPings: true` to frame the whole drive.
//
// What's drawn, bottom to top:
//   1. A chart grid on the map background (so the map looks intentional with no tiles / no signal).
//   2. OpenStreetMap tiles (colour-graded to the theme; cached; failures fall back to the grid, never an error).
//   3. Network-wide measured coverage (every driver, GET /api/cmh/public-coverage, gated by
//      MapLayers.networkCoverage): a quiet "where hasn't this been driven" background layer. Only cells the
//      network actually measured are tinted; everywhere else is left blank map — that absence is the gap
//      indicator, so there is no "no data" placeholder for it.
//   4. Sonar range rings (1 km / 2 km, or 0.5 mi / 1 mi) around the current position.
//   5. Links. With [heard]: from the current position to every LIVE heard repeater with a known location, solid
//      when heard on the latest ping, dashed while it is holding, each with a distance label. Without [heard]:
//      from the latest ping to each repeater it heard; they fade over ~15 s.
//   5b. Network layers (registry ids, layers/registry.dart): the global "All MeshCore repeaters" layer (`network`,
//      off by default) and the region roster (`repeaters`) as clustered painters from a [RepeaterMapSource], then
//      the viewed region's observers with a public position (`observers`). Taps open detail sheets through
//      showMapHitSheet (sheets/map_hit_sheet.dart); a cluster zooms to its members.
//   6. Repeaters (amber beacons). Heard ones pop up and glow while live, then grey out when stale. Tap for the name.
//   7. Ping dots: heard = blue→teal→green by best SNR (-10 → +10 dB) or plain green in "result" mode; heard nothing
//      = red. The newest dot pulses once.
//   8. Current position.
//
// Efficiency: inputs are snapshots taken once per ping (the heard list, the ping list); derived lists (sorted pings,
// the repeater marker set) are memoised on input identity, so a rebuild between pings costs nothing new. Markers are
// culled to the visible bounds by flutter_map's MarkerLayer.
//
// Widget keys (for tests): 'map-ping-<pingId>' (the dot: a DecoratedBox whose BoxDecoration.color is the result),
// 'map-repeater-<key>' (+ 'map-repeater-state-<key>-<fresh|holding|stale|idle>'), 'map-repeater-label',
// 'layer-network-paint' / 'layer-repeaters-paint' (the clustered layers), 'map-observer-<key>', 'map-network-legend',
// 'map-network-attribution',
// 'map-heard-label-<key>', 'map-link-distance-<key>', 'map-position', 'map-recenter', 'map-compass', 'map-offline',
// 'map-attribution', 'map-simulated'.
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:h3_flutter/h3_flutter.dart' show H3;

import '../../core/heard.dart' show haversineM;
import '../../core/coverage_query.dart' show coverageResForZoom;
import '../../core/api.dart' show CmatException;
import '../../core/hex_cells.dart';
import '../../core/map_links.dart';
import '../../core/repeater_reach.dart' show ReachTotals;
import '../../core/model.dart';
import '../../core/region_overview_api.dart' show RegionObserver;
import '../../core/region_repeaters_api.dart' show RegionRepeater;
import '../../core/network_coverage.dart';
import '../theme.dart';
import '../widgets.dart';
import 'cell_sheet.dart';
import '../../app/app_state.dart' show AppState;
import '../app.dart' show AppScope;
import 'layers/layers_sheet.dart' show NetworkAgeLegend;
import 'layers/link_lines_layer.dart';
import 'layers/map_layer.dart';
import 'layers/map_layers_adapter.dart';
import 'layers/observer_layer.dart';
import 'layers/repeater_cluster_layer.dart';
import 'layers/repeater_map_source.dart';
import 'layers/repeater_name_labels.dart';
import 'map_info_panel.dart';
import 'map_layers.dart';
import 'offline_basemap.dart';
import 'sheets/map_hit_sheet.dart';
import 'sheets/observer_sheet.dart' show ObserverSheetContext;
import 'sheets/repeater_sheet.dart' show RepeaterSheet, RepeaterSheetContext;

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

/// Colour for a network-coverage [CoverageLevel]: the website's own discrete `/coverage` legend steps (strong
/// green, likely blue, possible amber, stretch red; same hex values as its light/dark CSS tokens), not this
/// drive's continuous SNR gradient — the two data sets are deliberately told apart at a glance. [none] (no data
/// for the chosen dimension) is a neutral outline colour, never one of the four steps.
Color networkLevelColor(BuildContext context, CoverageLevel level) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  switch (level) {
    case CoverageLevel.strong:
      return dark ? const Color(0xFF79BE69) : const Color(0xFF2F7A3B);
    case CoverageLevel.good:
      return dark ? const Color(0xFF6AAEE0) : const Color(0xFF2A6B9C);
    case CoverageLevel.fair:
      return dark ? const Color(0xFFE2B04A) : const Color(0xFFB07D16);
    case CoverageLevel.weak:
      return dark ? const Color(0xFFF07B6B) : const Color(0xFFB23B2E);
    case CoverageLevel.none:
      return Theme.of(context).colorScheme.outlineVariant;
  }
}

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

  /// Where to centre when there's nothing else to centre on: the viewed region's centre (from regions-index).
  /// Null (index never loaded) shows a whole-world view rather than guessing a city.
  final LatLng? fallbackCenter;

  /// Extra space at the edges for overlays drawn on top of the map by the parent (e.g. a chip row).
  final EdgeInsets overlayPadding;

  /// Who's in range this drive (live first). When set, repeater markers and links follow it.
  final List<HeardView>? heard;

  /// Which layers to draw.
  final MapLayers layers;

  /// Network-wide measured coverage cells (e.g. from `CmatClient.publicCoverage()`), drawn as the background
  /// "where hasn't this been driven" layer when [MapLayers.networkCoverage] is on. Empty/not-yet-loaded draws
  /// nothing — there is no placeholder for "no data"; absence of a drawn cell is the point.
  final List<NetworkCell> networkCells;

  /// The region's whole repeater roster, drawn (clustered, tap for a sheet) when [MapLayers.regionRepeaters] is on.
  /// Used only when no [repeaterSource] is given; with one, the roster comes from the source.
  final List<RegionRepeater> regionRepeaters;

  /// Both repeater lists, render-ready (global `network` layer + region roster `repeaters` layer). Owned by the host
  /// (e.g. DriveMapModel); the map never disposes it.
  final RepeaterMapSource? repeaterSource;

  /// Which registry layers are on. Null = derived from [layers] (which has no field for `network` / `observers`).
  final MapLayerState? layerState;

  /// The viewed region's observers with a public position, drawn when the `observers` layer is on.
  final List<RegionObserver> observers;

  /// Display name of the region [observers] belong to (for the observer sheet).
  final String? observersRegionName;

  /// "Open repeater page" from a repeater sheet (null = no button).
  final void Function(BuildContext context, RepeaterPoint point)? openRepeaterPage;

  /// Repeater (map key) to highlight and bring into view, e.g. tapped in the heard box.
  final String? highlightKey;

  /// Called when a repeater marker is tapped (null = selection cleared).
  final ValueChanged<String?>? onSelectRepeater;

  /// Show the "SIMULATED GPS & RADIO" tag.
  final bool simulated;

  /// Reports the map zoom as it changes (the coverage layer picks its H3 resolution from it).
  final ValueChanged<double>? onZoomChanged;

  /// H3 resolution (7..11) for the drive's own hexagons when the person pinned one in the coverage options; null =
  /// automatic, the resolution for the map's current zoom ([coverageResForZoom], the same table the network layer uses),
  /// so the drive's cells rescale as you zoom.
  final int? hexRes;

  /// Overlays the parent draws over this map (heard box, button column), found by key at paint time: repeater names are
  /// never placed under them.
  final List<GlobalKey> labelAvoidKeys;

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
    this.fallbackCenter,
    this.overlayPadding = EdgeInsets.zero,
    this.heard,
    this.layers = const MapLayers(),
    this.networkCells = const [],
    this.regionRepeaters = const [],
    this.repeaterSource,
    this.layerState,
    this.observers = const [],
    this.observersRegionName,
    this.openRepeaterPage,
    this.highlightKey,
    this.onSelectRepeater,
    this.simulated = false,
    this.onZoomChanged,
    this.hexRes,
    this.labelAvoidKeys = const [],
  });

  /// True unless running under `flutter test`.
  static bool tilesByDefault = () {
    try {
      return !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return true;
    }
  }();

  /// The H3 engine; tests swap in one loaded by path.
  @visibleForTesting
  static H3? hexEngine = loadHexEngine();

  static const String tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackageName = 'com.meshsonar.app';

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
  double? _lastZoom;

  /// The camera zoom as last seen (before the first camera event: the zoom the map opened at).
  double? _zoomNow;

  // Memoised on input identity (see the header comment).
  List<DrivePing>? _sortedSrc;
  List<DrivePing> _sorted = const [];
  DrivePing? _latestCache;
  List<RepeaterRef>? _markerSrcRepeaters;
  List<HeardView>? _markerSrcHeard;
  List<RepeaterRef> _markerRepeaters = const [];
  Map<String, HeardView> _heardByKey = const {};

  // Without a host RepeaterMapSource, [CoverageMap.regionRepeaters] is drawn through a source of our own (rebuilt only
  // when that list's identity changes).
  StaticRepeaterMapFeed? _ownFeed;
  RepeaterMapSource? _ownSource;
  List<RegionRepeater>? _ownSrc;

  RepeaterMapSource? _rosterSource() {
    if (widget.repeaterSource != null) return widget.repeaterSource;
    final list = widget.regionRepeaters;
    if (list.isEmpty && _ownSource == null) return null;
    if (!identical(list, _ownSrc)) {
      _ownSrc = list;
      if (_ownFeed == null) {
        _ownFeed = StaticRepeaterMapFeed();
        _ownSource = RepeaterMapSource(_ownFeed!);
      }
      _ownFeed!.setRoster(null, list);
    }
    return _ownSource;
  }

  // ---------- link lines: tap a repeater -> a line to every cell it was heard in; tap a cell -> a line to every repeater ----------
  String? _linkId;
  bool _linkBusy = false;
  String? _linkError;
  int _linkGen = 0;
  int _linkUnplaced = 0;
  LinkSet Function(int res)? _linkBuild;
  LinkSet? _linkSet;
  int _linkSetRes = -1;
  NetworkCell? _panelCell;
  RepeaterPoint? _panelPoint;
  ReachTotals? _reachTotals;

  AppState? _appOrNull() {
    final w = context.getElementForInheritedWidgetOfExactType<AppScope>()?.widget;
    return w is AppScope ? w.notifier : null;
  }

  /// The lines at the resolution drawn now (a repeater's reach is re-bucketed when the zoom crosses a band).
  LinkSet? _currentLinks() {
    final build = _linkBuild;
    if (build == null) return null;
    final res = hexResolution;
    if (_linkSet == null || _linkSetRes != res) {
      _linkSet = build(res);
      _linkSetRes = res;
    }
    return _linkSet;
  }

  void _clearLinks() {
    if (_linkId == null && _panelCell == null && _panelPoint == null) return;
    _linkGen++;
    setState(() {
      _linkId = null;
      _linkBuild = null;
      _linkSet = null;
      _linkBusy = false;
      _linkError = null;
      _linkUnplaced = 0;
      _panelCell = null;
      _panelPoint = null;
      _reachTotals = null;
    });
  }

  void _beginLinks(String id, String title) {
    _linkGen++;
    setState(() {
      _linkId = id;
      _linkBusy = true;
      _linkError = null;
      _linkBuild = null;
      _linkSet = null;
      _linkUnplaced = 0;
    });
  }

  String _linkFailure(Object e) => e is CmatException && (e.status == 429)
      ? 'Too many requests. Try again in a minute.'
      : 'Couldn\'t load the links. Check your connection.';

  Future<void> _showRepeaterLinks(RepeaterPoint p) async {
    final app = _appOrNull();
    final h3 = CoverageMap.hexEngine;
    if (app == null || h3 == null || !app.reachEnabled) {
      _clearLinks();
      setState(() => _panelPoint = p); // the panel still opens with what the sheet knows
      return;
    }
    _beginLinks('repeater:${p.key}', p.name);
    setState(() {
      _panelPoint = p;
      _panelCell = null;
      _reachTotals = null;
    });
    final gen = _linkGen;
    try {
      final r = await app.repeaterReach(p.key, lat: p.lat, lon: p.lon);
      if (!mounted || gen != _linkGen) return;
      setState(() {
        _linkBusy = false;
        _reachTotals = r.reach.totals;
        _linkBuild = (res) => LinkSet(id: 'repeater:${p.key}', lat: p.lat, lon: p.lon, title: p.name, ends: reachEnds(r.reach, h3, res));
      });
    } catch (e) {
      if (!mounted || gen != _linkGen) return;
      setState(() {
        _linkBusy = false;
        _linkError = _linkFailure(e);
      });
    }
  }

  ({double lat, double lon, String name})? _placeRepeater(String key) {
    for (final src in [_rosterSource(), widget.repeaterSource]) {
      if (src == null) continue;
      for (final layer in [kRosterLayerId, kNetworkLayerId]) {
        final pts = src.pointsOf(layer);
        var i = pts.indexOf(key);
        // cell-links ids can be a prefix (2 bytes or more) of the repeater's key: take it only when exactly one matches.
        if (i < 0 && key.length >= 4) {
          for (var j = 0; j < pts.length; j++) {
            if (!pts.key[j].startsWith(key)) continue;
            if (i >= 0) return null; // ambiguous: not placed rather than guessed
            i = j;
          }
        }
        if (i >= 0) return (lat: pts.lat[i], lon: pts.lon[i], name: pts.name[i]);
      }
    }
    final r = _refFor(key);
    return r == null ? null : (lat: r.lat, lon: r.lon, name: _nameFor(r));
  }

  Future<void> _showCellLinks(NetworkCell n) async {
    final c = n.cell, id = c?.h3;
    final app = _appOrNull();
    if (c == null || id == null || app == null || !app.cellLinksEnabled) {
      _clearLinks();
      setState(() => _panelCell = n);
      return;
    }
    _beginLinks('cell:$id', 'This cell');
    setState(() {
      _panelCell = n;
      _panelPoint = null;
    });
    final gen = _linkGen;
    try {
      final got = await app.cellLinks(id);
      if (!mounted || gen != _linkGen) return;
      final placed = cellEnds(got, _placeRepeater);
      setState(() {
        _linkBusy = false;
        _linkUnplaced = placed.unplaced;
        _linkBuild = (_) => LinkSet(id: 'cell:$id', lat: c.lat, lon: c.lon, title: 'This cell', ends: placed.ends, unplaced: placed.unplaced);
      });
    } catch (e) {
      if (!mounted || gen != _linkGen) return;
      setState(() {
        _linkBusy = false;
        _linkError = _linkFailure(e);
      });
    }
  }

  String _panelSummary() {
    if (_linkBusy) return 'Finding links…';
    if (_linkError != null) return _linkError!;
    final set = _currentLinks();
    final n = set?.ends.length ?? 0;
    if (_panelPoint != null) {
      if (set == null) return roleLine(_panelPoint!);
      return n == 0 ? 'No MeshSonar drive has heard it yet' : 'Heard in $n ${n == 1 ? 'cell' : 'cells'}  ·  tap to expand';
    }
    final c = _panelCell?.cell;
    if (set == null) return c == null ? 'Coverage cell' : '${c.heard} of ${c.pings} pings heard';
    final base = n == 0 ? 'No mapped repeater heard here' : '$n ${n == 1 ? 'repeater' : 'repeaters'} heard here';
    return _linkUnplaced > 0 ? '$base (+$_linkUnplaced not on the map)' : base;
  }

  static String roleLine(RepeaterPoint p) => p.isRoom ? 'Room server' : 'Repeater';

  Widget? _panel(BuildContext context) {
    final p = _panelPoint, cell = _panelCell;
    if (p == null && cell == null) return null;
    final set = _currentLinks();
    final canFit = !_linkBusy && _linkError == null && (set?.ends.isNotEmpty ?? false);
    final here = widget.position ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    final units = AppScope.unitsOf(context);
    final Widget body;
    if (p != null) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_linkId != null && !_linkBusy)
            RepeaterReachStats(totals: _reachTotals, cells: set?.ends.length ?? 0, distance: (km) => units.distance(km * 1000)),
          Flexible(
            child: RepeaterSheet(
              point: p,
              dismissOnOpen: false,
              ctx: RepeaterSheetContext(position: here, openRegionPage: widget.openRepeaterPage, units: units),
            ),
          ),
        ],
      );
    } else {
      body = SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CellSheet(cell: cell!),
            if (_linkId != null && !_linkBusy && _linkError == null) CellRepeaterList(ends: set?.ends ?? const []),
          ],
        ),
      );
    }
    return MapInfoPanel(
      key: ValueKey('info-panel-${p?.key ?? cell!.id}'),
      title: p?.name ?? 'Coverage cell',
      summary: _panelSummary(),
      busy: _linkBusy,
      body: body,
      onFit: canFit ? _fitLinks : null,
      onClose: _clearLinks,
    );
  }

  void _fitLinks() {
    final s = _currentLinks();
    if (s == null || s.ends.isEmpty) return;
    _controller.fitCamera(CameraFit.coordinates(
      coordinates: [LatLng(s.lat, s.lon), for (final e in s.ends) LatLng(e.lat, e.lon)],
      padding: widget.overlayPadding + const EdgeInsets.all(56),
      maxZoom: 15,
    ));
  }

  /// A tap on a clustered repeater layer or an observer (cells come through [MapOptions.onTap]).
  void _onHit(MapHit hit) {
    if (hit is ClusterHit && hit.colocated.length <= 1) setState(() => _follow = false); // the camera moves to it
    final here = widget.position ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    if (hit is RepeaterHit) {
      _showRepeaterLinks(hit.point);
      return;
    }
    if (hit is ClusterHit && hit.colocated.length == 1) {
      _showRepeaterLinks(hit.colocated.single);
      return;
    }
    showMapHitSheet(
      context,
      hit,
      controller: _controller,
      repeaterContext: RepeaterSheetContext(position: here, openRegionPage: widget.openRepeaterPage),
      observerContext: ObserverSheetContext(position: here),
    );
  }

  // Hexagons: the H3 library is loaded once; the roll-up reruns only when the ping list changes.
  List<DrivePing>? _hexSrc;
  int _hexSrcLen = -1;
  int _hexSrcRes = -1;
  List<HexCell> _hexCells = const [];

  /// The resolution the drive's hexagons are drawn at: the pinned one, else the one for the current zoom.
  /// Small captions on the map (ring distances, link distances, heard names) are drawn from this zoom; zoomed out to a
  /// whole region they only pile on top of the repeater bubbles.
  static const double captionMinZoom = 10;
  bool get _captions => (_zoomNow ?? _initialZoom) >= captionMinZoom;

  int get hexResolution => (widget.hexRes ?? coverageResForZoom(_zoomNow ?? _initialZoom)).clamp(7, 11);

  List<HexCell> _ensureHexes() {
    final h3 = CoverageMap.hexEngine;
    if (h3 == null) return const [];
    final res = hexResolution;
    if (identical(_hexSrc, widget.pings) && _hexSrcLen == widget.pings.length && _hexSrcRes == res) return _hexCells;
    _hexSrc = widget.pings;
    _hexSrcLen = widget.pings.length;
    _hexSrcRes = res;
    try {
      _hexCells = buildHexCells(widget.pings, h3, res: res);
    } catch (_) {
      _hexCells = const [];
    }
    return _hexCells;
  }

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
    return widget.fallbackCenter ?? const LatLng(20, 0);
  }

  double get _initialZoom {
    if (widget.position != null || widget.pings.isNotEmpty) return 13.6;
    if (widget.repeaters.isNotEmpty) return 11;
    return widget.fallbackCenter == null ? 1.5 : 8;
  }

  CameraFit? get _initialFit {
    if (widget.fitToPings && widget.pings.length >= 2) {
      return CameraFit.coordinates(
        coordinates: [for (final p in widget.pings) LatLng(p.lat, p.lon)],
        padding: const EdgeInsets.all(40) + widget.overlayPadding,
        maxZoom: 15.5, // a short drive should still show its streets, not upscaled blurry tiles
      );
    }
    // Nothing of our own to frame yet (no position, no pings): frame the network-coverage cells instead, so the
    // background layer is actually visible on first open rather than requiring a manual pan to find it.
    if (widget.position == null && widget.pings.isEmpty && widget.networkCells.isNotEmpty) {
      return CameraFit.coordinates(
        coordinates: [for (final n in widget.networkCells) for (final b in n.boundary) LatLng(b.lat, b.lon)],
        padding: const EdgeInsets.all(40) + widget.overlayPadding,
        maxZoom: 15,
      );
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _selectedRepeater = widget.highlightKey;
    if (widget.showTiles ?? CoverageMap.tilesByDefault) {
      _pack.basemap.addListener(_onPacksChanged);
      _pack.basemap.ensureOpen();
      _pack.update(_initialCenter.latitude, _initialCenter.longitude);
    }
  }

  // Offline region pack drawn under the overlays; follows the camera centre (see OfflinePackSelection).
  late final OfflinePackSelection _pack = OfflinePackSelection(OfflineBasemap.instance);

  void _onPacksChanged() {
    if (!mounted) return;
    _pack.refresh();
    setState(() {});
  }

  @override
  void didUpdateWidget(CoverageMap old) {
    super.didUpdateWidget(old);
    if (old.follow != widget.follow) _follow = widget.follow;
    // The viewed region changed (or the index finished loading) while there is nothing else to look at: recentre.
    if (old.fallbackCenter != widget.fallbackCenter &&
        widget.fallbackCenter != null &&
        _ready &&
        widget.position == null &&
        widget.pings.isEmpty &&
        widget.repeaters.isEmpty) {
      _controller.move(widget.fallbackCenter!, 10);
    }
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
    _pack.basemap.removeListener(_onPacksChanged);
    _ownSource?.dispose();
    _ownFeed?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final tiles = widget.showTiles ?? CoverageMap.tilesByDefault;
    // A downloaded region pack covering the map wins over online tiles; no pack (or a corrupt one) means online as before.
    final offlinePack = tiles ? _pack.reader : null;
    final layers = widget.layers;
    _ensureSorted();
    _ensureMarkers();
    final latest = _latestCache;
    final pos = widget.position;
    final heardMode = widget.heard != null;
    final showLinks = widget.showLinks && layers.links;
    final layerState = widget.layerState ?? layers.toLayerState().toggle(kLabelsLayerId, true);
    final networkSource = widget.repeaterSource;
    final rosterSource = layerState.isOn(kRosterLayerId) ? _rosterSource() : null;
    final showNetwork = networkSource != null && layerState.isOn(kNetworkLayerId);

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
              final z = _controller.camera.zoom;
              if (z != _lastZoom) {
                _lastZoom = z;
                widget.onZoomChanged?.call(z); // the host's resolution starts right, not at its res-9 default
              }
              if (z != _zoomNow) {
                final before = hexResolution, captionsBefore = _captions;
                _zoomNow = z;
                if (before != hexResolution || captionsBefore != _captions) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? setState(() {}) : null);
              }
              if (_selectedRepeater != null && widget.highlightKey == _selectedRepeater) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) _focusRepeater(_selectedRepeater!);
                });
              }
            },
            onTap: (_, point) {
              final hit = widget.layers.networkCoverage ? networkCellAt(widget.networkCells, point) : null;
              if (hit == null) {
                _clearLinks(); // a tap on nothing puts the lines away
                return;
              }
              _showCellLinks(hit);
            },
            onPositionChanged: (camera, hasGesture) {
              if (tiles && _pack.update(camera.center.latitude, camera.center.longitude)) setState(() {});
              if (camera.zoom != _lastZoom) {
                _lastZoom = camera.zoom;
                widget.onZoomChanged?.call(camera.zoom);
              }
              // The drive's hexagons follow the zoom: a new resolution band redraws them at once (a pinch crosses
              // a band boundary mid-gesture; the cells must not wait for the network fetch).
              if (_zoomNow != camera.zoom) {
                final before = hexResolution, captionsBefore = _captions;
                _zoomNow = camera.zoom;
                if (before != hexResolution || captionsBefore != _captions) setState(() {});
              }
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
            if (offlinePack != null)
              OfflineBasemapLayer(key: ValueKey('offline-pack-${_pack.code}'), reader: offlinePack)
            else if (tiles)
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
            if (layers.networkCoverage && widget.networkCells.isNotEmpty)
              PolygonLayer(
                polygons: [
                  for (final n in widget.networkCells)
                    Polygon(
                      points: [for (final b in n.boundary) LatLng(b.lat, b.lon)],
                      color: networkLevelColor(context, n.level).withValues(alpha: n.level == CoverageLevel.none ? 0.10 : 0.34),
                      borderColor: networkLevelColor(context, n.level).withValues(alpha: n.level == CoverageLevel.none ? 0.25 : 0.8),
                      borderStrokeWidth: 1,
                    ),
                ],
              ),
            if (widget.showRings && layers.rings && pos != null) _RangeRings(center: pos, color: t.colorScheme.primary, ringMetres: AppScope.unitsOf(context).rangeRingMetres),
            if (widget.showRings && layers.rings && pos != null && _captions)
              MarkerLayer(
                markers: [
                  for (final (i, ringM) in AppScope.unitsOf(context).rangeRingMetres.indexed)
                    Marker(
                      point: _offsetNorth(pos, -ringM),
                      width: 44,
                      height: 18,
                      child: Center(
                        child: Text(
                          AppScope.unitsOf(context).rangeRingLabels[i],
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
            if (layers.hexes)
              KeyedSubtree(
                // The resolution is in the key so a test (and a screenshot) can see which band is on screen.
                key: ValueKey('drive-hexes-res-$hexResolution'),
                child: PolygonLayer(
                  polygons: [
                    for (final h in _ensureHexes())
                      Polygon(
                        points: [for (final b in h.boundary) LatLng(b.lat, b.lon)],
                        color: (h.wasHeard ? mc.forPing(heard: true, snr: h.bestSnrDb) : mc.silent).withValues(alpha: h.wasHeard ? 0.34 : 0.22),
                        borderColor: (h.wasHeard ? mc.forPing(heard: true, snr: h.bestSnrDb) : mc.silent).withValues(alpha: 0.75),
                        borderStrokeWidth: 1.2,
                      ),
                  ],
                ),
              ),
            if (_currentLinks() case final ls?) ...linkLineLayers(context, ls, labels: _captions || hexResolution >= 9),
            if (showNetwork)
              RepeaterClusterLayer(source: networkSource, layerId: kNetworkLayerId, selectedKey: _selectedRepeater, onHit: _onHit),
            if (rosterSource != null)
              RepeaterClusterLayer(source: rosterSource, layerId: kRosterLayerId, selectedKey: _selectedRepeater, onHit: _onHit),
            if (layerState.isOn('observers') && widget.observers.isNotEmpty)
              ObserverLayer(observers: widget.observers, regionName: widget.observersRegionName, onHit: _onHit),
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
                        name: r.name,
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
            if (liveLinks.isNotEmpty && _captions)
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
                            text: AppScope.unitsOf(context).distance(approx: true, haversineM(origin.latitude, origin.longitude, h.ref!.lat, h.ref!.lon)),
                            color: h.phase == HeardPhase.fresh ? mc.beacon : t.colorScheme.outline,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            if (layers.repeaters && heardMode && _captions)
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
            if (layerState.isOn(kLabelsLayerId))
              RepeaterNameLabels(
                markers: [
                  if (layers.repeaters)
                    for (final r in _markerRepeaters)
                      MarkerLabelInput(
                        key: r.key,
                        name: _plainName(r),
                        point: LatLng(r.lat, r.lon),
                        heard: _heardByKey.containsKey(r.key),
                        // A live heard repeater already carries its name + SNR tag.
                        ownTag: _captions && heardMode && (_heardByKey[r.key]?.live ?? false),
                      ),
                ],
                clustered: [
                  if (rosterSource != null) (rosterSource, kRosterLayerId),
                  if (showNetwork) (networkSource, kNetworkLayerId),
                ],
                selectedKey: _selectedRepeater,
                origin: origin,
                blockers: [
                  for (final h in liveLinks) LatLng((origin!.latitude + h.ref!.lat) / 2, (origin.longitude + h.ref!.lon) / 2),
                  if (widget.showRings && layers.rings && pos != null)
                    for (final m in AppScope.unitsOf(context).rangeRingMetres) _offsetNorth(pos, -m),
                ],
                inset: widget.overlayPadding + const EdgeInsets.only(bottom: 30),
                avoid: (size) => _overlayRects(),
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
            key: _stackKey,
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_panel(context) case final panel?) ...[panel, const SizedBox(height: Gap.xs)],
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
              // The global repeater layer's legend and credit (its data is MeshCore Map's), only while it draws.
              if (showNetwork)
                ListenableBuilder(
                  listenable: networkSource,
                  builder: (context, _) {
                    if (networkSource.globalPoints.length == 0) return const SizedBox.shrink();
                    final set = networkSource.feed.global;
                    return Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: _Pill(
                        key: const Key('map-network-attribution'),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            NetworkAgeLegend(set: set, dense: true),
                            if (set.attribution != null)
                              Text(set.attribution!, style: t.textTheme.labelSmall?.copyWith(fontSize: 11)),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
        Positioned(
          right: Gap.m + widget.overlayPadding.right,
          bottom: Gap.m + widget.overlayPadding.bottom,
          child: Column(
            key: _buttonsKey,
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

  final GlobalKey _stackKey = GlobalKey(debugLabel: 'map-credit-stack');
  final GlobalKey _buttonsKey = GlobalKey(debugLabel: 'map-buttons');

  /// Where the overlays sit, in this map's own coordinates (the credit stack, the recenter/compass buttons and the
  /// parent's [CoverageMap.labelAvoidKeys]), a little inflated. Read at paint time, so one frame behind a layout change.
  List<Rect> _overlayRects() {
    if (!mounted) return const [];
    try {
      final mapBox = context.findRenderObject();
      if (mapBox is! RenderBox || !mapBox.hasSize) return const [];
      final out = <Rect>[];
      for (final k in [_stackKey, _buttonsKey, ...widget.labelAvoidKeys]) {
        final c = k.currentContext;
        if (c == null || !c.mounted) continue;
        final o = c.findRenderObject();
        if (o is! RenderBox || !o.hasSize || !o.attached) continue;
        out.add(MatrixUtils.transformRect(o.getTransformTo(mapBox), Offset.zero & o.size).inflate(4));
      }
      return out;
    } catch (_) {
      return const []; // a route is being replaced: no overlays this frame
    }
  }

  /// The name for a map label: no directory lookups for the hundreds of markers in view.
  String _plainName(RepeaterRef r) =>
      r.name.isNotEmpty ? r.name : (_heardByKey[r.key]?.label ?? r.key.substring(0, math.min(8, r.key.length)));

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
    if (here != null) parts.add(AppScope.unitsOf(context).distance(approx: true, haversineM(here.latitude, here.longitude, r.lat, r.lon)));
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
              Flexible(
                child: Text(
                  'SIMULATED GPS & RADIO',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.textTheme.labelSmall?.copyWith(
                    color: mc.onBeacon,
                    fontSize: dense ? 9 : 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.6,
                    height: 1.1,
                  ),
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

  /// Spoken by VoiceOver (the written name is on the map as a label).
  final String name;
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
    required this.name,
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
    return Semantics(
      button: true,
      label: name.isEmpty ? 'Repeater ${repeaterKey.substring(0, math.min(4, repeaterKey.length))}' : 'Repeater $name',
      hint: 'Shows repeater details',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: child),
    );
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
    return Semantics(
      button: true,
      label: detail == null ? name : '$name, $detail',
      hint: 'Shows repeater details',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(onTap: onTap, child: box),
    );
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

/// Dashed range rings (1 km / 2 km, or 0.5 mi / 1 mi) around the current position, drawn directly so they stay crisp at any zoom.
class _RangeRings extends StatelessWidget {
  final LatLng center;
  final Color color;
  final List<double> ringMetres;
  const _RangeRings({required this.center, required this.color, required this.ringMetres});
  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    return IgnorePointer(
      child: CustomPaint(painter: _RingPainter(camera, center, color, ringMetres), size: Size.infinite),
    );
  }
}

class _RingPainter extends CustomPainter {
  final MapCamera camera;
  final LatLng center;
  final Color color;
  final List<double> ringMetres;
  _RingPainter(this.camera, this.center, this.color, this.ringMetres);

  @override
  void paint(Canvas canvas, Size size) {
    final c = camera.latLngToScreenOffset(center);
    for (final m in ringMetres) {
      final edge = camera.latLngToScreenOffset(LatLng(center.latitude + m / 111320.0, center.longitude));
      final r = (c - edge).distance;
      if (r < 6 || r > 6000) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = color.withValues(alpha: m == ringMetres.first ? 0.55 : 0.35);
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
      old.ringMetres.first != ringMetres.first ||
      old.camera.center != camera.center ||
      old.camera.zoom != camera.zoom;
}
