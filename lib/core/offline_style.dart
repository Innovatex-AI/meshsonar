// The offline map style (MapLibre style JSON, OpenMapTiles schema) built to look like the ONLINE map: OpenStreetMap
// Carto's colours and road hierarchy, passed through the same colour matrix the app applies to OSM raster tiles
// (ui/theme.dart `_lightTiles` / `_darkTiles`). So a region that moves from online tiles to its downloaded pack keeps
// the grey/paper look in light and the inverted chart look in dark. Pure Dart: also used by
// tool/make_web_styles.dart to write the MapLibre (web) styles uploaded next to the packs.
import 'dart:math' as math;

/// Bump when layer ids, colours or source-layer use change: it is part of the renderer's tile cache key (old cached
/// tiles are never reused) and is published as `style_version` in the manifest for web/MapLibre parity.
const offlineStyleVersion = 4;

/// Copies of the app's OSM tile matrices (ui/theme.dart). test/ui/offline_style_parity_test.dart fails if they drift.
const osmTintLight = <double>[
  0.2446, 0.8227, 0.0831, 0, -51.33, //
  0.2131, 0.7168, 0.0724, 0, -10.56, //
  0.1964, 0.6607, 0.0667, 0, 10.44, //
  0, 0, 0, 1, 0,
];
const osmTintDark = <double>[
  -0.2412, -0.8114, -0.0819, 0, 302.29, //
  -0.2948, -0.9917, -0.1001, 0, 380.57, //
  -0.3156, -1.0618, -0.1072, 0, 416.57, //
  0, 0, 0, 1, 0,
];

/// `#rrggbb` after the 4x5 colour matrix [m] (Flutter ColorFilter.matrix semantics: offsets in 0..255), clamped.
String tintHex(String hex, List<double> m) {
  final v = int.parse(hex.substring(1), radix: 16);
  final r = (v >> 16) & 0xff, g = (v >> 8) & 0xff, b = v & 0xff;
  int ch(int row) => (m[row * 5] * r + m[row * 5 + 1] * g + m[row * 5 + 2] * b + m[row * 5 + 4]).round().clamp(0, 255);
  String h(int x) => x.toRadixString(16).padLeft(2, '0');
  return '#${h(ch(0))}${h(ch(1))}${h(ch(2))}';
}

/// OpenStreetMap Carto colours (openstreetmap-carto, CC0), by our role names.
const cartoColors = <String, String>{
  'land': '#f2efe9',
  'water': '#aad3df',
  'residential': '#e0dfdf',
  'commercial': '#f2dad9',
  'retail': '#ffd6d1',
  'industrial': '#ebdbe8',
  'institutional': '#ffffe5',
  'cemetery': '#aacbaf',
  'park': '#c8facc',
  'pitch': '#aae0cb',
  'grass': '#cdebb0',
  'wood': '#add19e',
  'farmland': '#eef0d5',
  'wetland': '#d6e8d0',
  'sand': '#f5e9c6',
  'rock': '#eee5dc',
  'ice': '#ddecec',
  'aeroway': '#bbbbcc',
  'building': '#d9d0c9',
  'building-outline': '#c4b6ab',
  'motorway': '#e892a2',
  'motorway-casing': '#dc2a67',
  'trunk': '#f9b29c',
  'trunk-casing': '#c84e2f',
  'primary': '#fcd6a4',
  'primary-casing': '#a06b00',
  'secondary': '#f7fabf',
  'secondary-casing': '#707d05',
  'tertiary': '#ffffff',
  'tertiary-casing': '#8f8f8f',
  'minor': '#ffffff',
  'minor-casing': '#bbbbbb',
  'path': '#fa8072',
  'track': '#996600',
  'rail': '#707070',
  'boundary': '#8d618b',
  'text': '#222222',
  'place-text': '#000000',
  'water-text': '#4d80b3',
  'halo': '#ffffff',
};

/// Which renderer the style is for. [app]: vector_tile_renderer in the app (text-font = the system font family [appLabelFont],
/// source without a URL). [web]: MapLibre GL (text-font = the glyph stacks hosted on tiles.meshsonar.com, a
/// `pmtiles://` source and `glyphs` URL).
enum OfflineStyleTarget { app, web }

/// The Flutter family the app target asks for (spike S1, D14): vector_tile_renderer passes the first `text-font` entry
/// straight to a Flutter `TextStyle.fontFamily`, and `CupertinoSystemText` is Flutter's alias for the platform system
/// font (SF Pro Text on iOS/macOS; an unknown family falls back to the default font elsewhere). So offline-pack labels are
/// drawn in SF Pro with no font file bundled. Weight is not carried by the renderer, so bold labels use the same family.
const appLabelFont = 'CupertinoSystemText';

