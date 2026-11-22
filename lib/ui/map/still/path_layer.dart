// The ONE path overlay for the small maps (MAP slice 5, app half; the website's components/map/path-layer.ts and path-key.tsx):
// a numbered, named route. Hops are discs with their number and an "N · Name" label under them; a certain link is solid and a
// likely one dashed; the observer that heard it gets the observer symbol. A hop with no position is never drawn, the line stops
// there, and the caller lists the unplaced hops ([PathSpec.unplaced]) with the style's unplaced note ([PathKey]). Everything is
// read from the Map Definition's `symbols.path` ([MapPathStyle]); with none, callers keep what build 73 drew.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../core/map_path_style.dart';
import '../active_map_definition.dart';
import '../node_symbol.dart';

export '../../../core/map_path_style.dart' show MapPathStyle, PathCertainty;

/// The style of the definition every map draws from right now; null = it has no `symbols.path`.
MapPathStyle? activePathStyle() => MapPathStyle.of(ActiveMapDefinition.current);

/// One hop of a path. [n] is its place in the full path (1-based), the number the list beside the map shows; a hop with no
/// position keeps its number and is left out of the drawing.
class PathHop {
  final int n;
  final String name;
  final double? lat, lon;
  final PathCertainty certainty;
  const PathHop({required this.n, required this.name, this.lat, this.lon, this.certainty = PathCertainty.certain});
  bool get placed => lat != null && lon != null;
  LatLng? get point => placed ? LatLng(lat!, lon!) : null;
}

/// An observer that heard the packet (a public position only).
class PathObserverPoint {
  final double lat, lon;
  final String? name;
  const PathObserverPoint({required this.lat, required this.lon, this.name});
}

/// A path: its hops in order, and the observers that heard it.
class PathSpec {
  final List<PathHop> hops;
  final List<PathObserverPoint> observers;

  /// True = consecutive hops are joined by a line (a route); false = the hops are drawn on their own (a set of repeaters).
  final bool chain;

  /// True = the discs carry their number and the label is "N · Name"; false = no number, the label is the name.
  final bool numbered;
  const PathSpec({required this.hops, this.observers = const [], this.chain = true, this.numbered = true});

  /// Hops with a position, in order.
  List<PathHop> get placed => [for (final h in hops) if (h.placed) h];

  /// Hops with no position: listed beside the map, never drawn.
  List<PathHop> get unplaced => [for (final h in hops) if (!h.placed) h];

  /// Every point the map should frame.
  List<LatLng> get points => [for (final h in placed) h.point!, for (final o in observers) LatLng(o.lat, o.lon)];

  /// The links between consecutive hops. A link needs BOTH ends placed (a hop with no position breaks the chain, so the line
  /// stops there); it is certain only when both ends are certain.
  List<PathLink> get links {
    if (!chain) return const [];
    final out = <PathLink>[];
    for (var i = 1; i < hops.length; i++) {
      final a = hops[i - 1], b = hops[i];
      if (!a.placed || !b.placed) continue;
      out.add(PathLink(a.point!, b.point!, a.certainty == PathCertainty.certain && b.certainty == PathCertainty.certain ? PathCertainty.certain : PathCertainty.likely));
    }
    return out;
  }
}

class PathLink {
  final LatLng a, b;
  final PathCertainty certainty;
  const PathLink(this.a, this.b, this.certainty);
}

/// The path layer: links (solid and dashed), then the observer, then the labels, then the numbered discs on top.
class PathLayer extends StatelessWidget {
  final PathSpec spec;
  final MapPathStyle style;

  /// Test seam: null = the theme's brightness.
  final bool? dark;
  const PathLayer({super.key, required this.spec, required this.style, this.dark});

