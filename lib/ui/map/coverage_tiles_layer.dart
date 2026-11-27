// The coverage v2 tile layers (Measured coverage, Predicted coverage) inside the app's flutter_map.
//
// Decision (WP5, Nov 8 2026; recorded in meshsonar-infra HANDOFF): the tiles are the server's MVT tiles, as planned (D10),
// but they are NOT drawn with vector_map_tiles' theme renderer. That renderer (vector_tile_renderer 6.1) has no `circle`
// layer type and no `fill-pattern` support, so the two drawing rules the contract needs, D11's zoomed-out dots and the
// Predicted hatch, cannot be expressed in its style JSON. Instead the same tiles are decoded (package vector_tile, already
// under vector_map_tiles) into flat arrays (lib/core/coverage_v2.dart) and painted by CellRasterLayer, the cached-picture
// cell painter every other cell layer uses, with one style per band (the "one fill layer per band" rule, no expressions).
// The plan's own fallback (viewport GeoJSON at z >= 13) was not needed: the tile path works at every zoom.
//
// Tiles: integer zoom, at most 16 (z16 hexagons are exact deeper in); predicted from meta.predictedFromZoom (8). A tile not
// in memory yet is stood in for by its nearest loaded ancestor of the same kind (hexagons by hexagons from meta.hexFromZoom,
// points by points below it), else by its loaded children. A zoom step keeps the whole previous picture until the new
// zoom's tiles are in (kCoverageHold at most): no hole where coverage was, one swap per step (see "steadiness" below).
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../core/coverage_v2.dart';
import '../../core/map_definition_v2.dart' show CoverageLadder;
import 'cell_raster_layer.dart';
import 'coverage_bands.dart';

/// Counters for the steadiness of one coverage layer (tests and the simulator probe; plain ints, nothing is logged).
class CoverageLayerStats {
  /// build() calls of the layer.
  int builds = 0;

  /// Times the picture handed to the painter was replaced.
  int dataSwaps = 0;

  /// Builds in which something that was drawn in the previous build is drawn by nothing now (a hole where coverage was).
  int dropFrames = 0;

  /// Viewport tiles that lost their picture, summed over those builds.
  int droppedTiles = 0;

  void reset() => builds = dataSwaps = dropFrames = droppedTiles = 0;

  @override
  String toString() => 'builds=$builds dataSwaps=$dataSwaps dropFrames=$dropFrames droppedTiles=$droppedTiles';
}

/// True when tile a (z, x, y) and tile b cover some of the same ground (one is the other or its ancestor).
bool coverageTilesOverlap((int, int, int) a, (int, int, int) b) {
  final (az, ax, ay) = a;
  final (bz, bx, by) = b;
  if (az <= bz) return (bx >> (bz - az)) == ax && (by >> (bz - az)) == ay;
  return (ax >> (az - bz)) == bx && (ay >> (az - bz)) == by;
}

/// What a coverage layer shows in the view now (the map's status pill, Round 1 N5).
enum CoverageViewStatus { shown, loading, failed, empty, notAtThisZoom }

class CoverageTilesLayer extends StatefulWidget {
  final CoverageTileLayer layer;
  final CoverageTileStore store;
  final CoverageMeta meta;
  final CoverageBandColors colors;

  /// Measured features with fewer attempts are faint (meta.faintBelow).
  final int faintBelow;

  /// The Map Definition's coverage ladder (`coverage.summary`), or null = build 72 behaviour. With it the summary layers draw
  /// the picture from [CoverageLadder.fromZoom] to the res-11 hexagons, and the dot layers keep to the zooms below it.
  final CoverageLadder? ladder;

  /// What the layer shows in this view (build 77, Round 1 N5: the map says what it is doing), after each build.
  final ValueChanged<CoverageViewStatus>? onStatus;
  const CoverageTilesLayer({super.key, required this.layer, required this.store, required this.meta, required this.colors, this.faintBelow = 3, this.ladder, this.onStatus});

  @override
  State<CoverageTilesLayer> createState() => CoverageTilesLayerState();
}

class CoverageTilesLayerState extends State<CoverageTilesLayer> {
  @override
  void initState() {
    super.initState();
    widget.store.addListener(_onTile);
  }

  @override
  void didUpdateWidget(CoverageTilesLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      oldWidget.store.removeListener(_onTile);
      widget.store.addListener(_onTile);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    widget.store.removeListener(_onTile);
    super.dispose();
  }

  void _onTile() {
    if (mounted) setState(() {});
  }

  // Shapes per tile key (style indexes depend only on the data, never on the colours).
  final Map<String, List<CellShape>> _shapes = {};
  String _usedSig = '';
  CellLayerData _data = CellLayerData.empty;
  List<CellStyle>? _styles;
  CoverageBandColors? _stylesFor;

