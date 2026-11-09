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
// points by points below it), so a pan or zoom rarely blanks the layer and never shows dots where hexagons belong.
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';

import '../../core/coverage_v2.dart';
import 'cell_raster_layer.dart';
import 'coverage_bands.dart';

class CoverageTilesLayer extends StatefulWidget {
  final CoverageTileLayer layer;
  final CoverageTileStore store;
  final CoverageMeta meta;
  final CoverageBandColors colors;

  /// Measured features with fewer attempts are faint (meta.faintBelow).
  final int faintBelow;
  const CoverageTilesLayer({super.key, required this.layer, required this.store, required this.meta, required this.colors, this.faintBelow = 3});

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
      final style = heard
          ? band.clamp(0, 6)
          : (measured ? measuredStyleIndex(band, d.n[f] < widget.faintBelow) : predictedStyleIndex(band, d.o[f]));
      out.add(CellShape.slice(d.latLon, d.starts[f], d.starts[f + 1], style));
    }
    if (_shapes.length > 600) _shapes.remove(_shapes.keys.first);
    return _shapes[key] = out;
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final meta = widget.meta;
    final measured = widget.layer != CoverageTileLayer.predicted; // measured and heard follow the measured zoom rules
    if (!measured && camera.zoom < meta.predictedFromZoom) return const SizedBox.shrink();
    final z = coverageTileZoom(camera.zoom);
    final b = camera.visibleBounds;
    final preset = meta.defaultPreset;
    final version = meta.versionFor(widget.layer);
    final used = <String>[];
    final parts = <List<CellShape>>[];
    // Stand-ins come only from tiles of the same kind: at a hexagon zoom (>= meta.hexFromZoom) never from a point tile below it.
    // Andy's field shot (dark, z14, Polaris, Nov 8): while the big z13/z14 Predicted tiles were still loading over cellular, the
    // z12 Predicted tile (a grid of points) stood in for them and drew a fine dot-matrix over the whole area. A gap that fills in
    // as the hexagon tile lands is honest; dots at a hexagon zoom are not.
    final hexes = z >= meta.hexFromZoom;
    final minZ = hexes ? meta.hexFromZoom : (measured ? 0 : meta.predictedFromZoom);
    for (final (x, y) in tilesCovering(b.south, b.west, b.north, b.east, z)) {
      final key = coverageTileKey(widget.layer, preset, version, z, x, y);
      final d = widget.store.peek(key);
      if (d != null) {
        used.add(key);
        parts.add(_shapesOf(key, d));
        continue;
      }
      widget.store.want(widget.layer, preset, version, z, x, y);
      // Stand-in: the nearest loaded ancestor (its cells cover this tile too).
      for (var pz = z - 1, px = x >> 1, py = y >> 1; pz >= minZ && pz >= z - 4; pz--, px >>= 1, py >>= 1) {
        final pk = coverageTileKey(widget.layer, preset, version, pz, px, py);
        final pd = widget.store.peek(pk);
        if (pd == null) continue;
        if (!used.contains(pk)) {
          used.add(pk);
          parts.add(_shapesOf(pk, pd));
        }
        break;
      }
    }
    final sig = used.join(',');
    if (_stylesFor != widget.colors || _styles == null) {
      _styles = switch (widget.layer) {
        CoverageTileLayer.measured => measuredStyles(widget.colors),
        CoverageTileLayer.predicted => predictedStyles(widget.colors),
        CoverageTileLayer.heard => heardStyles(widget.colors),
      };
      _stylesFor = widget.colors;
      _usedSig = '';
    }
    if (sig != _usedSig) {
      _usedSig = sig;
      final all = parts.length == 1 ? parts.single : [for (final p in parts) ...p];
      _data = CellLayerData(all, _styles!,
          dotBelowZoom: meta.hexFromZoom.toDouble(), dotPx: widget.layer == CoverageTileLayer.heard ? kHeardDotPx : (measured ? 3 : 2));
    }
    if (_data.isEmpty) return const SizedBox.shrink();
    return CellRasterLayer(key: ValueKey('coverage-tiles-${widget.layer.name}'), data: _data);
  }
}

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
