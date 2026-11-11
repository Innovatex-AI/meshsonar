// CoverageMap: the live wardrive map, reusable on the Drive screen, the full-screen map and the drive detail screen.
//
// Usage:
//   CoverageMap(
//     pings: pings,                       // every ping to draw, any order (dots coloured by result or SNR)
//     repeaters: state.repeaters,         // RepeaterRef cache: amber beacon markers, name on tap
//     position: LatLng(fix.lat, fix.lon), // optional "you are here"; follow mode keeps it where it is on the screen
//     repeaterLabel: state.repeaterLabel, // optional: prefix -> display name for the link labels
//     heard: heardSnapshot(state.heard),  // optional: live/holding/stale repeaters (Drive screen)
//     layerState: kDefaultLayerState,     // optional: which registry layers are on (and the Pings colour mode)
//     networkCells: cells,                // optional: network-wide coverage cells (GET public-coverage)
//   )
//
// Live drive: pass `position` and leave `follow: true`. Follow keeps the position where it is on the screen (never re-pins it,
// never zooms). Any pan, zoom, pinch or rotate turns follow off and the camera is then never moved by code (pings, fixes,
// coverage, panel changes) until the Recenter button is tapped (lib/core/camera_follow.dart). Drive detail: pass
// `follow: false, fitToPings: true` to frame the whole drive.
//
// What's drawn, bottom to top:
//   1. A chart grid on the map background (so the map looks intentional with no tiles / no signal).
//   2. OpenStreetMap tiles (colour-graded to the theme; cached; failures fall back to the grid, never an error).
//   3. Network-wide measured coverage (every driver, GET /api/cmh/public-coverage, gated by
//      the `measured` layer): a quiet "where hasn't this been driven" background layer. Only cells the
//      network actually measured are tinted; everywhere else is left blank map — that absence is the gap
//      indicator, so there is no "no data" placeholder for it.
//   5. Links. With [heard]: from the current position to every LIVE heard repeater with a known location, solid
//      when heard on the latest ping, dashed while it is holding, each with a distance label. Without [heard]:
//      from the latest ping to each repeater it heard; they fade over ~15 s.
//   5b. Network layers (registry ids, layers/registry.dart): the global "All MeshCore repeaters" layer (`network`,
//      off by default) and the region roster (`repeaters`) as clustered painters from a [RepeaterMapSource], then
//      the viewed region's observers with a public position (`observers`). Taps open detail sheets through
//      showMapHitSheet (sheets/map_hit_sheet.dart); a cluster zooms to its members.
//   6. Repeaters (amber beacons). Heard ones pop up and glow while live, then grey out when stale. Tap for the name.
//   7. Ping dots: heard = the palette's SNR ramp by best SNR (-10 → +10 dB; red → yellow → green on Standard) or plain green
//      in "result" mode; heard nothing = grey. The newest dot pulses once.
//   (Measured / Predicted coverage v2 are MVT tiles coloured by the mean-SNR band, coverage_bands.dart.)
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
import 'dart:async' show StreamController, StreamSubscription, Timer, unawaited;
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'package:h3_flutter/h3_flutter.dart' show GeoCoord, H3;

import '../../core/heard.dart' show RepeaterLookup, haversineM;
import '../../core/coverage_query.dart' show coverageResForZoom;
import '../../core/api.dart' show CmatException;
import '../../core/hex_cells.dart';
import '../../core/map_links.dart';
import '../../core/repeater_reach.dart' show ReachTotals;
import '../../core/model.dart';
import '../../core/region_overview_api.dart' show RegionObserver;
import '../../core/region_repeaters_api.dart' show RegionRepeater;
import '../../core/network_coverage.dart';
import '../../core/coverage_v2.dart';
import 'coverage_bands.dart';
import 'coverage_tiles_layer.dart';
import 'sheets/coverage_cell_sheet.dart';
import '../../core/camera_follow.dart';
import '../../core/heading.dart' show shortestArc;
import '../../core/map_health.dart' show CameraTelemetry;
import '../../core/map_prefs.dart';
import '../theme.dart';
import '../widgets.dart';
import 'cell_sheet.dart';
import 'region_center.dart' show continentalCenter, continentalZoom;
import '../../app/app_state.dart' show AppState;
import '../app.dart' show AppScope;
import 'layers/link_lines_layer.dart';
import 'layers/map_layer.dart';
import 'layers/observer_layer.dart';
import 'layers/repeater_painter_layer.dart';
import 'layers/repeater_sprites.dart' show RepeaterFreshness, freshnessOfAdvertBand, freshnessOfRosterBand;
import 'layers/registry.dart' show definitionLayerIds, kDefaultLayerState, kHeardCellsLayerId;
import 'layers/region_borders_layer.dart';
import 'active_map_definition.dart';
import 'main_map_focus.dart';
import 'layers/repeater_map_source.dart';
import 'layers/repeater_name_labels.dart';
import 'map_info_panel.dart';
import '../../core/map_filter.dart' show GeoBounds;
import '../../core/map_styles.dart';
import 'cell_raster_layer.dart';
import 'tile_source.dart';
import '../../core/offline_packs.dart' show NetworkKind, PackSchema;
import '../../core/basemap.dart' show BasemapSource, BasemapSourceX, OurBasemap;
import '../../platform/map_prefs_store.dart' show openSharedMapPrefs;
import 'live_puck.dart';
import 'map_layers.dart';
import 'core/map_hit_resolver.dart';
import 'core/map_view_controller.dart';
import 'overlays/attribution_line.dart';
import 'overlays/credits_sheet.dart';
import 'overlays/map_overlay_host.dart';
import 'parts/chart_grid.dart';
import 'parts/map_chips.dart';
import 'overlays/map_controls.dart';
import 'parts/map_compass.dart';
import 'parts/map_markers.dart';
import 'parts/simulated_tag.dart';
import 'parts/source_chip.dart';

export 'parts/simulated_tag.dart' show SimulatedTag;
import 'basemap_layer.dart';
import 'offline_basemap.dart';
import 'sheets/map_hit_sheet.dart';
import '../ping_detail_sheet.dart' show PingDetailSheet;
import 'sheets/observer_sheet.dart' show ObserverSheetContext;
import 'sheets/repeater_sheet.dart' show RepeaterSheet, RepeaterSheetContext;
import '../claims/claim_widgets.dart' show OwnedByYouChip;

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

/// The colour of one of the drive's own hexagons ([HexCell]) in [mode] (Drive plan 7.3 F3): By SNR = the best SNR in the hexagon
/// (heard without a reading is band 6 grey, nothing heard is the No-reply colour); Heard / not = the same green the Pings layer uses
/// when any ping in the hexagon was heard, grey when none was.
Color hexColor(MeshSonarColors c, HexCell h, PingColorMode mode) => mode == PingColorMode.result
    ? (h.wasHeard ? c.snrStrong : c.silent)
    : (h.wasHeard ? c.forPing(heard: true, snr: h.bestSnrDb) : c.silent);

/// Colour for a network-coverage [CoverageLevel] on the old path (a server without coverage v2): the website's former discrete
/// `/coverage` steps (standard palette: red -> yellow -> green, no blue since build 51), from the chosen colour palette
/// ([MeshSonarColors.levelColor]). [CoverageLevel.none] (nothing heard) is the No-reply colour and [CoverageLevel.unknown] (heard,
/// signal unknown) is band 6 in every palette.
Color networkLevelColor(BuildContext context, CoverageLevel level) => MeshSonarColors.of(context).levelColor(level);

/// The colour matrix [style]'s online raster tiles are drawn through. Since M2 none: Chart / Light / Dark are our vector
/// tiles already drawn in the website's light / dark styles, and Topo is shown as its tile server made it.
List<double>? tileMatrixFor(BaseMapStyle style, List<double> themeMatrix) =>
    style.ungraded ? null : (style.forcesDark ? kDarkTileMatrix : themeMatrix);

/// Below this pane height the map's compass / heading / recenter buttons move left of the tool column.
const double kCompactMapHeight = 380;

/// What a map needs to draw coverage v2 (see [CoverageMap.coverageV2]).
@immutable
class CoverageV2Inputs {
  final CoverageTileStore tiles;
  final CoverageMeta meta;

  /// Tiles draw (live, unfiltered, online); false = the measured layer draws the JSON cells and the predicted layer hides.
  final bool drawTiles;

  /// The inspector read (`/api/coverage/cell/{h3}`); null = the panel shows what the tap knows.
  final Future<CoverageCellInfo> Function(String h3)? fetchCell;

  /// The server has the Heard (no ping) layer (`capabilities.coverageHeard`).
  final bool heard;
  const CoverageV2Inputs({required this.tiles, required this.meta, this.drawTiles = true, this.fetchCell, this.heard = false});
}

class CoverageMap extends StatefulWidget {
  /// Pings to draw. Order doesn't matter; the newest (by timestamp) gets the links and the pulse.
  final List<DrivePing> pings;

  /// Known repeaters (from the CMAT repeater cache).
  final List<RepeaterRef> repeaters;

  /// Current position, if known. With a [puck] this is the slow position (it refreshes every ~20 m or 2 s, enough for
  /// labels and the first zoom-in); the dot and the camera follow the puck itself, frame by frame.
  final LatLng? position;

