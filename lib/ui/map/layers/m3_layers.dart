// The M3-2 map layers (Map Definition layers `estimated`, `redundancy`, `snrlinks`; plan unified-map-system §8b M3-2), the same as the
// website's (meshcore-insights src/components/map/m3-layers.ts). Every colour, opacity and width is read from the definition
// (`symbols.estimated`, `symbols.redundancy`, `symbols.snrLink`, the palette's signal bands): the app invents none.
//
//   Estimated positions  the repeater symbol of its freshness state drawn at the position the SERVER gave (never moved, never
//                        clustered), paler the less sure (`symbols.estimated.opacity` by confidence). Keys 'map-estimated-<key>'.
//   Redundancy           res-11 hexagons coloured by how many distinct repeaters were measured there (steps 1, 2, 3, 4+, the
//                        definition's purple ramp, `symbols.redundancy`); drawn on the app's cell raster ('redundancy-layer').
//   Links by SNR         one line per located repeater pair: casing, then the line in the palette band colour of its SNR (no SNR =
//                        the neutral colour, dashed); width = packets on a log scale. Keys 'snr-links-layer', 'snr-links-none-layer'.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:h3_flutter/h3_flutter.dart' show H3;
import 'package:latlong2/latlong.dart';

import '../../../core/hex_cells.dart' show HexPoint;
import '../../../core/m3_data.dart';
import '../../../core/map_definition.dart';
import '../cell_raster_layer.dart';
import 'repeater_sprites.dart';

/// The definition's redundancy colour of [step] (1..4) in the theme.
Color redundancyColour(MapDefinition d, int step, {required bool dark}) {
  final c = d.symbol('redundancy')['colours'];
  final list = c is Map ? c[dark ? 'dark' : 'light'] : null;
  if (list is List && list.isNotEmpty) {
    final i = (step - 1).clamp(0, list.length - 1);
    return Color(parseHexColour(list[i] as String));
  }
  return const Color(0xFF8A5FC4); // a definition without the ramp has no Redundancy layer, so this is never drawn
}

/// The cell raster data of the Redundancy layer: one style per step, hexagons from the H3 engine (cells it cannot read are left out).
CellLayerData redundancyLayerData(List<RedundancyCell> cells, MapDefinition d, H3? h3, {required bool dark, double? dotBelowZoom}) {
  if (h3 == null || cells.isEmpty) return CellLayerData.empty;
  final opacity = d.symbol('redundancy')['opacity'] is num ? (d.symbol('redundancy')['opacity'] as num).toDouble() : 0.72;
  final usable = <(RedundancyCell, List<HexPoint>)>[];
  for (final c in cells) {
    try {
      usable.add((c, [for (final g in h3.cellToBoundary(BigInt.parse(c.h3, radix: 16))) HexPoint(g.lat, g.lon)]));
    } catch (_) {
      continue;
    }
  }
  final styles = <int, CellStyle>{for (var s = 1; s <= 4; s++) s: CellStyle(redundancyColour(d, s, dark: dark).withValues(alpha: opacity), const Color(0x00000000), 0)};
  final built = CellLayerData.build(usable.length, (i) => usable[i].$2, (i) => styles[usable[i].$1.step]!);
  // Zoomed out a res-11 cell is under 2 px: draw it as a dot there, like the coverage layers (meta `hexFromZoom`).
  return CellLayerData(built.shapes, built.styles, dotBelowZoom: dotBelowZoom, dotPx: 3);
}

/// The marker opacity of an estimate, the sprite spec for it and the symbol theme: shared with the legend key.
RepeaterSpriteSpec estimateSpriteSpec(RepeaterEstimate e, RepeaterFreshness f) => RepeaterSpriteSpec(f, e.role == 'room', SpriteVariant.badgeLarge);

