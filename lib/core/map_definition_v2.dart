// Map Definition version 2, read by the app (MAP slices 1 to 3, Nov 22 2026; site PRs meshcore-insights #363, #367, #370;
// plan meshsonar-infra docs/planning/unified-map-engine-plan-2026-11-21.md sections 4.1 to 4.4).
//
// `GET /api/map/definition?v=2` is the version 1 body plus:
//   - `ladder` (slice 1): the coverage summary zoom ladder (tile zoom -> H3 resolution), the fill-strength rule and the summary
//     tile addresses; capability `coverage.summary`;
//   - `labels.spec` (slice 2): the Drive label rule as numbers (sizes by zoom, budget, ink and halo by the basemap showing,
//     the pill, which thing is named from which zoom, hold and fade); capability `labels.spec`;
//   - `symbols.set` (slice 3): ONE node symbol set as 24 x 24 path geometry, `variables.colourBy`, `packetTypes`; capabilities
//     `symbols.set`, `variables.colourBy`, `packetTypes`.
// Each reader falls back to the numbers the app already drew with (the Drive map's), so an older definition (the bundled copy,
// a version 1 answer) draws exactly what build 72 drew. Pure Dart: no Flutter imports.
import 'dart:math' as math;

import 'map_definition.dart';

const String kSummaryCapability = 'coverage.summary';
const String kLabelSpecCapability = 'labels.spec';
const String kSymbolSetCapability = 'symbols.set';
const String kColourByCapability = 'variables.colourBy';
const String kPacketTypesCapability = 'packetTypes';

List<Map<String, dynamic>> _maps(Object? v) => [if (v is List) for (final e in v) if (e is Map) e.cast<String, dynamic>()];
Map<String, dynamic> _map(Object? v) => v is Map ? v.cast<String, dynamic>() : const {};
double _d(Object? v, double f) => v is num && v.isFinite ? v.toDouble() : f;
int _i(Object? v, int f) => v is num && v.isFinite ? v.toInt() : f;

// ---------------------------------------------------------------------------------------------------------------- slice 1

/// The coverage zoom ladder (`ladder`). Summary hexagons (H3 res 5 to 10) are drawn from tile zoom [fromZoom] up to
/// [toZoom]; from [hexFromZoom] the res-11 hexagons are the picture (unchanged); below [fromZoom] the map keeps its dots.
class CoverageLadder {
  final int fromZoom, toZoom, hexFromZoom;
  final double minCellPx, strengthMin, strengthSpan;

  /// Tile zoom -> H3 resolution.
  final Map<int, int> steps;
  final String measuredUrl, predictedUrl;
  final String measuredLayer, predictedLayer;
  final String tapCard;
  const CoverageLadder({
    required this.fromZoom,
    required this.toZoom,
    required this.hexFromZoom,
    required this.minCellPx,
    required this.strengthMin,
    required this.strengthSpan,
    required this.steps,
    required this.measuredUrl,
    required this.predictedUrl,
    this.measuredLayer = 'measured-summary',
    this.predictedLayer = 'predicted-summary',
    this.tapCard = '/api/coverage/summary/{h3}?preset={preset}',
  });

  /// The ladder the server sent on Nov 22 2026 (used by tests and by nothing at run time: without `ladder` there is no summary).
  static const CoverageLadder nov22 = CoverageLadder(
    fromZoom: 5,
    toZoom: 12,
    hexFromZoom: 13,
    minCellPx: 6,
    strengthMin: 0.45,
    strengthSpan: 0.55,
    steps: {12: 10, 11: 9, 10: 9, 9: 8, 8: 7, 7: 6, 6: 6, 5: 5},
    measuredUrl: '/api/coverage/tiles/measured-summary/{z}/{x}/{y}.mvt?preset={preset}&v={version}',
    predictedUrl: '/api/coverage/tiles/predicted-summary/{z}/{x}/{y}.mvt?preset={preset}&v={version}',
  );

  /// H3 resolution of the summary cells in a tile of zoom [z], or null outside the ladder.
  int? resAt(int z) => z < fromZoom || z > toZoom ? null : steps[z];

  /// True when the summary picture is what the map draws at camera zoom [zoom] (from [fromZoom] up to the res-11 hexagons).
  bool drawsAt(double zoom) => zoom >= fromZoom && zoom < hexFromZoom;

