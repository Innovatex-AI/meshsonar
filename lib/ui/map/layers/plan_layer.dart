// The `plan` layer's drawing (registry.dart kPlanLayerId, z 80, on top of everything): planned links as dashed lines coloured
// by their Estimate, then the plan's nodes and the targets as markers. Colours, ring and dash come from the Map Definition's
// `symbols.plan` (the same numbers the website reads), so web and app agree. Also the legend keys for the definition's `plan`
// and `planlink` legend symbols.
//
// Keys: 'plan-layer' (the markers), 'plan-links-layer', 'plan-node-<id>' (one marker, tappable), 'plan-legend-node',
// 'plan-legend-link'.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_definition.dart' show MapDefinition;
import '../../design/app_symbols.dart';
import '../../theme.dart';
import '../active_map_definition.dart';
import '../coverage_bands.dart';
import 'plan_overlay.dart';

/// The plan symbol's colours for one theme (Map Definition `symbols.plan.colours`).
@immutable
class PlanSymbolStyle {
  final Color disc, ring, icon;
  final double sizePx, linkWidthPx;
  final List<double> linkDash;
  final Map<String, int> verdictBand;
  const PlanSymbolStyle({
    required this.disc,
    required this.ring,
    required this.icon,
    this.sizePx = 24,
    this.linkWidthPx = 3,
    this.linkDash = const [6, 4],
    this.verdictBand = const {'likely': 5, 'marginal': 3, 'unlikely': 1},
  });

  static PlanSymbolStyle of(MapDefinition def, {required bool dark}) {
    final s = def.symbol('plan');
    double num0(Object? v, double d) => v is num ? v.toDouble() : d;
    final dash = s['linkDash'];
    final vb = s['verdictBand'];
    return PlanSymbolStyle(
      disc: Color(def.symbolColour('plan', 'disc', dark: dark, fallback: dark ? 0xFFCE93D8 : 0xFF6A1B9A)),
      ring: Color(def.symbolColour('plan', 'ring', dark: dark, fallback: dark ? 0xFFCE93D8 : 0xFF6A1B9A)),
      icon: Color(def.symbolColour('plan', 'icon', dark: dark, fallback: dark ? 0xFF12161B : 0xFFFFFFFF)),
      sizePx: num0(s['sizePx'], 24),
      linkWidthPx: num0(s['linkWidthPx'], 3),
      linkDash: dash is List && dash.length >= 2 && dash.every((e) => e is num && e > 0) ? [for (final e in dash) (e as num).toDouble()] : const [6, 4],
      verdictBand: vb is Map ? {for (final e in vb.entries) if (e.key is String && e.value is int) e.key as String: e.value as int} : const {'likely': 5, 'marginal': 3, 'unlikely': 1},
    );
  }

  /// The colour of a planned link with [verdict]: the coverage band the definition maps it to, else the ring colour.
  Color linkColour(PlanLinkVerdict verdict, CoverageBandColors bands) {
    final b = verdictBand[verdict.name];
    return b == null ? ring : bands[b];
  }
}

/// The marker of one plan node: a disc with a tower (a flag for a target), ringed dashed while planned, solid once installed.
class PlanNodeMarker extends StatelessWidget {
  final PlanOverlayNodeKind kind;
  final PlanSymbolStyle style;

  /// The target ring uses the app's accent so a place to drive to reads apart from a planned site.
  final Color targetColour;
  final double size;
  const PlanNodeMarker({super.key, required this.kind, required this.style, required this.targetColour, this.size = 24});

  @override
  Widget build(BuildContext context) {
    final target = kind == PlanOverlayNodeKind.target;
    final disc = target ? targetColour : style.disc;
    return SizedBox.square(
      dimension: size + 10,
      child: CustomPaint(
        painter: _PlanRingPainter(colour: target ? targetColour : style.ring, dashed: kind == PlanOverlayNodeKind.planned, radius: size / 2 + 4),
        child: Center(
          child: Container(
            width: size,
            height: size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: disc),
            alignment: Alignment.center,
            child: AppSymbolIcon(target ? AppSymbols.flag : AppSymbols.antenna, size: size * 0.6, color: style.icon),
          ),
        ),
      ),
    );
  }
}

class _PlanRingPainter extends CustomPainter {
  final Color colour;
  final bool dashed;
  final double radius;
  const _PlanRingPainter({required this.colour, required this.dashed, required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = colour;
    if (!dashed) {
      canvas.drawCircle(c, radius, p);
      return;
    }
    const segments = 12;
    const sweep = 2 * math.pi / segments;
    final rect = Rect.fromCircle(center: c, radius: radius);
    for (var i = 0; i < segments; i++) {
      canvas.drawArc(rect, i * sweep, sweep * 0.6, false, p);
    }
  }

  @override
  bool shouldRepaint(_PlanRingPainter o) => o.colour != colour || o.dashed != dashed || o.radius != radius;
}

/// The links of the plan (under the markers).
class PlanLinksLayer extends StatelessWidget {
  final List<PlanOverlayNode> nodes;
  final List<PlanOverlayLink> links;
  const PlanLinksLayer({super.key, required this.nodes, required this.links});