class EstimatedRepeaterLayer extends StatelessWidget {
  final List<RepeaterEstimate> estimates;
  final RepeaterFreshness Function(String key) freshnessOf;
  final MapDefinition definition;
  final void Function(RepeaterEstimate e)? onTap;
  const EstimatedRepeaterLayer({super.key, required this.estimates, required this.freshnessOf, required this.definition, this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final theme = RepeaterSpriteTheme(brightness: t.brightness, accent: t.colorScheme.primary, ok: t.colorScheme.primary, highContrast: MediaQuery.maybeHighContrastOf(context) ?? false);
    return MarkerLayer(
      markers: [
        for (final e in estimates)
          Marker(
            point: LatLng(e.lat, e.lon),
            width: 40,
            height: 40,
            child: Semantics(
              button: onTap != null,
              label: 'Estimated position of ${e.name ?? 'a repeater'}, approximate. ${e.confidenceText(definition)}',
              excludeSemantics: true,
              onTap: onTap == null ? null : () => onTap!(e),
              child: GestureDetector(
                key: ValueKey('map-estimated-${e.key}'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null ? null : () => onTap!(e),
                child: Center(
                  child: Opacity(
                    key: ValueKey('map-estimated-${e.key}-${e.confidence.name}'),
                    opacity: e.opacity(definition),
                    child: CustomPaint(size: const Size.square(kSpriteCell), painter: _EstimatePainter(estimateSpriteSpec(e, freshnessOf(e.key)), theme)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _EstimatePainter extends CustomPainter {
  final RepeaterSpriteSpec spec;
  final RepeaterSpriteTheme theme;
  _EstimatePainter(this.spec, this.theme);

  @override
  void paint(Canvas canvas, Size size) => paintRepeaterSprite(canvas, size.center(Offset.zero), spec, theme);

  @override
  bool shouldRepaint(_EstimatePainter old) => old.spec != spec || old.theme != theme;
}

/// The neutral (no SNR) line colour, the casing colour and their opacities from `symbols.snrLink`.
class SnrLinkStyle {
  final Color noSnr, casing;
  final double opacity, casingOpacity;
  const SnrLinkStyle(this.noSnr, this.casing, this.opacity, this.casingOpacity);
  static SnrLinkStyle of(MapDefinition d, {required bool dark}) {
    final s = d.symbol('snrLink');
    Color c(String k) {
      final m = s[k];
      final v = m is Map ? m[dark ? 'dark' : 'light'] : null;
      return v is String ? Color(parseHexColour(v)) : const Color(0xFF808080);
    }
    return SnrLinkStyle(c('noSnr'), c('casing'), (s['opacity'] as num?)?.toDouble() ?? 0.85, (s['casingOpacity'] as num?)?.toDouble() ?? 0.6);
  }
}

/// The Links by SNR layers: casings, lines with an SNR (palette band colour), and the dashed neutral lines (no SNR).
List<Widget> snrLinkLayers(List<SnrLink> links, MapDefinition d, {required SignalColoursDef signal, required bool dark}) {
  if (links.isEmpty) return const [];
  final st = SnrLinkStyle.of(d, dark: dark);
  Color band(int b) => Color(signal.bands[b.clamp(0, signal.bands.length - 1)]).withValues(alpha: st.opacity);
  List<LatLng> pts(SnrLink l) => [LatLng(l.aLat, l.aLon), LatLng(l.bLat, l.bLon)];
  // Wider lines under narrower ones: the thin links stay visible where they cross a thick one.
  final order = [...links]..sort((a, b) => b.width.compareTo(a.width));
  return [
    PolylineLayer(
      key: const Key('snr-links-case-layer'),
      polylines: [for (final l in order) Polyline(points: pts(l), strokeWidth: l.width + 1.6, color: st.casing.withValues(alpha: st.casingOpacity), strokeCap: StrokeCap.round, strokeJoin: StrokeJoin.round)],
    ),
    PolylineLayer(
      key: const Key('snr-links-layer'),
      polylines: [for (final l in order) if (l.band != 0) Polyline(points: pts(l), strokeWidth: l.width, color: band(l.band), strokeCap: StrokeCap.round, strokeJoin: StrokeJoin.round)],
    ),
    PolylineLayer(
      key: const Key('snr-links-none-layer'),
      polylines: [
        for (final l in order)
          if (l.band == 0)
            Polyline(points: pts(l), strokeWidth: l.width, color: st.noSnr.withValues(alpha: st.opacity), pattern: StrokePattern.dashed(segments: const [6, 5]), strokeCap: StrokeCap.butt),
      ],
    ),
  ];
}