  /// Steadiness counters of this layer (tests).
  final CoverageLayerStats stats = CoverageLayerStats();
  List<(int, int, int)> _drawnTiles = const [];

  /// Viewport tiles that draw nothing now although coverage was drawn over them in the last complete picture (tests: 0 = steady).
  int holes = 0;

  /// Cells in the data handed to the painter now (tests).
  int get cellCount => _data.shapes.length;

  List<CellShape> _shapesOf(String key, CoverageTileData d) {
    final got = _shapes[key];
    if (got != null) return got;
    final measured = widget.layer == CoverageTileLayer.measured;
    final heard = widget.layer == CoverageTileLayer.heard;
    final out = <CellShape>[];
    for (var f = 0; f < d.length; f++) {
      final band = d.band[f];
      final style = switch (widget.layer) {
        CoverageTileLayer.measuredSummary => measuredSummaryStyleIndex(band, d.share(f)),
        CoverageTileLayer.predictedSummary => predictedSummaryStyleIndex(band, d.o[f], d.share(f)),
        _ => heard ? band.clamp(0, 6) : (measured ? measuredStyleIndex(band, d.n[f] < widget.faintBelow) : predictedStyleIndex(band, d.o[f])),
      };
      out.add(CellShape.slice(d.latLon, d.starts[f], d.starts[f + 1], style));
    }
    if (_shapes.length > 600) _shapes.remove(_shapes.keys.first);
    return _shapes[key] = out;
  }

  // ---- steadiness (build 72, "the coverage is jumpy") ----
  // One picture per zoom step. When the tile zoom changes and the new zoom's tiles are not all in yet, the picture that is on
  // screen stays, whole, until they are (or [kCoverageHold] passes): no hole where coverage was, and dots turn into hexagons
  // (or back) once for the whole view, not tile by tile as each lands. Within one zoom (a pan) a tile that is not in yet is
  // stood in for by its nearest loaded ancestor of the same kind, else by its loaded children, so zooming out keeps the
  // finer tiles until the coarser one lands. The Nov 8 rule still holds once the hold is over: at a hexagon zoom a point
  // tile never stands in.
  int? _shownZ;
  Timer? _holdTimer;
  bool _holdExpired = false;

  /// True while a zoom step is showing the previous picture (tests).
  bool get holding => _holdTimer != null;

  void _endHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdExpired = false;
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final meta = widget.meta;
    final summary = widget.layer.isSummary;
    final ladder = widget.ladder;
    // measured and heard follow the measured zoom rules
    final measured = widget.layer != CoverageTileLayer.predicted && widget.layer != CoverageTileLayer.predictedSummary;
    stats.builds++;
    // With the ladder the summary layers draw from its first zoom up to the res-11 hexagons; the dot layers keep to the zooms
    // below it (measured) or draw nothing before the hexagons (predicted: its dots are gone, site slice 1).
    final skip = summary
        ? (ladder == null || !ladder.drawsAt(camera.zoom))
        : (ladder != null &&
              ((widget.layer == CoverageTileLayer.measured && camera.zoom >= ladder.fromZoom && camera.zoom < ladder.hexFromZoom) ||
                  (widget.layer == CoverageTileLayer.predicted && camera.zoom < ladder.hexFromZoom)));
    if (skip || (!measured && !summary && camera.zoom < meta.predictedFromZoom)) {
      if (widget.onStatus case final report?) WidgetsBinding.instance.addPostFrameCallback((_) => report(CoverageViewStatus.notAtThisZoom));
      _endHold();
      _shownZ = null;
      _data = CellLayerData.empty;
      _usedSig = '';
      _drawnTiles = const [];
      holes = 0;
      return const SizedBox.shrink();
    }
    final z = summary ? ladder!.tileZoom(camera.zoom) : coverageTileZoom(camera.zoom);
    final b = camera.visibleBounds;
    final preset = meta.defaultPreset;
    final version = meta.versionFor(widget.layer);
    final store = widget.store;
    String keyOf(int tz, int tx, int ty) => coverageTileKey(widget.layer, preset, version, tz, tx, ty);

    // What this view needs: ask for what is missing, forget queued requests for views the map has left, and make room for
    // a big screen (three screens of tiles for each of the three coverage layers, plus their stand-ins).
    final tiles = tilesCovering(b.south, b.west, b.north, b.east, z);
    final wanted = <String>{for (final (x, y) in tiles) keyOf(z, x, y)};
    store.ensureRoom(capacity: tiles.length * 3 * 3 * 2, concurrent: tiles.length ~/ 2);
    store.prune(widget.layer, wanted);
    var resolved = true;
    for (final (x, y) in tiles) {
      final key = keyOf(z, x, y);
      if (store.has(key)) continue;
      store.want(widget.layer, preset, version, z, x, y);
      if (store.loading(key)) resolved = false;
    }

