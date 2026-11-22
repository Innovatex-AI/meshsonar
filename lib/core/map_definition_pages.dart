// Map Definition version 2, MAP slices 4 to 6 (app half, build 74): the blocks the site added on Nov 22 2026 (meshcore-insights
// #373 to #375; schemaMinor 7): `pages` (one preset per page: its layers, basemap, panels, names, colour-by), `pages.aliases`
// (old layer words), `pages.breakpoints`, `pages.mapHeights`, `variables` (basemap, palette, colourBy) and `filters.node`.
// Every getter answers null (or an empty collection) when the block is missing, so an older definition (the bundled copy, a
// version 1 answer) leaves the caller on what build 73 drew. The definition has NO `drive` and NO `plan` page: those two
// presets stay the app's own. Pure Dart: no Flutter imports.
import 'map_definition.dart';

Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
List<String> _strings(Object? v) => [if (v is List) for (final e in v) if (e is String) e];

/// One page preset (`pages.pages[]`).
class MapPagePreset {
  final String id, name;

  /// `full` (a map page with its panels) or `still` (a small map inside a page).
  final String mode;

  /// The basemap id the page opens with (`road`, `topo`, ...), or null to keep the reader's saved choice.
  final String? basemap;

  /// Layer ids on when the page opens (already passed through `pages.aliases`).
  final List<String> layers;
  final List<String> panels;

  /// Whether node names show; null = the page does not say.
  final bool? names;
  final String? colourBy, camera;

  /// `short`, `standard` or `tall` for a still map; null when the page does not say.
  final String? height;
  final Map<String, dynamic> json;
  const MapPagePreset({
    required this.id,
    required this.name,
    required this.mode,
    required this.layers,
    required this.panels,
    required this.json,
    this.basemap,
    this.names,
    this.colourBy,
    this.camera,
    this.height,
  });

  bool get isStill => mode == 'still';
  bool has(String layerId) => layers.contains(layerId);
}

extension MapDefinitionPages on MapDefinition {
  Map<String, dynamic> get _pages => _map(json['pages']);

  /// True when the definition carries page presets (schemaMinor 7 and later).
  bool get hasPages => _pages['pages'] is List && (_pages['pages'] as List).isNotEmpty;

  /// Old layer words -> today's layer ids (`nodes` -> `repeaters`, `heardcells` -> `heard`). Empty when absent.
  Map<String, String> get layerAliases => {
        for (final e in _map(_pages['aliases']).entries)
          if (e.value is String) e.key: e.value as String,
      };

  /// [id] with its alias applied.
  String layerIdOf(String id) => layerAliases[id] ?? id;

  /// Every page id the definition presets, in its order.
  List<String> get pageIds => [
        if (_pages['pages'] is List)
          for (final p in _pages['pages'] as List)
            if (p is Map && p['id'] is String) p['id'] as String,
      ];

  /// The preset of page [id], or null when the definition has none (the caller keeps its build 73 behaviour).
  MapPagePreset? pagePreset(String id) {
    final list = _pages['pages'];
    if (list is! List) return null;
    for (final raw in list) {
      if (raw is! Map || raw['id'] != id) continue;
      final p = raw.cast<String, dynamic>();
      return MapPagePreset(
        id: id,
        name: p['name'] is String ? p['name'] as String : id,
        mode: p['mode'] is String ? p['mode'] as String : 'full',
        basemap: p['basemap'] is String ? p['basemap'] as String : null,
        layers: [for (final l in _strings(p['layers'])) layerIdOf(l)],
        panels: _strings(p['panels']),
        names: p['names'] is bool ? p['names'] as bool : null,
        colourBy: p['colourBy'] is String ? p['colourBy'] as String : null,
        camera: p['camera'] is String ? p['camera'] as String : null,
        height: p['height'] is String ? p['height'] as String : null,
        json: p,
      );
    }
    return null;
  }

  /// `pages.breakpoints.tablet` / `.desktop` in logical px; null when absent.
  int? get tabletBreakpoint => (_map(_pages['breakpoints'])['tablet'] as num?)?.toInt();
  int? get desktopBreakpoint => (_map(_pages['breakpoints'])['desktop'] as num?)?.toInt();

  /// Height of a still map: `short` and `standard` in px; null when absent or for a name the definition does not carry.
  double? stillMapHeight(String name) {
    final v = _map(_pages['mapHeights'])[name];
    return v is num ? v.toDouble() : null;
  }

  /// The tall map rule (`share` of the screen height between `minPx` and `maxPx`); null when absent.
  ({double share, double minPx, double maxPx})? get tallMapHeight {
    final t = _map(_pages['mapHeights'])['tall'];
    if (t is! Map) return null;
    final share = t['share'], lo = t['minPx'], hi = t['maxPx'];
    if (share is! num || lo is! num || hi is! num) return null;
    return (share: share.toDouble(), minPx: lo.toDouble(), maxPx: hi.toDouble());
  }

  Map<String, dynamic> get _variables => _map(json['variables']);

  /// `variables.basemap.ids` (`road`, `relief`, `plain`, `topo`, `satellite`); null when the definition does not say, which
  /// keeps the app on its build 73 basemap list.
  List<String>? get basemapVariableIds {
    final ids = _strings(_map(_variables['basemap'])['ids']);
    return ids.isEmpty ? null : ids;
  }

  String? get basemapVariableDefault => _map(_variables['basemap'])['default'] as String?;

  /// `variables.palette.ids`; null when absent.
  List<String>? get paletteVariableIds {
    final ids = _strings(_map(_variables['palette'])['ids']);
    return ids.isEmpty ? null : ids;
  }

  /// `filters.node` (status, byte size, last heard ...) as sent; empty when absent.
  Map<String, dynamic> get nodeFilters => _map(_map(json['filters'])['node']);
}