  @override
  Widget build(BuildContext context) {
    final isDark = dark ?? Theme.of(context).brightness == Brightness.dark;
    final c = style.colours(dark: isDark);
    final line = Color(c.line), disc = Color(c.disc), number = Color(c.number), halo = Color(c.halo);
    final links = spec.links;
    final solid = [for (final l in links) if (!style.isDashed(l.certainty)) l];
    final dashed = [for (final l in links) if (style.isDashed(l.certainty)) l];
    final w = style.widthPx;
    final r = style.discRadiusPx;
    final labelH = 16.0;
    final haloShadows = [for (final o in const [Offset(1, 0), Offset(-1, 0), Offset(0, 1), Offset(0, -1), Offset(1, 1), Offset(-1, -1)]) Shadow(color: halo, offset: o, blurRadius: 1)];
    return IgnorePointer(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (solid.isNotEmpty)
            PolylineLayer(
              key: const Key('path-lines-solid'),
              polylines: [for (final l in solid) Polyline(points: [l.a, l.b], strokeWidth: w, color: line, strokeCap: StrokeCap.round, strokeJoin: StrokeJoin.round)],
            ),
          if (dashed.isNotEmpty)
            PolylineLayer(
              key: const Key('path-lines-dashed'),
              polylines: [
                for (final l in dashed)
                  Polyline(
                    points: [l.a, l.b],
                    strokeWidth: w,
                    color: line,
                    pattern: StrokePattern.dashed(segments: [for (final d in style.dash) d * w]),
                    strokeJoin: StrokeJoin.round,
                  ),
              ],
            ),
          if (spec.observers.isNotEmpty)
            MarkerLayer(
              key: const Key('path-observers'),
              markers: [
                for (final o in spec.observers)
                  Marker(point: LatLng(o.lat, o.lon), width: 28, height: 28, child: Center(child: NodeSymbol(role: style.observerSymbol, size: 22, scaled: false, dark: isDark))),
              ],
            ),
          MarkerLayer(
            key: const Key('path-labels'),
            markers: [
              for (final h in spec.placed)
                Marker(
                  point: h.point!,
                  width: 170,
                  height: 2 * (r + 3 + labelH),
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    child: Text(
                      spec.numbered ? style.labelFor(h.n, h.name) : h.name,
                      key: Key('path-label-${h.n}'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, height: 1.2, fontWeight: FontWeight.w600, color: Color(isDark ? 0xFFE6EDF3 : 0xFF0D1117), shadows: haloShadows),
                    ),
                  ),
                ),
            ],
          ),
          MarkerLayer(
            key: const Key('path-discs'),
            markers: [
              for (final h in spec.placed)
                Marker(
                  point: h.point!,
                  width: 2 * r + 4,
                  height: 2 * r + 4,
                  child: Container(
                    key: Key('path-disc-${h.n}'),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: disc, shape: BoxShape.circle, border: Border.all(color: halo, width: 2)),
                    child: spec.numbered
                        ? Text('${h.n}', style: TextStyle(fontSize: style.numberPx, height: 1, fontWeight: FontWeight.w700, color: number))
                        : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The legend line of a path map (the website's PathKey): the numbered hop, certain (solid) and likely (dashed) links, the
/// observer, and the rule for hops with no position. One widget for every page that shows a path.
class PathKey extends StatelessWidget {
  final MapPathStyle style;
  final bool observers;

  /// Hops with no position, of [total]; 0 = say the style's rule instead.
  final int unplaced, total;
  final bool? dark;
  const PathKey({super.key, required this.style, this.observers = false, this.unplaced = 0, this.total = 0, this.dark});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final isDark = dark ?? t.brightness == Brightness.dark;
    final c = style.colours(dark: isDark);
    final line = Color(c.line);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    Widget item(Widget mark, String text) => Row(mainAxisSize: MainAxisSize.min, children: [mark, const SizedBox(width: 6), Flexible(child: Text(text, style: muted))]);
    Widget swatch(bool dashed) => SizedBox(
          width: 26,
          height: 8,
          child: CustomPaint(painter: _KeyLinePainter(line, dashed, style.widthPx, style.dash)),
        );
    return Semantics(
      container: true,
      label: 'Map key. Hops are numbered in order and named. A solid line is certain, a dashed line is likely. '
          '${unplaced > 0 ? '$unplaced of $total hops have no position: listed, not drawn.' : style.unplacedNote}',
      excludeSemantics: true,
      child: Wrap(
        key: const Key('path-key'),
        spacing: 14,
        runSpacing: 6,
        children: [
          item(
            Container(
              width: 18,
              height: 18,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: Color(c.disc), shape: BoxShape.circle, border: Border.all(color: Color(c.halo), width: 1.5)),
              child: Text('1', style: TextStyle(fontSize: 10, height: 1, fontWeight: FontWeight.w700, color: Color(c.number))),
            ),
            'Hop, numbered in order, named N · Name',
          ),
          item(swatch(false), 'Certain: a solid line'),
          item(swatch(true), 'Likely: a dashed line'),
          if (observers) item(NodeSymbol(role: style.observerSymbol, size: 18, scaled: false, dark: isDark), style.observerLabel),
          Text(
            unplaced > 0 ? '$unplaced of $total hops have no position: listed, not drawn.' : style.unplacedNote,
            key: const Key('path-key-unplaced'),
            style: muted,
          ),
        ],
      ),
    );
  }
}

class _KeyLinePainter extends CustomPainter {
  final Color color;
  final bool dashed;
  final double width;
  final List<double> dash;
  _KeyLinePainter(this.color, this.dashed, this.width, this.dash);

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = color
      ..strokeWidth = width
      ..strokeCap = dashed ? StrokeCap.butt : StrokeCap.round;
    final y = size.height / 2;
    if (!dashed) {
      canvas.drawLine(Offset(width / 2, y), Offset(size.width - width / 2, y), p);
      return;
    }
    final on = dash.first * width / 2, off = dash.last * width / 2;
    for (var x = 0.0; x < size.width; x += on + off) {
      canvas.drawLine(Offset(x, y), Offset((x + on).clamp(0, size.width), y), p);
    }
  }

  @override
  bool shouldRepaint(_KeyLinePainter o) => o.color != color || o.dashed != dashed || o.width != width;
}