    // A zoom step whose tiles are still on their way: keep the picture that is on screen, whole.
    final shownOverlapsView = _shownZ != null && tiles.any((t) => _drawnTiles.any((d) => coverageTilesOverlap(d, (z, t.$1, t.$2))));
    if (_shownZ != null && z != _shownZ && !resolved && !_holdExpired && !_data.isEmpty && shownOverlapsView) {
      _holdTimer ??= Timer(kCoverageHold, () {
        if (!mounted) return;
        setState(() => _holdExpired = true);
      });
      holes = 0;
      return CellRasterLayer(key: ValueKey('coverage-tiles-${widget.layer.name}'), data: _data);
    }
    _endHold();
    _shownZ = z;

    final used = <String>[];
    final parts = <List<CellShape>>[];
    final drawn = <(int, int, int)>[];
    final bare = <(int, int, int)>[];
    void use(String key, CoverageTileData d, (int, int, int) at) {
      drawn.add(at);
      if (used.contains(key)) return;
      used.add(key);
      parts.add(_shapesOf(key, d));
    }

    // Stand-ins come only from tiles of the same kind: at a hexagon zoom (>= meta.hexFromZoom) never from a point tile below it.
    // Andy's field shot (dark, z14, Polaris, Nov 8): while the big z13/z14 Predicted tiles were still loading over cellular, the
    // z12 Predicted tile (a grid of points) stood in for them and drew a fine dot-matrix over the whole area. A gap that fills in
    // as the hexagon tile lands is honest; dots at a hexagon zoom are not.
    final hexes = z >= meta.hexFromZoom;
    final minZ = summary ? ladder!.fromZoom : (hexes ? meta.hexFromZoom : (measured ? 0 : meta.predictedFromZoom));
    final maxChildZ = summary ? ladder!.toZoom : 16;
    for (final (x, y) in tiles) {
      final key = keyOf(z, x, y);
      final d = store.peek(key);
      if (d != null) {
        use(key, d, (z, x, y));
        continue;
      }
      var stood = false;
      // The nearest loaded ancestor (its cells cover this tile too).
      for (var pz = z - 1, px = x >> 1, py = y >> 1; pz >= minZ && pz >= z - 4; pz--, px >>= 1, py >>= 1) {
        final pk = keyOf(pz, px, py);
        final pd = store.peek(pk);
        if (pd == null) continue;
        use(pk, pd, (pz, px, py));
        stood = true;
        break;
      }
      // Else its loaded children, one or two levels down (zooming out: the finer tiles stay until the coarser one lands).
      // Below the hexagon zoom the painter draws every cell as a dot, so hexagon children read as dots there.
      for (var dz = 1; !stood && dz <= 2 && z + dz <= maxChildZ; dz++) {
        final n = 1 << dz;
        for (var cx = x * n; cx < (x + 1) * n; cx++) {
          for (var cy = y * n; cy < (y + 1) * n; cy++) {
            final ck = keyOf(z + dz, cx, cy);
            if (!store.has(ck)) continue;
            use(ck, store.peek(ck)!, (z + dz, cx, cy));
            stood = true;
          }
        }
      }
      if (!stood) bare.add((z, x, y));
    }
    final lost = [for (final t in bare) if (_drawnTiles.any((d) => coverageTilesOverlap(d, t))) t];
    holes = lost.length;
    if (lost.isNotEmpty) {
      stats.dropFrames++;
      stats.droppedTiles += lost.length;
    }
    // The reference is the last picture with no hole: a hole stays a hole until it is filled.
    if (lost.isEmpty) _drawnTiles = drawn;
    if (widget.onStatus case final report?) {
      final cells = parts.fold<int>(0, (n, p) => n + p.length);
      final status = !resolved
          ? (store.offline ? CoverageViewStatus.failed : CoverageViewStatus.loading)
          : (bare.isNotEmpty && store.offline ? CoverageViewStatus.failed : (cells == 0 ? CoverageViewStatus.empty : CoverageViewStatus.shown));
      WidgetsBinding.instance.addPostFrameCallback((_) => report(status));
    }
    final sig = used.join(',');
    if (_stylesFor != widget.colors || _styles == null) {
      _styles = switch (widget.layer) {
        CoverageTileLayer.measured => measuredStyles(widget.colors),
        CoverageTileLayer.predicted => predictedStyles(widget.colors),
        CoverageTileLayer.heard => heardStyles(widget.colors),
        CoverageTileLayer.measuredSummary => measuredSummaryStyles(widget.colors, ladder!),
        CoverageTileLayer.predictedSummary => predictedSummaryStyles(widget.colors, ladder!),
      };
      _stylesFor = widget.colors;
      _usedSig = '';
    }
    if (sig != _usedSig) {
      _usedSig = sig;
      stats.dataSwaps++;
      final List<CellShape> all;
      if (summary) {
        // A summary hexagon near a tile edge is a feature in both tiles (each tile also carries its buffer, where a hexagon may be
        // cut off): draw it once, from the tile its centre is in (the whole hexagon), or its fill doubles there.
        final pick = <String, (int, int, bool)>{};
        final loose = <(int, int)>[];
        for (var i = 0; i < used.length; i++) {
          final d = store.peek(used[i]);
          if (d == null) continue;
          final tz = used[i].split('|').last.split('/').map(int.parse).toList();
          final south = tileLat(tz[2] + 1.0, tz[0]), north = tileLat(tz[2].toDouble(), tz[0]);
          final west = tileLon(tz[1].toDouble(), tz[0]), east = tileLon(tz[1] + 1.0, tz[0]);
          for (var f = 0; f < parts[i].length; f++) {
            final h = d.h[f];
            if (h.isEmpty) {
              loose.add((i, f));
              continue;
            }
            var lat = 0.0, lon = 0.0;
            final n = d.starts[f + 1] - d.starts[f];
            for (var v = d.starts[f]; v < d.starts[f + 1]; v++) {
              lat += d.latLon[2 * v] / n;
              lon += d.latLon[2 * v + 1] / n;
            }
            final inside = lat >= south && lat < north && lon >= west && lon < east;
            final have = pick[h];
            if (have == null || (!have.$3 && inside)) pick[h] = (i, f, inside);
          }
        }
        all = [for (final e in pick.values) parts[e.$1][e.$2], for (final (i, f) in loose) parts[i][f]];
      } else {
        all = parts.length == 1 ? parts.single : [for (final p in parts) ...p];
      }
      _data = CellLayerData(all, _styles!,
          dotBelowZoom: summary ? null : meta.hexFromZoom.toDouble(),
          dotPx: widget.layer == CoverageTileLayer.heard ? kHeardDotPx : (measured ? 3 : 2));
    }
    if (_data.isEmpty) return const SizedBox.shrink();
    return CellRasterLayer(key: ValueKey('coverage-tiles-${widget.layer.name}'), data: _data);
  }
}