  /// The tile zoom to read at camera zoom [zoom] (integer floor, inside the ladder).
  int tileZoom(double zoom) => (zoom.isNaN ? hexFromZoom - 1 : zoom.floor()).clamp(fromZoom, toZoom);

  /// How strongly a summary hexagon is filled: `min + span * sqrt(f)`, f = the share of the cell actually measured (0..1).
  /// One driven road in a big cell is light; a well-driven cell is solid (plan 4.4 honesty rule).
  double strength(double f) => strengthMin + strengthSpan * math.sqrt(f.isNaN ? 1.0 : f.clamp(0.0, 1.0));

  static CoverageLadder? fromJson(Map<String, dynamic> j) {
    final stepList = _maps(j['steps']);
    if (stepList.isEmpty) return null;
    final tiles = _map(j['tiles']);
    final m = _map(tiles['measured']), p = _map(tiles['predicted']);
    final st = _map(j['strength']);
    final steps = {for (final s in stepList) _i(s['z'], -1): _i(s['res'], -1)}..removeWhere((k, v) => k < 0 || v < 0);
    if (steps.isEmpty || m['url'] is! String || p['url'] is! String) return null;
    return CoverageLadder(
      fromZoom: _i(j['fromZoom'], 5),
      toZoom: _i(j['toZoom'], 12),
      hexFromZoom: _i(j['hexFromZoom'], 13),
      minCellPx: _d(j['minCellPx'], 6),
      strengthMin: _d(st['min'], 0.45),
      strengthSpan: _d(st['span'], 0.55),
      steps: steps,
      measuredUrl: m['url'] as String,
      predictedUrl: p['url'] as String,
      measuredLayer: m['sourceLayer'] as String? ?? 'measured-summary',
      predictedLayer: p['sourceLayer'] as String? ?? 'predicted-summary',
      tapCard: j['tapCard'] as String? ?? '/api/coverage/summary/{h3}?preset={preset}',
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- slice 2

/// One "what gets a name" row of `labels.spec.things`.
class LabelThing {
  final String id;
  final double fromZoom;

  /// A repeater that matters right now is named from here instead of [fromZoom].
  final double? importantFromZoom;
  final String text;
  final bool italic;
  final double opacity;
  const LabelThing(this.id, this.fromZoom, {this.importantFromZoom, this.text = 'name', this.italic = false, this.opacity = 1});
}

/// `labels.spec`: the Drive map's labels as numbers, for every map (plan 4.2).
class MapLabelSpec {
  /// (fromZoom, px) ascending.
  final List<(double, double)> sizes;

  /// (fromZoom, most labels) ascending; below the first entry nothing is named.
  final List<(double, int)> budget;
  final double maxWidthPx, haloPx, staleOpacity, pillRadius, pillAlpha, holdMs, fadeMs;
  final ({int light, int dark}) ink, halo;

  /// Basemap id -> `theme` (follow the app theme) or `light` / `dark` (the map is always that).
  final Map<String, String> basemapTone;

  /// Basemap ids whose names sit on a pill.
  final Set<String> pillOn;
  final Map<String, LabelThing> things;
  const MapLabelSpec({
    required this.sizes,
    required this.budget,
    required this.maxWidthPx,
    required this.haloPx,
    required this.staleOpacity,
    required this.pillRadius,
    required this.pillAlpha,
    required this.holdMs,
    required this.fadeMs,
    required this.ink,
    required this.halo,
    required this.basemapTone,
    required this.pillOn,
    required this.things,
  });

  /// What build 72 drew on the Drive map (the fallback when the definition has no `labels.spec`).
  static const MapLabelSpec drive = MapLabelSpec(
    sizes: [(0, 12), (12, 13), (14, 14)],
    budget: [(9, 12), (11, 24), (12, 40), (13, 56), (14, 80)],
    maxWidthPx: 150,
    haloPx: 3,
    staleOpacity: 0.7,
    pillRadius: 8,
    pillAlpha: 0.88,
    holdMs: 300,
    fadeMs: 120,
    ink: (light: 0xFF1B1F24, dark: 0xFFF4F6F8),
    halo: (light: 0xFFFFFFFF, dark: 0xFF12161B),
    basemapTone: {'road': 'theme', 'relief': 'theme', 'plain': 'theme', 'topo': 'theme', 'satellite': 'dark'},
    pillOn: {'topo', 'satellite'},
    things: {
      'selected': LabelThing('selected', 0),
      'repeater': LabelThing('repeater', 11, importantFromZoom: 9),
      'room': LabelThing('room', 11, importantFromZoom: 9),
      'heard': LabelThing('heard', 10, text: 'name and SNR'),
      'companion': LabelThing('companion', 13),
      'sensor': LabelThing('sensor', 13),
      'unknown': LabelThing('unknown', 13),
      'observer': LabelThing('observer', 12),
      'phone': LabelThing('phone', 12),
      'estimated': LabelThing('estimated', 12, italic: true, opacity: 0.7),
      'plan': LabelThing('plan', 9),
    },
  );

  /// Font size at [zoom]: the last row whose fromZoom is <= zoom.
  double sizeAt(double zoom) {
    var px = sizes.first.$2;
    for (final (z, s) in sizes) {
      if (zoom >= z) px = s;
    }
    return px;
  }

  /// Most names drawn at [zoom] (0 below the first budget row).
  int budgetAt(double zoom) {
    var n = 0;
    for (final (z, m) in budget) {
      if (zoom >= z) n = m;
    }
    return n;
  }

  /// The zoom below which nothing is named (the first budget row).
  double get minZoom => budget.isEmpty ? 9 : budget.first.$1;

  LabelThing thing(String id) => things[id] ?? things['repeater'] ?? const LabelThing('repeater', 11);

  /// Does a name of [thingId] show at [zoom]? [important] = heard on this drive, on the shown path, relaying in Live.
  bool names(String thingId, double zoom, {bool important = false}) {
    final t = thing(thingId);
    final from = important ? (t.importantFromZoom ?? t.fromZoom) : t.fromZoom;
    return zoom >= from;
  }

  /// True when the basemap with id [basemapId] (`road`, `relief`, `plain`, `topo`, `satellite`) draws names on a pill.
  bool pillFor(String basemapId) => pillOn.contains(basemapId);

  /// Is the map under the names dark? `theme` follows [appDark]. Names follow the map that is showing, not the app theme.
  bool darkUnder(String basemapId, {required bool appDark}) => switch (basemapTone[basemapId]) {
    'dark' => true,
    'light' => false,
    _ => appDark,
  };

  int inkFor(bool dark) => dark ? ink.dark : ink.light;
  int haloFor(bool dark) => dark ? halo.dark : halo.light;

  static MapLabelSpec? fromJson(Map<String, dynamic> j) {
    final size = _maps(j['size']), budget = _maps(j['budget']);
    if (size.isEmpty || budget.isEmpty) return null;
    final tones = _map(j['tones']);
    int hex(Object? v, int f) {
      if (v is! String || !v.startsWith('#') || v.length != 7) return f;
      return 0xFF000000 | (int.tryParse(v.substring(1), radix: 16) ?? (f & 0xFFFFFF));
    }

    final light = _map(tones['light']), dark = _map(tones['dark']);
    final pill = _map(j['pill']);
    final hold = _map(j['hold']);
    final d = drive;
    return MapLabelSpec(
      sizes: [for (final s in size) (_d(s['fromZoom'], 0), _d(s['px'], 12))]..sort((a, b) => a.$1.compareTo(b.$1)),
      budget: [for (final b in budget) (_d(b['fromZoom'], 9), _i(b['max'], 12))]..sort((a, b) => a.$1.compareTo(b.$1)),
      maxWidthPx: _d(j['maxWidthPx'], d.maxWidthPx),
      haloPx: _d(j['haloPx'], d.haloPx),
      staleOpacity: _d(j['staleOpacity'], d.staleOpacity),
      pillRadius: _d(pill['radius'], d.pillRadius),
      pillAlpha: _d(pill['alpha'], d.pillAlpha),
      holdMs: _d(hold['holdMs'], d.holdMs),
      fadeMs: _d(hold['fadeMs'], d.fadeMs),
      ink: (light: hex(light['ink'], d.ink.light), dark: hex(dark['ink'], d.ink.dark)),
      halo: (light: hex(light['halo'], d.halo.light), dark: hex(dark['halo'], d.halo.dark)),
      basemapTone: {for (final e in _map(j['basemapTone']).entries) e.key: '${e.value}'},
      pillOn: {for (final e in (pill['on'] as List? ?? const [])) '$e'},
      things: {
        for (final t in _maps(j['things']))
          if (t['id'] is String)
            t['id'] as String: LabelThing(
              t['id'] as String,
              _d(t['fromZoom'], 11),
              importantFromZoom: t['importantFromZoom'] is num ? (t['importantFromZoom'] as num).toDouble() : null,
              text: t['text'] as String? ?? 'name',
              italic: t['italic'] == true,
              opacity: _d(t['opacity'], 1),
            ),
      },
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------- slice 3

/// One drawing instruction of a role's glyph (`mode` stroke or fill).
class SymbolGlyphPath {
  final String d;
  final bool fill;
  const SymbolGlyphPath(this.d, this.fill);
}

/// One role of the symbol set: its badge outline and glyph, 24 x 24.
class SymbolRole {
  final String id, name, label, badge;
  final List<SymbolGlyphPath> glyph;
  const SymbolRole(this.id, this.name, this.label, this.badge, this.glyph);
}

/// One freshness row: the ring and the opacity.
class SymbolFreshness {
  final String id, ring, label;
  final double opacity;
  const SymbolFreshness(this.id, this.ring, this.opacity, this.label);
}

/// One tint (colour-by option value): label and fill per theme.
class SymbolTint {
  final String id, label;
  final int light, dark;
  const SymbolTint(this.id, this.label, this.light, this.dark);
  int of(bool isDark) => isDark ? dark : light;
}

/// `symbols.set`: the ONE node symbol set (plan 4.3). Shape by role, ring by freshness, optional tint by a variable.
class NodeSymbolSet {
  final double sizePx, viewBox, strokePx, ringR, ringWidth;
  final List<double> ringDash;
  final ({int fill, int ink}) neutralLight, neutralDark;
  final int onTintLight, onTintDark;
  final List<SymbolRole> roles;
  final List<SymbolFreshness> freshness;

  /// `tints.status` / `tints.hash` / `tints.role`.
  final Map<String, List<SymbolTint>> tints;
  const NodeSymbolSet({
    required this.sizePx,
    required this.viewBox,
    required this.strokePx,
    required this.ringR,
    required this.ringWidth,
    required this.ringDash,
    required this.neutralLight,
    required this.neutralDark,
    required this.onTintLight,
    required this.onTintDark,
    required this.roles,
    required this.freshness,
    required this.tints,
  });

  SymbolRole? role(String id) => roles.where((r) => r.id == id).firstOrNull;
  SymbolFreshness? fresh(String id) => freshness.where((f) => f.id == id).firstOrNull;
  ({int fill, int ink}) neutral(bool dark) => dark ? neutralDark : neutralLight;
  int onTint(bool dark) => dark ? onTintDark : onTintLight;

  static NodeSymbolSet? fromJson(Map<String, dynamic> j) {
    final roles = _maps(j['roles']);
    if (roles.isEmpty) return null;
    int hex(Object? v) {
      if (v is! String || !v.startsWith('#')) return 0xFF808080;
      final h = v.substring(1);
      final n = int.tryParse(h, radix: 16) ?? 0x808080;
      return h.length == 8 ? ((n & 0xFF) << 24) | (n >> 8) : 0xFF000000 | n;
    }

    final neutral = _map(j['neutral']), nl = _map(neutral['light']), nd = _map(neutral['dark']);
    final onTint = _map(j['onTint']);
    final ring = _map(j['ring']);
    final tints = _map(j['tints']);
    return NodeSymbolSet(
      sizePx: _d(j['sizePx'], 24),
      viewBox: _d(j['viewBox'], 24),
      strokePx: _d(j['strokePx'], 1.7),
      ringR: _d(ring['r'], 11.1),
      ringWidth: _d(ring['widthPx'], 1.7),
      ringDash: [for (final x in (ring['dash'] as List? ?? const [3.4, 2.6])) (x as num).toDouble()],
      neutralLight: (fill: hex(nl['fill']), ink: hex(nl['ink'])),
      neutralDark: (fill: hex(nd['fill']), ink: hex(nd['ink'])),
      onTintLight: hex(onTint['light']),
      onTintDark: hex(onTint['dark']),
      roles: [
        for (final r in roles)
          if (r['id'] is String && r['badge'] is String)
            SymbolRole(r['id'] as String, r['name'] as String? ?? r['id'] as String, r['label'] as String? ?? '', r['badge'] as String, [
              for (final g in _maps(r['glyph'])) if (g['d'] is String) SymbolGlyphPath(g['d'] as String, g['mode'] == 'fill'),
            ]),
      ],
      freshness: [
        for (final f in _maps(j['freshness']))
          SymbolFreshness(f['id'] as String? ?? '', f['ring'] as String? ?? 'none', _d(f['opacity'], 1), f['label'] as String? ?? ''),
      ],
      tints: {
        for (final e in tints.entries)
          e.key: [
            for (final t in _maps(e.value))
              SymbolTint(t['id'] as String? ?? '', t['label'] as String? ?? '', hex(_map(t['fill'])['light']), hex(_map(t['fill'])['dark'])),
          ],
      },
    );
  }
}

/// `variables.colourBy`: what a person can tint the node symbols by.
class ColourByDef {
  final String urlKey, defaultId;
  final List<({String id, String label, bool available, String? note})> options;
  final Map<String, String> pageDefaults;
  const ColourByDef({required this.urlKey, required this.defaultId, required this.options, required this.pageDefaults});

  /// The ids a person can pick (an option the server marks `available: false` is left out).
  List<String> get pickable => [for (final o in options) if (o.available) o.id];

  static ColourByDef? fromJson(Map<String, dynamic> j) {
    final opts = _maps(j['options']);
    if (opts.isEmpty) return null;
    return ColourByDef(
      urlKey: j['urlKey'] as String? ?? 'cb',
      defaultId: j['default'] as String? ?? 'none',
      options: [
        for (final o in opts)
          if (o['id'] is String) (id: o['id'] as String, label: o['label'] as String? ?? o['id'] as String, available: o['available'] != false, note: o['note'] as String?),
      ],
      pageDefaults: {for (final e in _map(j['pageDefaults']).entries) e.key: '${e.value}'},
    );
  }
}

/// `packetTypes`: one colour list for Live, the feed, the packets table and the charts.
class PacketTypeColours {
  /// Packet type number -> (light, dark) ARGB.
  final Map<int, ({int light, int dark})> byType;
  final Map<int, String> names;
  final ({int light, int dark}) other;
  const PacketTypeColours(this.byType, this.names, this.other);

  ({int light, int dark}) of(int type) => byType[type] ?? other;

  static PacketTypeColours? fromJson(Map<String, dynamic> j) {
    final types = _maps(j['types']);
    if (types.isEmpty) return null;
    final o = _map(j['other']);
    final by = <int, ({int light, int dark})>{};
    final names = <int, String>{};
    for (final t in types) {
      final n = t['type'];
      if (n is! num || t['light'] is! String || t['dark'] is! String) continue;
      by[n.toInt()] = (light: parseHexColour(t['light'] as String), dark: parseHexColour(t['dark'] as String));
      names[n.toInt()] = t['name'] as String? ?? '${t['id']}';
    }
    if (by.isEmpty) return null;
    return PacketTypeColours(by, names, (
      light: o['light'] is String ? parseHexColour(o['light'] as String) : 0xFF6F7780,
      dark: o['dark'] is String ? parseHexColour(o['dark'] as String) : 0xFF8A929B,
    ));
  }
}

/// The version 2 readers. Every one is null (or the Drive numbers) when the definition does not carry the block.
extension MapDefinitionV2 on MapDefinition {
  /// The coverage summary ladder; null when the server did not send it (no summary picture, build 72 behaviour).
  CoverageLadder? get coverageLadder {
    if (!hasCapability(kSummaryCapability)) return null;
    final l = json['ladder'];
    return l is Map ? CoverageLadder.fromJson(l.cast<String, dynamic>()) : null;
  }

  /// `labels.spec`, else the Drive numbers.
  MapLabelSpec get labelSpec {
    final s = labels['spec'];
    return (s is Map ? MapLabelSpec.fromJson(s.cast<String, dynamic>()) : null) ?? MapLabelSpec.drive;
  }

  bool get hasLabelSpec => labels['spec'] is Map;

  NodeSymbolSet? get symbolSet {
    final s = symbol('set');
    return s.isEmpty ? null : NodeSymbolSet.fromJson(s);
  }

  ColourByDef? get colourBy {
    final v = json['variables'];
    final c = v is Map ? v['colourBy'] : null;
    return c is Map ? ColourByDef.fromJson(c.cast<String, dynamic>()) : null;
  }

  PacketTypeColours? get packetTypes {
    final p = json['packetTypes'];
    return p is Map ? PacketTypeColours.fromJson(p.cast<String, dynamic>()) : null;
  }
}