  @override
  Widget build(BuildContext context) {
    final def = ActiveMapDefinition.current;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final style = PlanSymbolStyle.of(def, dark: dark);
    final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, Theme.of(context).brightness, definition: def);
    final at = {for (final n in nodes) n.id: n.at};
    final lines = <Polyline>[
      for (final l in links)
        if (at[l.fromId] != null && at[l.toId] != null && l.fromId != l.toId)
          Polyline(
            points: [at[l.fromId]!, at[l.toId]!],
            strokeWidth: style.linkWidthPx,
            color: style.linkColour(l.verdict, bands),
            pattern: StrokePattern.dashed(segments: style.linkDash),
          ),
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return PolylineLayer(key: const Key('plan-links-layer'), polylines: lines);
  }
}

/// The plan's nodes and the targets. [onTap] gets the node tapped (the map turns it into a [PlanNodeHit]).
class PlanNodesLayer extends StatelessWidget {
  final List<PlanOverlayNode> nodes;
  final ValueChanged<PlanOverlayNode>? onTap;
  const PlanNodesLayer({super.key, required this.nodes, this.onTap});

  /// The marker's hit box (44 pt, the app's minimum target).
  static const double hitSize = 44;

  @override
  Widget build(BuildContext context) {
    if (nodes.isEmpty) return const SizedBox.shrink();
    final t = Theme.of(context);
    final style = PlanSymbolStyle.of(ActiveMapDefinition.current, dark: t.brightness == Brightness.dark);
    return MarkerLayer(
      key: const Key('plan-layer'),
      markers: [
        for (final n in nodes)
          Marker(
            point: n.at,
            width: hitSize,
            height: hitSize,
            child: Semantics(
              button: onTap != null,
              label: '${n.kindLabel}: ${n.name}',
              child: GestureDetector(
                key: ValueKey('plan-node-${n.id}'),
                behavior: HitTestBehavior.opaque,
                onTap: onTap == null ? null : () => onTap!(n),
                child: Center(child: ExcludeSemantics(child: PlanNodeMarker(kind: n.kind, style: style, targetColour: t.colorScheme.primary, size: style.sizePx))),
              ),
            ),
          ),
      ],
    );
  }
}

/// The whole plan layer from a controller: links, then nodes. Redraws when the controller changes.
List<Widget> planLayerWidgets(PlanOverlayController overlay, {ValueChanged<PlanOverlayNode>? onTap}) => [
  ListenableBuilder(
    listenable: overlay,
    builder: (context, _) => PlanLinksLayer(nodes: overlay.drawnNodes, links: overlay.plan.links),
  ),
  ListenableBuilder(
    listenable: overlay,
    builder: (context, _) => PlanNodesLayer(nodes: overlay.drawnNodes, onTap: onTap),
  ),
];

/// The node under [point] (screen offsets of [camera]) within half a marker's hit box, nearest first; null when none.
PlanOverlayNode? planNodeAt(List<PlanOverlayNode> nodes, MapCamera camera, LatLng point, {double radius = PlanNodesLayer.hitSize / 2}) {
  final p = camera.latLngToScreenOffset(point);
  PlanOverlayNode? best;
  var bestD = double.infinity;
  for (final n in nodes) {
    final d = (camera.latLngToScreenOffset(n.at) - p).distance;
    if (d <= radius && d < bestD) {
      best = n;
      bestD = d;
    }
  }
  return best;
}

/// The legend key for the definition's `plan` (a planned node) and `planlink` (a planned link) symbols; null for any other.
Widget? planLegendKey(BuildContext context, String? symbol, {String? state}) {
  final t = Theme.of(context);
  final def = ActiveMapDefinition.current;
  final style = PlanSymbolStyle.of(def, dark: t.brightness == Brightness.dark);
  switch (symbol) {
    case 'plan':
      return ExcludeSemantics(
        key: const Key('plan-legend-node'),
        child: SizedBox.square(
          dimension: 18,
          child: FittedBox(child: PlanNodeMarker(kind: PlanOverlayNodeKind.planned, style: style, targetColour: t.colorScheme.primary, size: 14)),
        ),
      );
    case 'planlink':
      final bands = CoverageBandColors.of(MeshSonarColors.of(context).palette, t.brightness, definition: def);
      final verdict = PlanLinkVerdict.values.where((v) => v.name == state).firstOrNull ?? PlanLinkVerdict.unknown;
      final c = style.linkColour(verdict, bands);
      return ExcludeSemantics(
        key: const Key('plan-legend-link'),
        child: SizedBox(width: 16, height: 3, child: Row(children: [for (var i = 0; i < 3; i++) ...[Container(width: 4, height: 3, color: c), if (i < 2) const SizedBox(width: 2)]])),
      );
  }
  return null;
}