  /// The live puck (lib/ui/map/live_puck.dart): when set, the dot, heading cone, ping rings and the lines
  /// to the repeaters that heard the latest ping are drawn from it without rebuilding the map on each GPS fix.
  final PuckController? puck;

  /// Follow [position] (keeping it where it is on the screen) until the person moves the map.
  final bool follow;

  /// Frame all pings when the map first opens (drive detail). Ignored if there are fewer than 2 pings.
  final bool fitToPings;

  /// Draw links from the newest ping to the repeaters it heard.
  final bool showLinks;

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

  /// The viewed region's bounds, when known: with no position and no pings the map frames these (not just their centre).
  final LatLngBounds? fallbackBounds;

  /// Extra space at the edges for overlays drawn on top of the map by the parent (e.g. a chip row).
  final EdgeInsets overlayPadding;

  /// Who's in range this drive (live first). When set, repeater markers and links follow it.
  final List<HeardView>? heard;

  /// Network-wide measured coverage cells (e.g. from `CmatClient.publicCoverage()`), drawn as the background
  /// "where hasn't this been driven" layer when the `measured` layer is on. Empty/not-yet-loaded draws
  /// nothing — there is no placeholder for "no data"; absence of a drawn cell is the point.
  final List<NetworkCell> networkCells;

  /// The region's whole repeater roster, drawn (clustered, tap for a sheet) when the `repeaters` layer is on.
  /// Used only when no [repeaterSource] is given; with one, the roster comes from the source.
  final List<RegionRepeater> regionRepeaters;

  /// Both repeater lists, render-ready (global `network` layer + region roster `repeaters` layer). Owned by the host
  /// (e.g. DriveMapModel); the map never disposes it.
  final RepeaterMapSource? repeaterSource;

  /// Which registry layers are on, plus the Pings colour mode (`modeOf('pings')`). The one layer system (Drive plan 7.1).
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

  /// Coverage v2 (server capability `coverageV2`): the tile store and meta for the Measured / Predicted layers, whether the tiles
  /// draw now, and the cell inspector read. Also switches "This drive" to res-11 mean-SNR cells. Null = the old path.
  final CoverageV2Inputs? coverageV2;

  /// The colour key for what this map is drawing (see map_key.dart): shown in the Credits sheet, not on the map. Null = none.
  final Widget? mapKey;

  /// The viewed region's border rings (the definition's `borders` layer, region_borders_layer.dart); empty = none.
  final List<List<LatLng>> regionBorders;

  /// The legend card (legend_card.dart), shown under the top-leading chips; null = none.
  final Widget? legend;

  /// This is the main map (the Drive tab's): it answers "Open the map here" from previews (main_map_focus.dart).
  final bool takesFocusRequests;

  /// "What do the colours mean?" in the Credits sheet. Null = no button.
  final VoidCallback? openLegend;

  /// The camera and follow state shared with the host (the Drive model owns one for the whole app session, so the in-tab map and
  /// the expanded map are the same camera). Null = this map makes its own and disposes it.
  final MapViewController? viewController;

  // Overlay slots (MapOverlayHost, overlays/map_overlay_host.dart). The map mounts the host and the attribution line itself, so
  // no screen can forget the credit; screens only fill the slots.
  final Widget? banner;
  final Widget? topLeading;
  final Widget? topTrailing;
  final Widget? bottom;

  /// New Drive screen: when set, the map's controls slot holds the fixed-slot [MapControlColumn] (Layers + Recenter / heading +
  /// Compass) and this opens the layers sheet. Null = the older FAB buttons.
  final VoidCallback? onLayers;

  /// Inspector rules while a drive runs (Drive plan 4.9): [inspectorLocked] keeps it at the one-line peek ("Open when stopped"),
  /// [inspectorAutoClear] closes it after that long without a touch.
  final bool inspectorLocked;
  final Duration? inspectorAutoClear;

  /// Overlay clearances (see MapOverlayHost.topClearance / bottomClearance): the full-bleed Drive map keeps its slots out of the
  /// status bar and above the panel without ever being resized.
  final double topClearance;
  final double bottomClearance;

  /// The base map under the data (street / dark / topo cycler). Offline region packs are drawn for every style that
  /// [BaseMapStyle.usesOfflinePack].
  final BaseMapStyle baseStyle;

  /// Called (after the frame) with the part of the world on screen when the map opens and as it moves: the host works out
  /// the coverage % of the view from it.
  final ValueChanged<GeoBounds>? onBoundsChanged;

  /// What the camera tells the "Map and GPS health" recorder (mode, zoom, frames driven). Optional.
  final CameraTelemetry? telemetry;

  /// The remembered map choices (heading-up, auto re-centre, zoom by speed). Null = the app-wide [MapPrefs.shared].
  final MapPrefs? prefs;

  const CoverageMap({
    super.key,
    required this.pings,
    this.repeaters = const [],
    this.position,
    this.follow = true,
    this.puck,
    this.fitToPings = false,
    this.showLinks = true,
    this.interactive = true,
    this.rotatable = false,
    this.showTiles,
    this.repeaterLabel,
    this.fallbackCenter,
    this.fallbackBounds,
    this.overlayPadding = EdgeInsets.zero,
    this.heard,
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
    this.coverageV2,
    this.hexRes,
    this.mapKey,
    this.regionBorders = const [],
    this.legend,
    this.takesFocusRequests = false,
    this.openLegend,
    this.viewController,
    this.banner,
    this.topLeading,
    this.topTrailing,
    this.bottom,
    this.onLayers,
    this.inspectorLocked = false,
    this.inspectorAutoClear,
    this.topClearance = 0,
    this.bottomClearance = 0,
    this.baseStyle = BaseMapStyle.chart,
    this.onBoundsChanged,
    this.telemetry,
    this.prefs,
  });

  /// True unless running under `flutter test`.
  /// Tests only: the HTTP client the tile provider uses (serves real tile files from disk).
  static http.Client? debugTileClient;

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

  static const String userAgentPackageName = 'com.meshsonar.app';

  @override
  State<CoverageMap> createState() => _CoverageMapState();
}

class _CoverageMapState extends State<CoverageMap> {
  static final StrokePattern _dashed = StrokePattern.dashed(segments: const [10, 8]);
  late final MapViewController _vc = widget.viewController ?? MapViewController();
  late final bool _ownsVc = widget.viewController == null;
  MapController get _controller => _vc.map;
  final MapHitResolver _hits = MapHitResolver();
  bool _ready = false;
  // Follow state: the camera drives itself until the person moves the map (lib/core/camera_follow.dart).
  CameraFollow get _fc => _vc.follow;
  MapPrefs get _prefs => widget.prefs ?? MapPrefs.shared;
  DateTime _now() => widget.puck?.clock() ?? DateTime.now();
  bool get _follow => _fc.following;
  set _follow(bool v) {
    if (v) {
      _fc.resume();
    } else {
      _vc.followOffset = null;
      _fc.userMoved();
    }
  }

  double get _userZoom => _vc.userZoom;
  set _userZoom(double v) => _vc.userZoom = v;
  double get _zoomOffset => _vc.zoomOffset;
  set _zoomOffset(double v) => _vc.zoomOffset = v;
  ValueNotifier<double> get _rotationN => _vc.rotation;
  DateTime _lastBounds = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _boundsTimer;
  final StreamController<void> _tileReset = StreamController<void>.broadcast();
  MeshTileProvider? _tileProvider;
  final MapTileStats _tileStats = MapTileStats.instance;
  StreamSubscription<NetworkKind>? _netSub;
  String? _selectedRepeater;
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

  // The drive's repeaters as painter badges, rebuilt only when their inputs change (the label placer keys on identity).
  List<RepeaterBadge> _badges = const [];
  Object? _badgeKey;

  /// Heard > roster > network (plan 6.1): the drive's repeaters are drawn as badges; both lists leave those keys out of
  /// their points and clusters, and lend their colour band and last advert to the badge.
  List<RepeaterBadge> _badgesFor(RepeaterMapSource? roster, RepeaterMapSource? network, bool on, String? legacyLitId, Set<String> legacyLit) {
    final key = Object.hash(
      identityHashCode(_markerRepeaters),
      identityHashCode(_heardByKey),
      roster?.revision,
      network?.revision,
      identical(roster, network),
      on,
      _captions,
      legacyLitId,
      _selectedRepeater,
      widget.heard == null,
    );
    if (_badgeKey == key) return _badges;
    // "Heard this drive" draws only the repeaters this drive heard, the newest ping's, and the selected one (F2); every other
    // known repeater is the roster / network layers' business.
    final drawn = on ? [for (final r in _markerRepeaters) if (_drawnAsHeard(r.key, legacyLit)) r] : const <RepeaterRef>[];
    final claimed = {for (final r in drawn) r.key};
    for (final s in {?roster, ?network}) {
      s.claimedKeys = claimed;
    }
    final out = <RepeaterBadge>[];
    if (on) {
      for (final r in drawn) {
        final h = _heardByKey[r.key];
        final info = roster?.claimedInfo(r.key) ?? network?.claimedInfo(r.key);
        final heard = h != null || legacyLit.contains(r.key);
        final RepeaterFreshness f;
        if (heard) {
          f = RepeaterFreshness.fresh;
        } else if (info != null) {
          f = info.layerId == kRosterLayerId ? freshnessOfRosterBand(info.band) : freshnessOfAdvertBand(info.band);
        } else {
          f = RepeaterFreshness.stale;
        }
        out.add(RepeaterBadge(
          key: r.key,
          name: _plainName(r),
          lat: r.lat,
          lon: r.lon,
          isRoom: r.isRoom,
          freshness: f,
          heard: heard,
          heardLast: h != null && h.pingsAgo == 0,
          lastSeen: info?.lastSeen,
          snr: _captions && h != null && h.live && h.snrDb != null ? formatSnrShort(h.snrDb!) : null,
        ));
      }
    }
    _badgeKey = key;
    return _badges = out;
  }

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