/// How long a zoom step may keep the previous picture while its tiles load. After it the view is drawn from what is in
/// (with honest gaps), so a dead connection never leaves a stale picture for good.
const Duration kCoverageHold = Duration(seconds: 4);

/// Hit test over loaded measured/predicted tiles: the res-11 cell id under [lat]/[lon] at tile zoom [z] (hexagons, by
/// point-in-polygon), or, zoomed out, the dot within [radiusDeg] of it (its centroid's cell is resolved by the caller with h3).
/// Returns the H3 id for a hexagon hit, `null` when nothing is there.
({String? h3, double lat, double lon})? coverageTileHit(
  CoverageTileStore store,
  CoverageTileLayer layer,
  CoverageMeta meta,
  double lat,
  double lon,
  int z, {
  double radiusDeg = 0,
}) {
  final (x, y) = tileOf(lat, lon, z);
  final d = store.peek(coverageTileKey(layer, meta.defaultPreset, meta.versionFor(layer), z, x, y));
  if (d == null) return null;
  ({String? h3, double lat, double lon})? best;
  var bestD = double.infinity;
  for (var f = 0; f < d.length; f++) {
    final from = d.starts[f], to = d.starts[f + 1];
    if (layer == CoverageTileLayer.predicted && d.band[f] == 0 && to - from == 1) continue; // not drawn zoomed out
    if (to - from == 1) {
      final dl = d.latLon[2 * from] - lat, dn = d.latLon[2 * from + 1] - lon;
      final dist = dl * dl + dn * dn;
      if (dist <= radiusDeg * radiusDeg && dist < bestD) {
        bestD = dist;
        best = (h3: null, lat: d.latLon[2 * from], lon: d.latLon[2 * from + 1]);
      }
      continue;
    }
    if (_inside(d.latLon, from, to, lat, lon)) return (h3: d.h[f].isEmpty ? null : d.h[f], lat: lat, lon: lon);
  }
  return best;
}

bool _inside(Float64List ll, int from, int to, double lat, double lon) {
  var inside = false;
  for (var i = from, j = to - 1; i < to; j = i++) {
    final ai = ll[2 * i], oi = ll[2 * i + 1], aj = ll[2 * j], oj = ll[2 * j + 1];
    if ((ai > lat) != (aj > lat) && lon < (oj - oi) * (lat - ai) / (aj - ai) + oi) inside = !inside;
  }
  return inside;
}
