// Map Definition version 2 `symbols.tools` (MAP slice 6, app half, build 74): the style of the tool and drive maps, written once
// for the website (meshcore-insights src/lib/map/tool-style.ts) and the app: a privacy zone, the part of a drive the public does
// not see, the zone editor's handles. Every getter answers null when the block (or one of its three parts) is missing or damaged,
// so a definition without it (the bundled copy, an older server answer) leaves each map on exactly what build 73 drew. No colour
// is written here. Pure Dart: no Flutter imports; colours are ARGB ints.
import 'map_definition.dart';

/// A colour in the two themes.
class ToolColour {
  final int light, dark;
  const ToolColour(this.light, this.dark);
  int of({required bool dark}) => dark ? this.dark : light;

  @override
  bool operator ==(Object other) => other is ToolColour && other.light == light && other.dark == dark;
  @override
  int get hashCode => Object.hash(light, dark);
}

/// A value for the normal and the active (selected) state.
class ToolPair {
  final double normal, active;
  const ToolPair(this.normal, this.active);
  double of({required bool active}) => active ? this.active : normal;
}

/// A privacy zone: a filled circle with a dashed edge.
class ZoneToolStyle {
  final String label;
  final ToolColour fill, edge;
  final ToolPair fillOpacity, edgeWidthPx;

  /// Dash and gap in multiples of the edge width (the MapLibre `line-dasharray` rule the website uses); null = solid.
  final List<double>? dash;
  const ZoneToolStyle({required this.label, required this.fill, required this.edge, required this.fillOpacity, required this.edgeWidthPx, this.dash});
}

/// The part of a drive the public does not see: faded and dashed.
class HiddenTrackToolStyle {
  final String label;
  final ToolColour colour;
  final double opacity, widthPx;
  final List<double>? dash;
  const HiddenTrackToolStyle({required this.label, required this.colour, required this.opacity, required this.widthPx, this.dash});
}

/// The zone editor's handles: the resize handle (fill + edge) and the move handle's fill.
class HandleToolStyle {
  final ToolColour fill, edge, moveFill;
  const HandleToolStyle({required this.fill, required this.edge, required this.moveFill});
}

Map<String, dynamic>? _obj(Object? v) => v is Map ? v.cast<String, dynamic>() : null;

ToolColour? _colour(Object? v) {
  final m = _obj(v);
  if (m == null) return null;
  final l = m['light'], d = m['dark'];
  if (l is! String || d is! String) return null;
  try {
    return ToolColour(parseHexColour(l), parseHexColour(d));
  } on FormatException {
    return null;
  }
}

ToolPair? _pair(Object? v) {
  final m = _obj(v);
  if (m == null) return null;
  final n = m['normal'], a = m['active'];
  return n is num && a is num ? ToolPair(n.toDouble(), a.toDouble()) : null;
}

List<double>? _dash(Object? v) {
  if (v is! List) return null;
  final out = [for (final e in v) if (e is num && e.isFinite && e >= 0) e.toDouble()];
  return out.length == v.length && out.length >= 2 && out.any((e) => e > 0) ? out : null;
}

/// `symbols.tools` of a definition.
class MapToolStyle {
  final ZoneToolStyle zone;
  final HiddenTrackToolStyle hiddenTrack;
  final HandleToolStyle handle;
  const MapToolStyle({required this.zone, required this.hiddenTrack, required this.handle});

  /// The tool style of [d], or null when `symbols.tools` is missing or any of zone, hiddenTrack or handle is unusable.
  static MapToolStyle? of(MapDefinition d) {
    final t = _obj(_obj(d.json['symbols'])?['tools']);
    if (t == null) return null;
    final z = _obj(t['zone']), h = _obj(t['hiddenTrack']), k = _obj(t['handle']);
    if (z == null || h == null || k == null) return null;
    final zFill = _colour(z['fill']), zEdge = _colour(z['edge']);
    final zOpacity = _pair(z['fillOpacity']), zWidth = _pair(z['edgeWidthPx']);
    final hColour = _colour(h['colour']);
    final hOpacity = h['opacity'], hWidth = h['widthPx'];
    final kFill = _colour(k['fill']), kEdge = _colour(k['edge']), kMove = _colour(k['moveFill']);
    if (zFill == null || zEdge == null || zOpacity == null || zWidth == null) return null;
    if (hColour == null || hOpacity is! num || hWidth is! num) return null;
    if (kFill == null || kEdge == null || kMove == null) return null;
    return MapToolStyle(
      zone: ZoneToolStyle(
        label: z['label'] is String ? z['label'] as String : 'Privacy zone',
        fill: zFill,
        edge: zEdge,
        fillOpacity: zOpacity,
        edgeWidthPx: zWidth,
        dash: _dash(z['dash']),
      ),
      hiddenTrack: HiddenTrackToolStyle(
        label: h['label'] is String ? h['label'] as String : 'Hidden from the public: faded and dashed',
        colour: hColour,
        opacity: hOpacity.toDouble(),
        widthPx: hWidth.toDouble(),
        dash: _dash(h['dash']),
      ),
      handle: HandleToolStyle(fill: kFill, edge: kEdge, moveFill: kMove),
    );
  }
}