  /// Coverage v2 inspector: the tapped res-11 cell and its answer (null while loading or when the read failed).
  ({String h3, double lat, double lon})? _panelV2;
  CoverageCellInfo? _v2Info;
  DrivePing? _panelPing;
  final ScrollController _pingScroll = ScrollController();
  RepeaterPoint? _panelPoint;
  ReachTotals? _reachTotals;

  AppState? _appOrNull() {
    final w = context.getElementForInheritedWidgetOfExactType<AppScope>()?.widget;
    return w is AppScope ? w.notifier : null;
  }

  /// The lines at the resolution drawn now (a repeater's reach is re-bucketed when the zoom crosses a band).
  LinkSet? _currentLinks() {
    // The `links` switch gates every link line, the live puck lines and the ones drawn after a tap (Drive plan 7.3 F9).
    if (!(widget.layerState ?? kDefaultLayerState).isOn('links')) return null;
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
    if (_linkId == null && _panelCell == null && _panelPoint == null && _panelPing == null && _panelV2 == null) return;
    _linkGen++;
    setState(() {
      _linkId = null;
      _linkBuild = null;
      _linkSet = null;
      _linkBusy = false;
      _linkError = null;
      _linkUnplaced = 0;
      _panelCell = null;
      _panelV2 = null;
      _v2Info = null;
      _panelPoint = null;
      _panelPing = null;
      _reachTotals = null;
    });
  }

  /// What a tap at [p] hits on the coverage v2 layers, top first: this drive's cells, measured (tiles or saved cells), then
  /// predicted. Zoomed in (hexagons) it is the res-11 cell under the finger; zoomed out (dots) the nearest dot within 12 px.
  ({String h3, double lat, double lon})? _coverageHit(CoverageV2Inputs v2, MapLayerState ls, LatLng p) {
    final h3 = CoverageMap.hexEngine;
    if (h3 == null) return null;
    final zoom = _controller.camera.zoom;
    String cellOf(double lat, double lon) => hexId(h3.geoToCell(GeoCoord(lon: lon, lat: lat), kCoverageV2Res));
    final dots = zoom < v2.meta.hexFromZoom;
    final tz = coverageTileZoom(zoom);
    if (!dots) {
      final id = cellOf(p.latitude, p.longitude);
      final drawn = (ls.isOn('hexes') && _ensureHexes().any((h) => h.id == id)) ||
          (ls.isOn('measured') &&
              (v2.drawTiles
                  ? coverageTileHit(v2.tiles, CoverageTileLayer.measured, v2.meta, p.latitude, p.longitude, tz) != null
                  : widget.networkCells.any((n) => n.cell?.h3 == id))) ||
          (ls.isOn('predicted') && v2.drawTiles && coverageTileHit(v2.tiles, CoverageTileLayer.predicted, v2.meta, p.latitude, p.longitude, tz) != null) ||
          (v2.heard && ls.isOn(kHeardCellsLayerId) && v2.drawTiles &&
              coverageTileHit(v2.tiles, CoverageTileLayer.heard, v2.meta, p.latitude, p.longitude, tz) != null);
      return drawn ? (h3: id, lat: p.latitude, lon: p.longitude) : null;
    }
    // Dots: 12 px in degrees of longitude at this zoom (latitude is close enough at these sizes).
    final r = 12 * 360 / (256 * math.pow(2, zoom));
    ({double lat, double lon})? best;
    var bestD = r * r;
    void consider(double lat, double lon) {
      final d = (lat - p.latitude) * (lat - p.latitude) + (lon - p.longitude) * (lon - p.longitude);
      if (d <= bestD) {
        bestD = d;
        best = (lat: lat, lon: lon);
      }
    }

    if (ls.isOn('hexes')) {
      for (final h in _ensureHexes()) {
        if (h.center != null) consider(h.center!.lat, h.center!.lon);
      }
    }
    if (best == null && ls.isOn('measured')) {
      if (v2.drawTiles) {
        final h = coverageTileHit(v2.tiles, CoverageTileLayer.measured, v2.meta, p.latitude, p.longitude, tz, radiusDeg: r);
        if (h != null) consider(h.lat, h.lon);
      } else {
        for (final n in widget.networkCells) {
          if (n.cell != null) consider(n.cell!.lat, n.cell!.lon);
        }
      }
    }
    if (best == null && v2.heard && ls.isOn(kHeardCellsLayerId) && v2.drawTiles) {
      final h = coverageTileHit(v2.tiles, CoverageTileLayer.heard, v2.meta, p.latitude, p.longitude, tz, radiusDeg: r);
      if (h != null) consider(h.lat, h.lon);
    }
    if (best == null && ls.isOn('predicted') && v2.drawTiles && zoom >= v2.meta.predictedFromZoom) {
      final h = coverageTileHit(v2.tiles, CoverageTileLayer.predicted, v2.meta, p.latitude, p.longitude, tz, radiusDeg: r);
      if (h != null) consider(h.lat, h.lon);
    }
    final b = best;
    return b == null ? null : (h3: cellOf(b.lat, b.lon), lat: b.lat, lon: b.lon);
  }

  /// Opens the inspector for one res-11 cell and draws lines to the repeaters that served it (keys resolved to names the same
  /// way cell-links does: an exact key, else a unique prefix among the drawn repeaters).
  Future<void> _showCoverageCell(CoverageV2Inputs v2, String id, double lat, double lon) async {
    final h3 = CoverageMap.hexEngine;
    var cLat = lat, cLon = lon;
    if (h3 != null) {
      final g = h3.cellToGeo(BigInt.parse(id, radix: 16));
      cLat = g.lat;
      cLon = g.lon;
    }
    _beginLinks('cell:$id', 'This cell');
    setState(() {
      _panelV2 = (h3: id, lat: cLat, lon: cLon);
      _v2Info = null;
      _panelCell = null;
      _panelPoint = null;
      _panelPing = null;
    });
    final fetch = v2.fetchCell;
    if (fetch == null) {
      setState(() => _linkBusy = false);
      return;
    }
    final gen = _linkGen;
    try {
      final info = await fetch(id);
      if (!mounted || gen != _linkGen) return;
      final reps = info.measured?.repeaters ?? const <CoverageCellRepeater>[];
      final placed = cellEnds(
        CellLinks(h3: id, links: [for (final r in reps) CellLink(key: r.key, pings: r.n, bestSnr: r.snrMax, medianSnr: r.snrMean)]),
        _placeRepeater,
      );
      setState(() {
        _v2Info = info;
        _linkBusy = false;
        _linkUnplaced = placed.unplaced;
        _linkBuild = (_) => LinkSet(id: 'cell:$id', lat: cLat, lon: cLon, title: 'This cell', ends: placed.ends, unplaced: placed.unplaced);
      });
    } catch (e) {
      if (!mounted || gen != _linkGen) return;
      setState(() {
        _linkBusy = false;
        _linkError = "Couldn't load this cell. Check your connection.";
      });
    }
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

  bool _isRefusal(Object e) => e is CmatException && (e.status == 401 || e.status == 403);

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
      _panelPing = null;
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
      if (_isRefusal(e)) {
        // The server refused the public read (401/403): fall back to the panel alone, silently (Drive plan 7.3 F8).
        _clearLinks();
        setState(() => _panelPoint = p);
        return;
      }
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
    final r = _refFor(key) ?? _refForPrefix(key);
    return r == null ? null : (lat: r.lat, lon: r.lon, name: _nameFor(r));
  }