/// Glyph stacks published under `fonts/` in the tiles bucket (built from the Barlow OFL files in assets/fonts). This
/// is a documented Barlow exception (web only; the app never loads these).
const webFontRegular = 'Barlow-Regular', webFontMedium = 'Barlow-Medium', webFontBold = 'BarlowSemiCondensed-SemiBold';

Map<String, dynamic> offlineStyle({
  required bool dark,
  OfflineStyleTarget target = OfflineStyleTarget.app,
  String? pmtilesUrl,
  String glyphsUrl = 'https://tiles.meshsonar.com/fonts/{fontstack}/{range}.pbf',
}) {
  final m = dark ? osmTintDark : osmTintLight;
  String c(String role) => tintHex(cartoColors[role]!, m);
  final web = target == OfflineStyleTarget.web;
  List<String> font(String weight) => switch (weight) {
    'bold' => [web ? webFontBold : appLabelFont],
    'medium' => [web ? webFontMedium : appLabelFont],
    _ => [web ? webFontRegular : appLabelFont],
  };
  const src = 'openmaptiles';

  Map<String, dynamic> stops(List<List<num>> s, {num base = 1.4}) => {'base': base, 'stops': s};
  Map<String, dynamic> fill(
    String id,
    String layer,
    String color, {
    List<dynamic>? filter,
    String? outline,
    num? minzoom,
  }) => {
    'id': id,
    'type': 'fill',
    'source': src,
    'source-layer': layer,
    'minzoom': ?minzoom,
    'filter': ?filter,
    'paint': {'fill-color': color, 'fill-outline-color': ?outline},
  };
  Map<String, dynamic> line(
    String id,
    String layer,
    String color,
    List<List<num>> width, {
    List<dynamic>? filter,
    num? minzoom,
    List<num>? dash,
    num? opacity,
  }) => {
    'id': id,
    'type': 'line',
    'source': src,
    'source-layer': layer,
    'minzoom': ?minzoom,
    'filter': ?filter,
    'layout': {'line-cap': dash == null ? 'round' : 'butt', 'line-join': 'round'},
    'paint': {'line-color': color, 'line-width': stops(width), 'line-dasharray': ?dash, 'line-opacity': ?opacity},
  };
  // Road widths (px at 256-px tiles) after OSM Carto's progression; casings are the fill plus a rim.
  const roadWidths = <String, List<List<num>>>{
    'motorway': [
      [5, 0.5],
      [8, 1.2],
      [10, 2],
      [12, 3.5],
      [14, 7],
      [16, 12],
      [18, 28],
    ],
    'trunk': [
      [6, 0.5],
      [8, 1.1],
      [10, 1.8],
      [12, 3.2],
      [14, 6.5],
      [16, 11],
      [18, 26],
    ],
    'primary': [
      [7, 0.5],
      [9, 1],
      [11, 1.8],
      [13, 4],
      [15, 8.5],
      [18, 24],
    ],
    'secondary': [
      [9, 0.5],
      [11, 1.4],
      [13, 3.5],
      [15, 8],
      [18, 22],
    ],
    'tertiary': [
      [10, 0.5],
      [12, 1.2],
      [14, 4],
      [16, 8],
      [18, 20],
    ],
    'minor': [
      [12, 0.4],
      [13, 1.2],
      [14, 2.6],
      [16, 6],
      [18, 16],
    ],
    'service': [
      [14, 0.8],
      [16, 2.5],
      [18, 7],
    ],
  };
  List<List<num>> casing(List<List<num>> w, num rim) => [
    for (final s in w) [s[0], s[1] + (s[0] >= 12 ? rim : rim * 0.4)],
  ];
  // Roads: OpenMapTiles `class` values per Carto tier. Bridges/tunnels are not split out (Carto draws tunnels dashed;
  // at car-glance scale the plain line reads better).
  final tiers = <(String, List<String>, String, num)>[
    ('minor', ['minor'], 'minor', 12),
    ('service', ['service'], 'minor', 14),
    ('tertiary', ['tertiary'], 'tertiary', 10),
    ('secondary', ['secondary'], 'secondary', 9),
    ('primary', ['primary'], 'primary', 7),
    ('trunk', ['trunk'], 'trunk', 6),
    ('motorway', ['motorway'], 'motorway', 5),
  ];
  final roadCasings = [
    for (final (tier, classes, colorRole, minz) in tiers)
      line(
        'road-$tier-casing',
        'transportation',
        c('${colorRole == 'minor' ? 'minor' : colorRole}-casing'),
        casing(roadWidths[tier]!, tier == 'minor' || tier == 'service' ? 1.0 : 1.6),
        filter: ['in', 'class', ...classes],
        minzoom: tier == 'minor' || tier == 'service' || tier == 'tertiary' ? 12 : minz,
      ),
  ];
  final roadFills = [
    for (final (tier, classes, colorRole, minz) in tiers)
      line(
        'road-$tier',
        'transportation',
        c(colorRole),
        roadWidths[tier]!,
        filter: ['in', 'class', ...classes],
        minzoom: minz,
      ),
  ];

  Map<String, dynamic> label(
    String id,
    String layer,
    List<dynamic>? filter, {
    required List<List<num>> size,
    required String color,
    num? minzoom,
    num? maxzoom,
    bool alongLine = false,
    String weight = 'regular',
    String field = '{name}',
    num maxWidth = 8,
  }) => {
    'id': id,
    'type': 'symbol',
    'source': src,
    'source-layer': layer,
    'minzoom': ?minzoom,
    'maxzoom': ?maxzoom,
    'filter': ?filter,
    'layout': {
      'text-field': field,
      'text-font': font(weight),
      'text-size': {'stops': size},
      'text-max-width': maxWidth,
      if (alongLine) 'symbol-placement': 'line',
      if (alongLine) 'text-rotation-alignment': 'map',
    },
    'paint': {'text-color': color, 'text-halo-color': c('halo'), 'text-halo-width': 2},
  };

  // Labels, MOST important first. vector_tile_renderer places symbols in layer order and the first to claim space
  // wins; MapLibre places the top-most layer first, so the web style gets the list reversed (same priorities).
  final labels = <Map<String, dynamic>>[
    label(
      'label-city',
      'place',
      ['==', 'class', 'city'],
      size: [
        [5, 12],
        [10, 17],
        [14, 21],
      ],
      color: c('place-text'),
      minzoom: 5,
      maxzoom: 15,
      weight: 'bold',
    ),
    label(
      'label-town',
      'place',
      ['==', 'class', 'town'],
      size: [
        [8, 12],
        [14, 17],
      ],
      color: c('place-text'),
      minzoom: 8,
      weight: 'bold',
    ),
    label(
      'label-village',
      'place',
      ['==', 'class', 'village'],
      size: [
        [10, 11],
        [15, 15],
      ],
      color: c('place-text'),
      minzoom: 10,
    ),
    label(
      'label-motorway',
      'transportation_name',
      [
        'all',
        ['==', 'class', 'motorway'],
        ['in', 'network', 'us-interstate', 'us-highway', 'us-state'],
      ],
      size: [
        [10, 10.5],
        [16, 13],
      ],
      color: c('text'),
      minzoom: 11,
      alongLine: true,
      field: '{ref}',
      weight: 'medium',
    ),
    label(
      'label-road-major',
      'transportation_name',
      ['in', 'class', 'trunk', 'primary', 'secondary'],
      size: [
        [12, 11],
        [16, 14],
      ],
      color: c('text'),
      minzoom: 12,
      alongLine: true,
      weight: 'medium',
    ),
    label(
      'label-neighbourhood',
      'place',
      ['in', 'class', 'suburb', 'neighbourhood', 'quarter', 'hamlet'],
      size: [
        [12, 11],
        [16, 14],
      ],
      color: c('text'),
      minzoom: 12,
    ),
    label(
      'label-water',
      'water_name',
      null,
      size: [
        [10, 11],
        [14, 13],
      ],
      color: c('water-text'),
      minzoom: 10,
    ),
    label(
      'label-river',
      'waterway',
      ['==', 'class', 'river'],
      size: [
        [12, 11],
        [16, 13],
      ],
      color: c('water-text'),
      minzoom: 12,
      alongLine: true,
    ),
    label(
      'label-road-minor',
      'transportation_name',
      ['in', 'class', 'minor', 'tertiary'],
      size: [
        [14, 10.5],
        [17, 13],
      ],
      color: c('text'),
      minzoom: 14,
      alongLine: true,
    ),
  ];

  return {
    'version': 8,
    // `id` + `metadata.version` are vector_map_tiles' tile-cache key (memory and disk): per palette, per version.
    'id': 'meshsonar-offline-${dark ? 'dark' : 'light'}',
    'name': 'MeshSonar offline (${dark ? 'dark' : 'light'})',
    'metadata': {'version': '$offlineStyleVersion', 'meshsonar:style_version': offlineStyleVersion},
    if (web) 'glyphs': glyphsUrl,
    'sources': {
      src: {
        'type': 'vector',
        if (web) 'url': 'pmtiles://${pmtilesUrl ?? 'https://tiles.meshsonar.com/CMH-v261024.pmtiles'}',
        if (!web) 'minzoom': 0,
        if (!web) 'maxzoom': 14,
        if (web) 'attribution': '© OpenStreetMap contributors',
      },
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': c('land')},
      },
      // Land cover and land use (Carto fills).
      fill('landcover-wood', 'landcover', c('wood'), filter: ['==', 'class', 'wood']),
      fill('landcover-grass', 'landcover', c('grass'), filter: ['==', 'class', 'grass']),
      fill('landcover-farmland', 'landcover', c('farmland'), filter: ['==', 'class', 'farmland']),
      fill('landcover-wetland', 'landcover', c('wetland'), filter: ['==', 'class', 'wetland']),
      fill('landcover-sand', 'landcover', c('sand'), filter: ['==', 'class', 'sand']),
      fill('landcover-rock', 'landcover', c('rock'), filter: ['==', 'class', 'rock']),
      fill('landcover-ice', 'landcover', c('ice'), filter: ['==', 'class', 'ice']),
      fill(
        'landuse-residential',
        'landuse',
        c('residential'),
        filter: ['in', 'class', 'residential', 'suburb', 'neighbourhood'],
      ),
      fill('landuse-commercial', 'landuse', c('commercial'), filter: ['==', 'class', 'commercial']),
      fill('landuse-retail', 'landuse', c('retail'), filter: ['==', 'class', 'retail']),
      fill(
        'landuse-industrial',
        'landuse',
        c('industrial'),
        filter: ['in', 'class', 'industrial', 'railway', 'garages', 'quarry'],
      ),
      fill(
        'landuse-institutional',
        'landuse',
        c('institutional'),
        filter: ['in', 'class', 'school', 'university', 'college', 'hospital', 'kindergarten'],
      ),
      fill('landuse-cemetery', 'landuse', c('cemetery'), filter: ['==', 'class', 'cemetery']),
      fill('landuse-pitch', 'landuse', c('pitch'), filter: ['in', 'class', 'pitch', 'stadium', 'playground']),
      fill('park', 'park', c('park')),
      fill('water', 'water', c('water')),
      line(
        'waterway-river',
        'waterway',
        c('water'),
        [
          [8, 0.6],
          [12, 1.6],
          [14, 3],
          [18, 10],
        ],
        filter: ['in', 'class', 'river', 'canal'],
      ),
      line(
        'waterway-stream',
        'waterway',
        c('water'),
        [
          [12, 0.5],
          [14, 1.2],
          [18, 4],
        ],
        filter: ['in', 'class', 'stream', 'ditch', 'drain'],
        minzoom: 12,
      ),
      fill('aeroway-area', 'aeroway', c('aeroway'), filter: ['in', 'class', 'runway', 'taxiway', 'apron'], minzoom: 11),
      line(
        'aeroway-runway',
        'aeroway',
        c('aeroway'),
        [
          [11, 2],
          [14, 10],
          [18, 60],
        ],
        filter: ['==', 'class', 'runway'],
        minzoom: 11,
      ),
      fill('building', 'building', c('building'), outline: c('building-outline'), minzoom: 13),
      line(
        'path',
        'transportation',
        c('path'),
        [
          [14, 0.6],
          [16, 1.2],
          [18, 2],
        ],
        filter: ['in', 'class', 'path'],
        minzoom: 14,
        dash: [2, 1.5],
      ),
      line(
        'track',
        'transportation',
        c('track'),
        [
          [13, 0.6],
          [16, 1.2],
          [18, 2],
        ],
        filter: ['==', 'class', 'track'],
        minzoom: 13,
        dash: [3, 1.5],
      ),
      ...roadCasings,
      ...roadFills,
      line(
        'rail',
        'transportation',
        c('rail'),
        [
          [10, 0.6],
          [14, 1.5],
          [18, 3],
        ],
        filter: ['in', 'class', 'rail', 'transit'],
        minzoom: 10,
      ),
      line(
        'boundary-state',
        'boundary',
        c('boundary'),
        [
          [3, 0.6],
          [8, 1.2],
          [12, 2],
        ],
        filter: [
          'all',
          ['<=', 'admin_level', 4],
          ['!=', 'maritime', 1],
        ],
        dash: [4, 2],
        opacity: 0.7,
      ),
      ...(web ? labels.reversed : labels),
    ],
  };
}

/// Relative luminance difference helper for tests (0..1).
double lumaOf(String hex) {
  final v = int.parse(hex.substring(1), radix: 16);
  double lin(int x) {
    final s = x / 255;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * lin((v >> 16) & 0xff) + 0.7152 * lin((v >> 8) & 0xff) + 0.0722 * lin(v & 0xff);
}