  /// The drive's own repeater whose key starts with [id] (echo ids are short prefixes), only when exactly one does.
  RepeaterRef? _refForPrefix(String id) {
    if (id.length < 2) return null;
    _ensureMarkers();
    RepeaterRef? hit;
    for (final r in _markerRepeaters) {
      if (!r.key.startsWith(id.toLowerCase())) continue;
      if (hit != null) return null;
      hit = r;
    }
    return hit;
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
      _panelPing = null;
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
      if (_isRefusal(e)) {
        _clearLinks();
        setState(() => _panelCell = n);
        return;
      }
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
    final p = _panelPoint, cell = _panelCell, ping = _panelPing, v2 = _panelV2;
    if (p == null && cell == null && ping == null && v2 == null) return null;
    if (v2 != null && p == null && ping == null) {
      final set = _currentLinks();
      final info = _v2Info;
      final mine = _ensureHexes().where((h) => h.id == v2.h3).firstOrNull;
      final meta = widget.coverageV2?.meta ?? CoverageMeta.fallback;
      return MapInfoPanel(
        key: ValueKey('info-panel-v2-${v2.h3}'),
        title: info?.measured != null ? 'Measured cell' : (info?.predicted != null ? 'Predicted cell' : 'Coverage cell'),
        summary: _linkBusy
            ? 'Loading…'
            : (_linkError ?? coverageCellSummary(info, meta, mine: mine, unplaced: _linkUnplaced)),
        busy: _linkBusy,
        body: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CoverageCellSheet(info: info, meta: meta, mine: mine, h3: v2.h3, repeaterName: (k) => _placeRepeater(k)?.name),
              if (!_linkBusy && _linkError == null && (set?.ends.isNotEmpty ?? false)) CellRepeaterList(ends: set!.ends),
            ],
          ),
        ),
        onFit: !_linkBusy && (set?.ends.isNotEmpty ?? false) ? _fitLinks : null,
        onClose: _clearLinks,
        locked: widget.inspectorLocked,
        autoClear: widget.inspectorAutoClear,
      );
    }
    if (ping != null) {
      final set = _currentLinks();
      final lookup = _appOrNull()?.lookup ?? RepeaterLookup.empty;
      final n = set?.ends.length ?? 0;
      final best = bestSnr(ping);
      final summary = ping.kind == PingKind.rx
          ? 'Heard a packet'
          : ping.heardNothing
          ? 'Heard nothing  ·  mapped, no signal'
          : 'Heard ${ping.echoes.length} repeater${ping.echoes.length == 1 ? '' : 's'}${best == null ? '' : '  ·  best ${formatSnrShort(best)} dB'}${_linkUnplaced > 0 ? '  ·  $_linkUnplaced not on the map' : ''}';
      return MapInfoPanel(
        key: ValueKey('info-panel-ping-${ping.id}'),
        title: 'Ping at ${ping.ts.toLocal().hour.toString().padLeft(2, '0')}:${ping.ts.toLocal().minute.toString().padLeft(2, '0')}',
        summary: summary,
        busy: false,
        body: PingDetailSheet(ping: ping, lookup: lookup, scrollController: _pingScroll),
        onFit: n > 0 ? _fitLinks : null,
        onClose: _clearLinks,
        locked: widget.inspectorLocked,
        autoClear: widget.inspectorAutoClear,
      );
    }
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
      badge: p != null && (_appOrNull()?.ownsRadio(p.key) ?? false) ? const OwnedByYouChip() : null,
      summary: _panelSummary(),
      busy: _linkBusy,
      body: body,
      onFit: canFit ? _fitLinks : null,
      onClose: _clearLinks,
      locked: widget.inspectorLocked,
      autoClear: widget.inspectorAutoClear,
    );
  }

  /// A repeater from the drive's own list (the amber markers) as the point the panel works with: the network or
  /// roster row when one has it, else what the marker knows.
  RepeaterPoint _pointForRef(RepeaterRef r) {
    for (final src in [_rosterSource(), widget.repeaterSource]) {
      if (src == null) continue;
      for (final layer in [kRosterLayerId, kNetworkLayerId]) {
        final i = src.pointsOf(layer).indexOf(r.key);
        if (i >= 0) return src.pointAt(layer, i);
      }
    }
    return RepeaterPoint(
      layerId: kNetworkLayerId,
      source: RepeaterPointSource.global,
      key: r.key,
      name: _nameFor(r),
      isRoom: r.isRoom,
      lat: r.lat,
      lon: r.lon,
      band: 0,
    );
  }

  /// Tap a ping dot: a line to every repeater that heard it, labelled with its SNR, and the ping's own details.
  void _showPingLinks(DrivePing p) {
    final app = _appOrNull();
    final lookup = app?.lookup;
    final ends = <LinkEnd>[];
    var unplaced = 0;
    for (final e in p.echoes) {
      final ref = lookup?.resolve(e.repeater).ref;
      final placed = ref != null ? (lat: ref.lat, lon: ref.lon, name: _nameFor(ref)) : _placeRepeater(e.repeater);
      if (placed == null) {
        unplaced++;
        continue;
      }
      ends.add(LinkEnd(lat: placed.lat, lon: placed.lon, id: e.repeater, name: placed.name, pings: 1, snr: e.snrDb));
    }
    _linkGen++;
    setState(() {
      _linkId = 'ping:${p.id}';
      _linkBusy = false;
      _linkError = null;
      _linkUnplaced = unplaced;
      _panelPing = p;
      _panelPoint = null;
      _panelCell = null;
      _reachTotals = null;
      _linkSet = null;
      _linkBuild = (_) => LinkSet(id: 'ping:${p.id}', lat: p.lat, lon: p.lon, title: 'Ping', ends: ends, unplaced: unplaced);
    });
  }

  void _fitLinks() {
    final s = _currentLinks();
    if (s == null || s.ends.isEmpty) return;
    setState(() => _follow = false); // the person framed these links: keep that view until Recenter
    _controller.fitCamera(CameraFit.coordinates(
      coordinates: [LatLng(s.lat, s.lon), for (final e in s.ends) LatLng(e.lat, e.lon)],
      padding: widget.overlayPadding + const EdgeInsets.all(56),
      maxZoom: 15,
    ));
  }

  /// A tap on a badge of the drive's own repeaters: select it and show its panel, a second tap puts it away.
  void _onBadgeTap(RepeaterBadge b) {
    final r = _refFor(b.key);
    if (r == null) return;
    _hits.submit(MapHitCandidate(MapHitKind.repeater, () {
      final on = _selectedRepeater != r.key;
      _select(on ? r.key : null);
      if (on) {
        _showRepeaterLinks(_pointForRef(r));
      } else {
        _clearLinks();
      }
    }));
  }

  /// A tap on a clustered repeater layer or an observer (cells come through [MapOptions.onTap]).
  void _onHit(MapHit hit) {
    // One tap, one decision (MapHitResolver): the same tap also reaches the map itself and any marker under the finger.
    _hits.submit(MapHitCandidate(hit is ObserverHit ? MapHitKind.observer : MapHitKind.repeater, () => _applyHit(hit)));
  }

  void _applyHit(MapHit hit) {
    if (!mounted) return;
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
    final v2 = widget.coverageV2 != null;
    final res = v2 ? 11 : hexResolution;
    if (identical(_hexSrc, widget.pings) && _hexSrcLen == widget.pings.length && _hexSrcRes == res) return _hexCells;
    _hexSrc = widget.pings;
    _hexSrcLen = widget.pings.length;
    _hexSrcRes = res;
    try {
      _hexCells = v2 ? buildDriveCells(widget.pings, h3, sf: presetSf(widget.coverageV2!.meta.defaultPreset)) : buildHexCells(widget.pings, h3, res: res);
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
    // Nothing of our own: the viewed region comes before the mean of whatever repeaters happen to be loaded.
    if (widget.fallbackCenter != null) return widget.fallbackCenter!;
    if (widget.repeaters.isNotEmpty) {
      var lat = 0.0, lon = 0.0;
      for (final r in widget.repeaters) {
        lat += r.lat;
        lon += r.lon;
      }
      return LatLng(lat / widget.repeaters.length, lon / widget.repeaters.length);
    }
    return continentalCenter;
  }

  double get _initialZoom {
    if (widget.position != null || widget.pings.isNotEmpty) return 13.6;
    if (widget.fallbackCenter != null) return 8;
    if (widget.repeaters.isNotEmpty) return 11;
    return continentalZoom;
  }

  CameraFit? get _initialFit {
    if (_hadCamera) return null;
    if (widget.fitToPings && widget.pings.length >= 2) {
      return CameraFit.coordinates(
        coordinates: [for (final p in widget.pings) LatLng(p.lat, p.lon)],
        padding: const EdgeInsets.all(40) + widget.overlayPadding,
        maxZoom: 15.5, // a short drive should still show its streets, not upscaled blurry tiles
      );
    }
    // Nothing of our own (no position, no pings): the viewed region's bounds come first.
    if (widget.position == null && widget.pings.isEmpty && widget.fallbackBounds != null) {
      return CameraFit.bounds(bounds: widget.fallbackBounds!, padding: const EdgeInsets.all(24) + widget.overlayPadding, maxZoom: 12);
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

  /// True when a map was mounted on this controller before: its camera is kept, the starting fit is not applied again.
  bool _hadCamera = false;

  @override
  void initState() {
    super.initState();
    _selectedRepeater = widget.highlightKey;
    _hadCamera = _vc.initialised;
    if (!_hadCamera) {
      _vc.initialised = true;
      if (!widget.follow) _fc.userMoved();
    }
    _hits.onNothing = _clearLinks; // a tap on nothing puts the lines away
    if (widget.takesFocusRequests) MainMapFocus.notifier.addListener(_onFocusRequest);
    _prefs.addListener(_onPrefs);
    if (widget.puck != null) unawaited(openSharedMapPrefs());
    if (widget.showTiles ?? CoverageMap.tilesByDefault) {
      _pack.basemap.addListener(_onPacksChanged);
      _pack.basemap.ensureOpen();
      _pack.update(_initialCenter.latitude, _initialCenter.longitude);
      _watchNetwork();
    }
  }

  /// The phone's own view of the network closes or opens the tile gate at once (no doomed requests while offline).
  /// Dev builds only (screenshot harness): switching the forced-offline switch back off re-asks for every tile, like regaining the network.
  void _onForcedOffline() {
    if (!TileFetchGate.debugForceOffline.value) _tileReset.add(null);
  }

  void _watchNetwork() {
    TileFetchGate.debugForceOffline.addListener(_onForcedOffline);
    final net = _pack.basemap.network;
    unawaited(net.current().then((k) => _tiles().gate.setPhoneOnline(k != NetworkKind.offline), onError: (Object _) {}));
    _netSub = net.changes.listen((k) {
      final online = k != NetworkKind.offline;
      _tiles().gate.setPhoneOnline(online);
      if (online) _tileReset.add(null); // tiles that failed while offline are asked for again
    }, onError: (Object _) {});
  }

  void _onPrefs() {
    if (!mounted) return;
    final was = _headingUpApplied;
    if (was && !_prefs.headingUp) _northUp(); // heading-up off: the map turns back to north
    _headingUpApplied = _prefs.headingUp;
    setState(() {});
  }

  bool _headingUpApplied = false;

  MeshTileProvider _tiles() => _tileProvider ??= MeshTileProvider(shouldSkip: _packDraws, client: CoverageMap.debugTileClient);

  /// True when the installed pack draws tile z/x/y, so no request is made for it.
  bool _packDraws(int z, int x, int y) {
    final code = _pack.code;
    if (code == null) return false;
    final ip = _pack.basemap.managerOrNull?.installed[code];
    final r = _pack.reader;
    if (ip == null || r == null || z < r.header.minZoom) return false;
    final n = math.pow(2, z).toDouble();
    final lon = (x + 0.5) / n * 360 - 180;
    final lat = math.atan(0.5 * (math.exp(math.pi * (1 - 2 * (y + 0.5) / n)) - math.exp(-math.pi * (1 - 2 * (y + 0.5) / n)))) * 180 / math.pi;
    return ip.covers(lat, lon);
  }

  // Offline region pack drawn under the overlays; follows the camera centre (see OfflinePackSelection).
  late final OfflinePackSelection _pack = OfflinePackSelection(OfflineBasemap.instance);

  void _onPacksChanged() {
    if (!mounted) return;
    _pack.refresh();
    _tileReset.add(null);
    setState(() {});
  }

  @override
  void didUpdateWidget(CoverageMap old) {
    super.didUpdateWidget(old);
    if (old.follow != widget.follow) _follow = widget.follow;
    // The viewed region changed (or the index finished loading) while there is nothing else to look at: recentre.
    final fallbackChanged = old.fallbackCenter != widget.fallbackCenter || old.fallbackBounds != widget.fallbackBounds;
    if (fallbackChanged &&
        widget.fallbackCenter != null &&
        _ready &&
        widget.position == null &&
        widget.pings.isEmpty &&
        (widget.repeaters.isEmpty || widget.fallbackBounds != null)) {
      final b = widget.fallbackBounds;
      if (b != null) {
        _controller.fitCamera(CameraFit.bounds(bounds: b, padding: const EdgeInsets.all(24) + widget.overlayPadding, maxZoom: 12));
      } else {
        _controller.move(widget.fallbackCenter!, 10);
      }
    }
    if (old.highlightKey != widget.highlightKey) {
      _selectedRepeater = widget.highlightKey;
      if (widget.highlightKey != null) _focusRepeater(widget.highlightKey!);
      return;
    }
    final pos = widget.position;
    if (!_follow || !_ready) return; // a map the person moved is never moved by code: pings and fixes just draw
    // First real GPS location after opening on an overview (zoomed out past 12): zoom in to street level, once per session.
    // Pings never change the zoom.
    if (old.position == null && pos != null && !_vc.firstFixZoomDone && _controller.camera.zoom < 12) {
      _vc.firstFixZoomDone = true;
      _vc.followOffset = null;
      _controller.move(pos, 13.6);
      return;
    }
    if (widget.puck?.pose != null) return; // the live puck drives the camera frame by frame (_onPuckFrame)
    if (pos != null) {
      if (pos != old.position) _keepAt(pos);
    } else {
      final l = _latest;
      final ol = old.pings.isEmpty ? null : old.pings.first;
      if (l != null && (ol == null || ol.id != l.id || old.pings.length != widget.pings.length)) _keepAt(LatLng(l.lat, l.lon));
    }
  }

  RepeaterRef? _refFor(String key) {
    _ensureMarkers();
    for (final r in _markerRepeaters) {
      if (r.key == key) return r;
    }
    return null;
  }

  /// "Open the map here" from a preview (map_preview.dart): look at that spot and stop following until Recenter.
  void _onFocusRequest() {
    final r = MainMapFocus.notifier.value;
    if (r == null || !_ready || !mounted) return;
    MainMapFocus.taken(r);
    _follow = false;
    _controller.move(r.at, r.zoom);
    setState(() {});
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

  /// The part of the map widget covered by overlays and the Drive screen's top / bottom clearances (panel): what follow keeps
  /// the puck out of.
  EdgeInsets get _followPad => widget.overlayPadding + EdgeInsets.only(top: widget.topClearance, bottom: widget.bottomClearance);

  /// Where [at] is on the screen under [cam], as an offset from the map widget's centre (screen pixels).
  static ({double dx, double dy}) _screenOffset(MapCamera cam, LatLng at) {
    final d = cam.projectAtZoom(at, cam.zoom) - cam.projectAtZoom(cam.center, cam.zoom);
    final r = cam.rotation * math.pi / 180;
    return (dx: d.dx * math.cos(r) - d.dy * math.sin(r), dy: d.dx * math.sin(r) + d.dy * math.cos(r));
  }

  /// The follow offset to use for [at] this frame: the remembered one (or where [at] is now), kept inside the visible area.
  ({double dx, double dy}) _followOffsetFor(MapCamera cam, LatLng at) {
    final size = cam.nonRotatedSize;
    final pad = _followPad;
    final want = _vc.followOffset ?? _screenOffset(cam, at);
    final a = keepInView(
      dx: want.dx, dy: want.dy, width: size.width, height: size.height, left: pad.left, top: pad.top, right: pad.right, bottom: pad.bottom);
    _vc.followOffset = a;
    return a;
  }

  /// The camera centre that puts [at] at screen offset [a] with zoom [z] and rotation [rot].
  static LatLng _centreFor(MapCamera cam, LatLng at, ({double dx, double dy}) a, double z, double rot) {
    final r = rot * math.pi / 180;
    final rx = a.dx * math.cos(r) + a.dy * math.sin(r);
    final ry = -a.dx * math.sin(r) + a.dy * math.cos(r);
    return cam.unprojectAtZoom(cam.projectAtZoom(at, z) - Offset(rx, ry), z);
  }

  /// Following without a live puck (position or newest ping changed): keep [at] at its place on the screen, same zoom.
  void _keepAt(LatLng at) {
    final cam = _controller.camera;
    final c = _centreFor(cam, at, _followOffsetFor(cam, at), cam.zoom, cam.rotation);
    if ((c.latitude - cam.center.latitude).abs() < 1e-9 && (c.longitude - cam.center.longitude).abs() < 1e-9) return;
    _controller.move(c, cam.zoom);
  }

  /// One display frame of the puck: while following, moves the camera so the arrow keeps its place on the screen (where it
  /// was when follow started, the middle after Recenter), from the SAME pose the arrow is drawn with, in the same frame, so
  /// there is nothing to lag or fight. The zoom is never changed (except the opt-in zoom-by-speed). A finger on the map, or a
  /// map the person moved, is left alone until the Recenter button.
  void _onPuckFrame(LatLng at, double dt) {
    final puck = widget.puck;
    if (puck == null || !_ready) return;
    final tele = widget.telemetry;
    if (tele != null) {
      tele.mode = _fc.following ? 'follow' : 'paused';
      tele.headingUp = _prefs.headingUp;
    }
    if (!_fc.shouldDrive) return;
    final pose = puck.pose;
    if (pose == null) return;
    final cam = _controller.camera;
    var z = cam.zoom;
    if (_prefs.zoomBySpeed) {
      _zoomOffset = easeToward(_zoomOffset, speedZoomOffset(pose.speedMps), dt, 1.5);
      z = (_userZoom + _zoomOffset).clamp(3.0, 18.0).toDouble();
    } else {
      _zoomOffset = 0;
      _userZoom = z;
    }
    var rot = cam.rotation;
    final mh = puck.mapHeadingDeg;
    if (_prefs.headingUp && mh != null) rot = rot + shortestArc(rot, headingUpRotation(mh));
    final c = _centreFor(cam, at, _followOffsetFor(cam, at), z, rot);
    if (z == cam.zoom && rot == cam.rotation && (c.latitude - cam.center.latitude).abs() < 1e-9 && (c.longitude - cam.center.longitude).abs() < 1e-9) return;
    _controller.moveAndRotate(c, z, rot);
    tele?.drives++;
    tele?.zoom = z;
  }

  LatLng? get _livePosition {
    final p = widget.puck?.pose;
    return p == null ? widget.position : LatLng(p.lat, p.lon);
  }

  /// The Recenter button: follow is on again and the position goes to the middle of the visible area. The zoom stays.
  void _recenter() {
    setState(() => _follow = true);
    final target = _livePosition ?? (_latest == null ? null : LatLng(_latest!.lat, _latest!.lon));
    if (!_ready) return;
    final cam = _controller.camera;
    final size = cam.nonRotatedSize;
    final pad = _followPad;
    _vc.followOffset = followAnchor(width: size.width, height: size.height, left: pad.left, top: pad.top, right: pad.right, bottom: pad.bottom);
    if (target == null) return;
    if (widget.puck != null && widget.puck!.pose != null) {
      _onPuckFrame(target, 0.016); // the follower puts it at its place on the screen at once
    } else {
      _keepAt(target);
    }
  }

  void _northUp() {
    if (!_ready) return;
    _controller.rotate(0);
    _rotationN.value = 0;
  }

  void _select(String? key) {
    setState(() => _selectedRepeater = key);
    widget.onSelectRepeater?.call(key);
  }

  @override
  void dispose() {
    MainMapFocus.notifier.removeListener(_onFocusRequest);
    _hits.dispose();
    _boundsTimer?.cancel();
    _prefs.removeListener(_onPrefs);
    unawaited(_netSub?.cancel());
    TileFetchGate.debugForceOffline.removeListener(_onForcedOffline);
    unawaited(_tileReset.close());
    _tileProvider?.dispose();
    _pingScroll.dispose();
    _pack.basemap.removeListener(_onPacksChanged);
    _ownSource?.dispose();
    _ownFeed?.dispose();
    if (_ownsVc) _vc.dispose();
    super.dispose();
  }

  /// Tells the host which part of the world is on screen (after the frame: this can run while the map builds).
  void _reportBounds({bool force = false}) {
    final cb = widget.onBoundsChanged;
    if (cb == null) return;
    // While the camera follows the car this is called every frame: at most ~3 reports a second, and one more after it settles.
    final now = DateTime.now();
    if (!force && now.difference(_lastBounds) < const Duration(milliseconds: 300)) {
      _boundsTimer?.cancel();
      _boundsTimer = Timer(const Duration(milliseconds: 320), () => _reportBounds(force: true));
      return;
    }
    _lastBounds = now;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ready) return;
      final b = _controller.camera.visibleBounds;
      cb(GeoBounds(b.south, b.west, b.north, b.east));
    });
  }

  // ---------- cell layers: prepared once per data / palette change, painted from a cached picture ----------
  CellLayerData? _netData;
  List<NetworkCell>? _netSrc;
  MeshSonarColors? _netMc;
  Brightness? _netBr;

  CellLayerData _networkData(BuildContext context) {
    final cells = widget.networkCells;
    final mc = MeshSonarColors.of(context);
    final br = Theme.of(context).brightness;
    final cur = _netData;
    if (cur != null && identical(_netSrc, cells) && identical(_netMc, mc) && _netBr == br) return cur;
    final v2 = widget.coverageV2;
    if (v2 != null) {
      // Coverage v2 cells from public-coverage?metric=mean (time travel, filters, offline): the same styles as the tiles.
      final shapes = <CellShape>[
        for (final n in cells)
          if (n.cell != null) CellShape(n.boundary, measuredStyleIndex(n.cell!.band ?? 0, n.cell!.attempts < v2.meta.faintBelow)),
      ];
      final d = CellLayerData(shapes, measuredStyles(CoverageBandColors.of(mc.palette, br)), dotBelowZoom: v2.meta.hexFromZoom.toDouble(), dotPx: 3);
      _netData = d;
      _netSrc = cells;
      _netMc = mc;
      _netBr = br;
      return d;
    }
    final colours = <int, Color>{};
    Color colourOf(NetworkCell n) =>
        colours.putIfAbsent(n.level.index, () => networkLevelColor(context, n.level));
    final d = CellLayerData.build(cells.length, (i) => cells[i].boundary, (i) {
      final n = cells[i];
      final c = colourOf(n);
      // One or two pings are a thin sample: drawn fainter than a cell the network measured properly.
      final (fill, edge) = cellAlphas(n.level, n.cell?.pings ?? kMinCellPings);
      return CellStyle(c.withValues(alpha: fill), c.withValues(alpha: edge), 1);
    });
    _netData = d;
    _netSrc = cells;
    _netMc = mc;
    _netBr = br;
    return d;
  }

  CellLayerData? _hexLayerData;
  List<HexCell>? _hexLayerSrc;
  MeshSonarColors? _hexLayerMc;
  PingColorMode? _hexLayerMode;

  /// A repeater the `heard` layer draws: heard this drive, lit by the newest ping or selected. A map with no heard list (the
  /// drive-detail map, which has no roster or network layer) keeps drawing every repeater it was given.
  bool _drawnAsHeard(String key, Set<String> legacyLit) =>
      widget.heard == null || _heardByKey.containsKey(key) || legacyLit.contains(key) || key == _selectedRepeater;

  /// The drive's own hexagons (layer `hexes`, "Your coverage"). Coloured like the Pings layer (Drive plan 7.3 F3): by best SNR in
  /// the By-SNR mode, green when any ping in the hexagon was heard / grey when none was in the Heard mode.
  CellLayerData _hexData(MeshSonarColors mc, PingColorMode mode) {
    final hexes = _ensureHexes();
    final cur = _hexLayerData;
    if (cur != null && identical(_hexLayerSrc, hexes) && identical(_hexLayerMc, mc) && _hexLayerMode == mode) return cur;
    final v2 = widget.coverageV2;
    if (v2 != null) {
      // Coverage v2 "This drive": the measured look (same bands, same faint rule) with a solid outline in the band colour so the
      // drive's own cells stand out on top of everyone's; dots when zoomed out (D11).
      final bands = CoverageBandColors.of(mc.palette, Theme.of(context).brightness);
      final base = measuredStyles(bands);
      final styles = [
        for (var i = 0; i < base.length; i++)
          CellStyle(base[i].fill, i ~/ 2 == 0 ? base[i].border : bands[i ~/ 2], 1.2, null, base[i].dot),
      ];
      final shapes = [
        for (final h in hexes) CellShape(h.boundary, measuredStyleIndex(h.band ?? 0, h.sent < v2.meta.faintBelow)),
      ];
      final d = CellLayerData(shapes, styles, dotBelowZoom: v2.meta.hexFromZoom.toDouble(), dotPx: 3);
      _hexLayerData = d;
      _hexLayerSrc = hexes;
      _hexLayerMc = mc;
      _hexLayerMode = mode;
      return d;
    }
    final d = CellLayerData.build(hexes.length, (i) => hexes[i].boundary, (i) {
      final h = hexes[i];
      final c = hexColor(mc, h, mode);
      return CellStyle(c.withValues(alpha: h.wasHeard ? 0.34 : 0.22), c.withValues(alpha: 0.75), 1.2);
    });
    _hexLayerData = d;
    _hexLayerSrc = hexes;
    _hexLayerMc = mc;
    _hexLayerMode = mode;
    return d;
  }

  /// Dashed outlines of the installed offline packs (the one in use drawn stronger): where the map works with no signal.
  List<Widget> _packOutlines(MeshSonarColors mc) {
    final m = _pack.basemap.managerOrNull;
    if (m == null || m.installed.isEmpty) return const [];
    return [
      PolygonLayer(
        key: const Key('pack-outlines'),
        polygons: [
          for (final ip in m.installed.values)
            if (ip.bbox.length == 4)
              Polygon(
                points: [LatLng(ip.bbox[1], ip.bbox[0]), LatLng(ip.bbox[1], ip.bbox[2]), LatLng(ip.bbox[3], ip.bbox[2]), LatLng(ip.bbox[3], ip.bbox[0])],
                color: Colors.transparent,
                borderColor: (ip.code == _pack.code ? mc.beacon : mc.textMuted).withValues(alpha: ip.code == _pack.code ? 0.85 : 0.5),
                borderStrokeWidth: ip.code == _pack.code ? 2 : 1.2,
                pattern: _dashed,
              ),
        ],
      ),
    ];
  }

  /// The app layer slots in the active Map Definition's drawing order. Predicted / Heard / Measured are one slot (`measured`,
  /// drawn in the definition's order inside it); Repeaters and All MeshCore repeaters are one painter, placed at the lower of
  /// the two; Observers and Moving phones one marker layer at the lower of the two.
  List<String> _paintOrder() {
    final out = <String>[];
    for (final id in definitionLayerIds(ActiveMapDefinition.current)) {
      final slot = switch (id) {
        'predicted' || kHeardCellsLayerId || 'measured' => 'measured',
        kRosterLayerId || kNetworkLayerId => kNetworkLayerId,
        'phones' => 'observers',
        _ => id,
      };
      if (!out.contains(slot)) out.add(slot);
    }
    for (final slot in const ['borders', 'measured', 'hexes', 'links', kNetworkLayerId, 'observers']) {
      if (!out.contains(slot)) out.add(slot); // a definition without the layer still gets the app's drawing (switch is off)
    }
    return out;
  }

  static List<Widget>? _layerWidgets(String slot, Map<String, List<Widget> Function()> build) => build[slot]?.call();

  @override
  Widget build(BuildContext context) {
    final mc = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final style = widget.baseStyle;
    final tileGrading = tileMatrixFor(style, mc.tileMatrix);
    final tiles = widget.showTiles ?? CoverageMap.tilesByDefault;
    final wide = MediaQuery.sizeOf(context).shortestSide >= 600;
    // A downloaded region pack covering the map wins over online tiles; no pack (or a corrupt one) means online as before.
    final offlinePack = tiles && style.usesOfflinePack ? _pack.reader : null;
    _ensureSorted();
    _ensureMarkers();
    final latest = _latestCache;
    final pos = widget.position;
    final heardMode = widget.heard != null;
    final layerState = widget.layerState ?? kDefaultLayerState;
    final showLinks = widget.showLinks && layerState.isOn('links');
    final pingMode = pingColorModeOf(layerState);
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

    return MapOverlayHost(
      slotKeys: _slotKeys,
      topClearance: widget.topClearance,
      bottomClearance: widget.bottomClearance,
      map: FlutterMap(
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
            onPointerDown: (_, _) => _fc.pointerDown(),
            onPointerUp: (_, _) => _fc.pointerUp(),
            onPointerCancel: (_, _) => _fc.pointerUp(),
            onMapReady: () {
              _ready = true;
              if (widget.takesFocusRequests && MainMapFocus.notifier.value != null) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _onFocusRequest());
              }
              _userZoom = _controller.camera.zoom;
              _headingUpApplied = _prefs.headingUp;
              _reportBounds(force: true);
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
              // A repeater, ping, observer or cluster drawn on top of a cell gets the tap, not the cell under it: the cell is
              // only one candidate, and the resolver picks the winner by priority once the tap has reached every source.
              final ls = widget.layerState ?? kDefaultLayerState;
              if (widget.coverageV2 case final v2?) {
                final h = _coverageHit(v2, ls, point);
                if (h == null) {
                  _hits.tapReachedMap();
                } else {
                  _hits.submit(MapHitCandidate(MapHitKind.cell, () => _showCoverageCell(v2, h.h3, h.lat, h.lon)));
                }
                return;
              }
              final cell = ls.isOn('measured') ? networkCellAt(widget.networkCells, point) : null;
              if (cell == null) {
                _hits.tapReachedMap();
              } else {
                _hits.submit(MapHitCandidate(MapHitKind.cell, () => _showCellLinks(cell)));
              }
            },
            onPositionChanged: (camera, hasGesture) {
              _reportBounds();
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
              if (widget.rotatable) _rotationN.value = camera.rotation;
              if (hasGesture) {
                // The person panned, zoomed, pinched or rotated: follow is off and code never moves this camera again
                // until Recenter (no auto-resume, Andy Nov 10 2026).
                final was = _fc.following;
                _follow = false;
                _userZoom = camera.zoom - _zoomOffset;
                if (was) setState(() {});
              }
            },
          ),
          children: [
            ChartGrid(color: mc.mapGrid),
            // Online + disk-cached tiles everywhere, except where an installed offline pack draws (no request for those); the
            // pack's vector tiles go on top of that. Where a pack ends the online/cached tiles carry on: never a blank edge.
            // Chart / Light / Dark: our vector basemap (OpenFreeMap fallback), every tile through the same cache and gate.
            if (tiles && style.isVector) BasemapLayer(key: ValueKey('basemap-${style.id}'), dark: style.darkLook, tiles: _tiles(), reset: _tileReset.stream),
            if (tiles && !style.isVector)
              TileLayer(
                key: ValueKey('tiles-${style.id}'),
                urlTemplate: style.tileUrl,
                userAgentPackageName: CoverageMap.userAgentPackageName,
                maxNativeZoom: style.maxNativeZoom,
                tileProvider: _tiles(),
                reset: _tileReset.stream,
                tileDisplay: const TileDisplay.fadeIn(duration: Duration(milliseconds: 150)),
                // Phones load the viewport only (panBuffer 0) so the visible tiles never wait behind tiles nobody sees yet.
                keepBuffer: wide ? 4 : 1,
                panBuffer: wide ? 1 : 0,
                tileBuilder: tileGrading == null
                    ? null
                    : (context, tile, _) => ColorFiltered(colorFilter: ColorFilter.matrix(tileGrading), child: tile),
              ),
            if (offlinePack != null)
              OfflineBasemapLayer(
                key: ValueKey('offline-pack-${_pack.code}${style == BaseMapStyle.chart ? '' : '-${style.id}'}'),
                reader: offlinePack,
                schema: _pack.basemap.managerOrNull?.installed[_pack.code]?.schema ?? PackSchema.openmaptiles,
                // Dark forces the dark look, Light the light look; Chart follows the app theme.
                dark: style.darkLook,
              ),
            if (tiles && style.usesOfflinePack) ..._packOutlines(mc),
            // The definition's layers, in its drawing order (bottom to top: borders, predicted, heard, measured, drive, links,
            // network, live, repeaters, observers, phones). The app's drive extras (ping dots, the position, names) stay on top.
            for (final id in _paintOrder()) ...?_layerWidgets(id, {
              'borders': () => [
                if (layerState.isOn('borders') && widget.regionBorders.isNotEmpty)
                  RegionBordersLayer(key: const Key('region-borders-layer'), rings: widget.regionBorders),
              ],
              'measured': () => [
            if (widget.coverageV2 case final v2? when v2.drawTiles) ...[
              if (layerState.isOn('predicted'))
                CoverageTilesLayer(
                  key: const Key('coverage-predicted-layer'),
                  layer: CoverageTileLayer.predicted,
                  store: v2.tiles,
                  meta: v2.meta,
                  colors: CoverageBandColors.of(mc.palette, t.brightness),
                ),
              // Heard (no ping): over Predicted, under Measured, so a pinged cell always shows its Measured colour (§8.5).
              if (v2.heard && layerState.isOn(kHeardCellsLayerId))
                CoverageTilesLayer(
                  key: const Key('coverage-heard-layer'),
                  layer: CoverageTileLayer.heard,
                  store: v2.tiles,
                  meta: v2.meta,
                  colors: CoverageBandColors.of(mc.palette, t.brightness),
                ),
              if (layerState.isOn('measured'))
                CoverageTilesLayer(
                  key: const Key('coverage-measured-layer'),
                  layer: CoverageTileLayer.measured,
                  store: v2.tiles,
                  meta: v2.meta,
                  colors: CoverageBandColors.of(mc.palette, t.brightness),
                  faintBelow: v2.meta.faintBelow,
                ),
            ] else if (layerState.isOn('measured') && widget.networkCells.isNotEmpty)
              CellRasterLayer(key: const Key('network-cells-layer'), data: _networkData(context)),
            ],
              'hexes': () => [
            if (layerState.isOn('hexes'))
              KeyedSubtree(
                // The resolution is in the key so a test (and a screenshot) can see which band is on screen.
                key: ValueKey('drive-hexes-res-${widget.coverageV2 != null ? 11 : hexResolution}'),
                child: CellRasterLayer(key: const Key('drive-hexes-layer'), data: _hexData(mc, pingMode)),
              ),
            ],
              'links': () => [
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
            if (widget.puck case final puck? when heardMode && showLinks)
              PuckLinksLayer(puck: puck, heard: widget.heard!, fallback: origin)
            else if (liveLinks.isNotEmpty)
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
            if (_currentLinks() case final ls?) ...linkLineLayers(context, ls, labels: _captions || hexResolution >= 9),
            ],
              kNetworkLayerId: () => [
            if (showNetwork || rosterSource != null || layerState.isOn('heard'))
              ListenableBuilder(
                listenable: Listenable.merge([?rosterSource, ?networkSource]),
                builder: (context, _) => RepeaterPainterLayer(
                  sources: [
                    if (rosterSource != null) (rosterSource, kRosterLayerId),
                    if (showNetwork) (networkSource, kNetworkLayerId),
                  ],
                  badges: _badgesFor(rosterSource, networkSource, layerState.isOn('heard'), latest?.id, legacyLit),
                  selectedKey: _selectedRepeater,
                  onHit: _onHit,
                  onBadgeTap: _onBadgeTap,
                ),
              ),
            ],
              'observers': () => [
                if ((layerState.isOn('observers') || layerState.isOn('phones')) && widget.observers.isNotEmpty)
                  ObserverLayer(
                    observers: widget.observers,
                    regionName: widget.observersRegionName,
                    onHit: _onHit,
                    showFixed: layerState.isOn('observers'),
                    showMobile: layerState.isOn('phones'),
                  ),
              ],
            }),
            if (layerState.isOn('pings'))
              MarkerLayer(
                markers: [
                  for (final p in _sorted)
                    Marker(
                      point: LatLng(p.lat, p.lon),
                      width: 40,
                      height: 40,
                      child: GestureDetector(
                        key: ValueKey('map-ping-tap-${p.id}'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => _hits.submit(MapHitCandidate(MapHitKind.ping, () => _showPingLinks(p))),
                        child: PingDot(
                          dotKey: ValueKey('map-ping-${p.id}'),
                          color: pingColor(mc, p, pingMode),
                          ring: t.colorScheme.surface,
                          pulse: identical(p, latest) || p.id == latest?.id,
                        ),
                      ),
                    ),
                ],
              ),
            if (widget.puck case final puck?)
              PuckLayer(puck: puck, fallback: pos, onMoved: _onPuckFrame)
            else if (pos != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: pos,
                    width: 48,
                    height: 48,
                    child: IgnorePointer(
                      child: PositionMarker(
                        key: const Key('map-position'),
                        color: t.colorScheme.primary,
                        ring: t.colorScheme.surface,
                      ),
                    ),
                  ),
                ],
              ),
            if (layerState.isOn(kLabelsLayerId) || (liveLinks.isNotEmpty && _captions))
              ListenableBuilder(
                listenable: Listenable.merge([?rosterSource, ?networkSource]),
                builder: (context, _) => RepeaterNameLabels(
                  showNames: layerState.isOn(kLabelsLayerId),
                  badges: _badgesFor(rosterSource, networkSource, layerState.isOn('heard'), latest?.id, legacyLit),
                  sources: [
                    if (rosterSource != null) (rosterSource, kRosterLayerId),
                    if (showNetwork) (networkSource, kNetworkLayerId),
                  ],
                  selectedKey: _selectedRepeater,
                  selectedDetail: selected == null ? null : _detailFor(selected, origin),
                  origin: origin,
                  puck: pos,
                  pill: style == BaseMapStyle.street || style == BaseMapStyle.topo,
                  linkTags: [
                    if (_captions)
                      for (final h in liveLinks)
                        LinkTagInput(
                          id: 'link-${h.ref!.key}',
                          a: origin!,
                          b: LatLng(h.ref!.lat, h.ref!.lon),
                          text: AppScope.unitsOf(context).distance(approx: true, haversineM(origin.latitude, origin.longitude, h.ref!.lat, h.ref!.lon)),
                          color: h.phase == HeardPhase.fresh ? mc.beacon : t.colorScheme.outline,
                        ),
                  ],
                  blockers: const [],
                  inset: widget.overlayPadding + const EdgeInsets.only(bottom: 30),
                  avoid: (size) => _overlayRects(),
                ),
              ),
          ],
        ),
      banner: widget.banner,
      // New Drive screen: the "Map offline" state is a pill under the region chip (plan 4.12), never a bottom-left note.
      topLeading: _withLegend(
        widget.onLayers != null && !tiles
          ? Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ?widget.topLeading,
                const SizedBox(height: Gap.xs),
                MapPill(
                  key: const Key('map-offline'),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_off_rounded, size: 13, color: mc.textMuted),
                      const SizedBox(width: 4),
                      const Flexible(child: Text('Offline map', maxLines: 1)),
                    ],
                  ),
                ),
              ],
            )
          : widget.topLeading,
      ),
      topTrailing: widget.topTrailing,
      controls: _controls(context, pos, latest),
      bottom: _bottomColumn(context, tiles, mc, t),
      // The credit: always mounted (Drive plan section 8), bottom-right, tapped (i) opens the Credits sheet.
      attribution: BasemapSourceBuilder(
        controller: _controller,
        builder: (context, source) {
          final credit = _creditText(style, source, offlinePack != null);
          return networkSource == null
              ? AttributionLine(style: style, text: credit, onInfo: () => _openCredits(context, style, tiles, null))
              : ListenableBuilder(
                  listenable: networkSource,
                  builder: (context, _) {
                    final meshCore = showNetwork && networkSource.globalPoints.length > 0;
                    return AttributionLine(
                      style: style,
                      text: credit,
                      showMeshCore: meshCore,
                      onInfo: () => _openCredits(context, style, tiles, meshCore ? (networkSource.feed.global.attribution ?? 'MeshCore Map') : null),
                    );
                  },
                );
        },
      ),
    );
  }

  /// The top-leading slot's content with the legend card under it (the app keeps the lower-left corner free, Drive plan 9.3, so
  /// the card sits under the chips and opens downward).
  Widget? _withLegend(Widget? top) {
    final legend = widget.legend;
    if (legend == null) return top;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [?top, if (top != null) const SizedBox(height: Gap.xs), legend],
    );
  }

  /// The credit of what the base map draws now: Topo's own line, the offline pack's, or the online source's (ours / OpenFreeMap).
  String _creditText(BaseMapStyle style, BasemapSource source, bool packDrawn) {
    if (!style.isVector) return style.attribution;
    if (packDrawn) {
      final ip = _pack.basemap.managerOrNull?.installed[_pack.code];
      return ip == null || ip.schema == PackSchema.protomaps ? OurBasemap.attribution : '© OpenStreetMap contributors';
    }
    return source.attribution;
  }

  void _openCredits(BuildContext context, BaseMapStyle style, bool tiles, String? meshCoreCredit) {
    showMapCredits(
      context,
      style: style,
      sourceState: tiles
          ? SourceChip(
              stats: _tileStats,
              gate: _tiles().gate,
              packName: _pack.code == null ? null : (_pack.basemap.managerOrNull?.installed[_pack.code]?.name ?? _pack.code),
              clock: _now,
            )
          : null,
      colourKey: widget.mapKey,
      meshCoreCredit: meshCoreCredit,
      openLegend: widget.openLegend == null
          ? null
          : () {
              Navigator.of(context, rootNavigator: true).maybePop();
              widget.openLegend!();
            },
    );
  }

  /// The bottom slot: what the host puts there, then this map's own status (the info panel, the SIMULATED tag, the offline note).
  /// Nothing here is a credit; the credit is the [AttributionLine].
  Widget? _bottomColumn(BuildContext context, bool tiles, MeshSonarColors mc, ThemeData t) {
    final panel = _panel(context);
    final children = <Widget>[
      ?widget.bottom,
      if (panel != null) ...[SizedBox(width: double.infinity, child: panel), const SizedBox(height: Gap.xs)],
      // New Drive screen: SIM is a badge in the status capsule and the offline state is a pill at the top; nothing bottom-left.
      if (widget.simulated && widget.onLayers == null) ...[const SimulatedTag(key: Key('map-simulated')), const SizedBox(height: Gap.xs)],
      if (!tiles && widget.onLayers == null)
        MapPill(
          key: const Key('map-offline'),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_rounded, size: 13, color: mc.textMuted),
              const SizedBox(width: 4),
              Flexible(child: Text('Map offline. Pings still record.', overflow: TextOverflow.ellipsis, style: t.textTheme.labelSmall?.copyWith(fontSize: 11))),
            ],
          ),
        ),
    ];
    if (children.isEmpty) return null;
    return Column(
      key: _stackKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }

  /// The round buttons above the attribution: compass (rotatable), heading-up toggle (live puck), recenter (not following).
  Widget? _controls(BuildContext context, LatLng? pos, DrivePing? latest) {
    if (widget.onLayers != null) {
      final havePos = pos != null || latest != null;
      final mode = !_follow ? RecenterMode.notFollowing : (_prefs.headingUp ? RecenterMode.followingHeadingUp : RecenterMode.followingNorthUp);
      return ValueListenableBuilder<double>(
        key: _buttonsKey,
        valueListenable: _rotationN,
        builder: (context, rot, _) => MapControlColumn(
          onLayers: widget.onLayers!,
          compassVisible: widget.rotatable && rot.abs() >= 0.5,
          compassRotation: rot,
          onCompass: _northUp,
          recenterVisible: havePos,
          recenterMode: mode,
          onRecenter: () {
            switch (mode) {
              case RecenterMode.notFollowing:
                _prefs.headingUp = false;
                _recenter();
              case RecenterMode.followingNorthUp:
                _prefs.headingUp = true;
              case RecenterMode.followingHeadingUp:
                _prefs.headingUp = false;
            }
          },
        ),
      );
    }
    final showHeading = widget.puck != null && widget.interactive;
    final showRecenter = !_follow && (pos != null || latest != null);
    if (!widget.rotatable && !showHeading && !showRecenter) return null;
    return Column(
      key: _buttonsKey,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.rotatable) ...[
          ValueListenableBuilder<double>(
            valueListenable: _rotationN,
            builder: (context, rot, _) => MapCompass(rotation: rot, onPressed: _northUp),
          ),
          const SizedBox(height: Gap.s),
        ],
        if (showHeading) ...[
          FloatingActionButton.small(
            key: const Key('map-heading-toggle'),
            heroTag: null,
            tooltip: _prefs.headingUp ? 'Heading up (tap for north up)' : 'North up (tap for heading up)',
            onPressed: () => _prefs.headingUp = !_prefs.headingUp,
            child: Icon(_prefs.headingUp ? Icons.navigation_rounded : Icons.explore_outlined),
          ),
          const SizedBox(height: Gap.s),
        ],
        if (showRecenter)
          FloatingActionButton.small(
            key: const Key('map-recenter'),
            heroTag: null,
            tooltip: 'Recenter and follow',
            onPressed: _recenter,
            child: const Icon(Icons.my_location_rounded),
          ),
      ],
    );
  }

  final GlobalKey _stackKey = GlobalKey(debugLabel: 'map-bottom-stack');
  final GlobalKey _buttonsKey = GlobalKey(debugLabel: 'map-buttons');
  late final Map<MapSlot, GlobalKey> _slotKeys = {
    MapSlot.banner: GlobalKey(debugLabel: 'slot-banner'),
    MapSlot.topLeading: GlobalKey(debugLabel: 'slot-top-leading'),
    MapSlot.topTrailing: GlobalKey(debugLabel: 'slot-top-trailing'),
  };

  /// Where the overlays sit, in this map's own coordinates (the bottom stack, the recenter/compass buttons and the
  /// banner / top slots), a little inflated. Read at paint time, so one frame behind a layout change.
  List<Rect> _overlayRects() {
    if (!mounted) return const [];
    try {
      final mapBox = context.findRenderObject();
      if (mapBox is! RenderBox || !mapBox.hasSize) return const [];
      final out = <Rect>[];
      for (final k in [_stackKey, _buttonsKey, ..._slotKeys.values]) {
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

}
