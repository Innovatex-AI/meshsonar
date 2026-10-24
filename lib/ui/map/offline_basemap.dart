// The offline basemap: downloaded PMTiles region packs drawn with vector_map_tiles inside the existing flutter_map.
// Fallback order: installed pack covering the map -> online OSM raster tiles (flutter_map's own cache) -> chart grid.
// NOTE: the app's map engine is flutter_map (not maplibre_gl); a MapLibre-style JSON is used only as the *theme* format
// the vector renderer understands. See meshsonar-infra/docs/tiles-offline-packs.md.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../core/offline_packs.dart';
import '../../core/pmtiles_reader.dart';

/// Serves tiles from an open PMTiles file to the vector renderer.
class PmtilesVectorTileProvider extends VectorTileProvider {
  final PmtilesReader reader;
  PmtilesVectorTileProvider(this.reader);

  @override
  int get maximumZoom => reader.header.maxZoom;
  @override
  int get minimumZoom => reader.header.minZoom;
  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final b = await reader.tile(tile.z, tile.x, tile.y);
    if (b == null) {
      throw ProviderException(message: 'no tile ${tile.z}/${tile.x}/${tile.y} in pack', retryable: Retryable.none);
    }
    return b;
  }
}

/// Process-wide holder of the pack manager and the open pack readers. Lazy: nothing touches disk until first use.
class OfflineBasemap extends ChangeNotifier {
  OfflineBasemap._();
  static final OfflineBasemap instance = OfflineBasemap._();

  /// Tests inject a directory and client instead of path_provider / the network.
  @visibleForTesting
  static OfflineBasemap forTest() => OfflineBasemap._();

  OfflinePackManager? _manager;
  Future<OfflinePackManager>? _opening;
  final Map<String, PmtilesReader> _readers = {};
  final Map<String, int> _readerVersion = {};
  OfflinePackManager? get managerOrNull => _manager;

  Future<OfflinePackManager> manager({Directory? root, http.Client? client}) => _opening ??= _open(root, client);

  Future<OfflinePackManager> _open(Directory? root, http.Client? client) async {
    var dir = root;
    if (dir == null) {
      Directory base;
      try {
        base = await getApplicationSupportDirectory();
      } catch (_) {
        base = await getApplicationDocumentsDirectory();
      }
      dir = Directory(p.join(base.path, 'meshsonar', 'offline_packs'));
    }
    final m = OfflinePackManager(root: dir, client: client ?? http.Client());
    await m.load();
    m.changes.listen((_) => _sync(m));
    _manager = m;
    await _sync(m);
    return m;
  }

  /// Opens readers for installed packs and closes those that were deleted or replaced.
  Future<void> _sync(OfflinePackManager m) async {
    var changed = false;
    for (final code in _readers.keys.toList()) {
      final ip = m.installed[code];
      if (ip == null || _readerVersion[code] != ip.version) {
        await _readers.remove(code)?.close();
        _readerVersion.remove(code);
        changed = true;
      }
    }
    for (final ip in m.installed.values) {
      if (_readers.containsKey(ip.code)) continue;
      try {
        _readers[ip.code] = await PmtilesReader.open(m.packFile(ip.code));
        _readerVersion[ip.code] = ip.version;
        changed = true;
      } catch (_) {
        // corrupt or unsupported file: the map silently stays on online tiles; the packs screen still lets the user delete it
      }
    }
    if (changed) notifyListeners();
  }

  /// Kicks off the lazy open (safe to call from initState; failures just mean "no offline pack").
  void ensureOpen() {
    manager().then((_) {}, onError: (Object _) {});
  }

  PmtilesReader? readerCovering(double lat, double lon) {
    final m = _manager;
    if (m == null) return null;
    final ip = m.packCovering(lat, lon);
    return ip == null ? null : _readers[ip.code];
  }
}

/// A flutter_map child layer drawing [reader]'s tiles. Build as a `children:` entry.
class OfflineBasemapLayer extends StatelessWidget {
  final PmtilesReader reader;
  const OfflineBasemapLayer({super.key, required this.reader});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return VectorTileLayer(
      theme: vtr.ThemeReader().read(offlineMapStyle(dark: dark)),
      tileProviders: TileProviders({'openmaptiles': PmtilesVectorTileProvider(reader)}),
      layerMode: VectorTileLayerMode.raster,
      maximumZoom: 19,
    );
  }
}

/// MapLibre-style JSON (OpenMapTiles schema) in the app's chart palette. The website style is a separate follow-up.
/// No text layers: glyph/sprite hosting is a
/// separate work package, so offline maps show geometry only (roads, water, land use, buildings, boundaries).
Map<String, dynamic> offlineMapStyle({required bool dark}) {
  final c = dark
      ? {
          'bg': '#0e1517',
          'water': '#12303a',
          'park': '#142a22',
          'land': '#182124',
          'bld': '#1f2b2f',
          'road': '#3a4a50',
          'major': '#5b727a',
          'bound': '#6a7d84',
        }
      : {
          'bg': '#eef1ee',
          'water': '#b9d6e2',
          'park': '#d3e5cf',
          'land': '#e4e8e2',
          'bld': '#d6d9d3',
          'road': '#ffffff',
          'major': '#f6d9a0',
          'bound': '#8a9a96',
        };
  Map<String, dynamic> fill(String id, String layer, String color, [List<dynamic>? filter]) => {
    'id': id,
    'type': 'fill',
    'source': 'openmaptiles',
    'source-layer': layer,
    'filter': ?filter,
    'paint': {'fill-color': color},
  };
  Map<String, dynamic> line(String id, String color, List<dynamic> filter, num w) => {
    'id': id,
    'type': 'line',
    'source': 'openmaptiles',
    'source-layer': 'transportation',
    'filter': filter,
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {
      'line-color': color,
      'line-width': {
        'base': 1.4,
        'stops': [
          [8, w * 0.4],
          [14, w],
          [18, w * 4],
        ],
      },
    },
  };
  return {
    'version': 8,
    'name': 'meshsonar-offline',
    'sources': {
      'openmaptiles': {'type': 'vector', 'minzoom': 0, 'maxzoom': 14},
    },
    'layers': [
      {
        'id': 'background',
        'type': 'background',
        'paint': {'background-color': c['bg']},
      },
      fill('landcover', 'landcover', c['park']!, ['in', 'class', 'grass', 'wood', 'farmland']),
      fill('landuse', 'landuse', c['land']!),
      fill('park', 'park', c['park']!),
      fill('water', 'water', c['water']!),
      fill('building', 'building', c['bld']!),
      line('road-minor', c['road']!, ['in', 'class', 'minor', 'service', 'tertiary', 'track', 'path'], 1.2),
      line('road-major', c['major']!, ['in', 'class', 'motorway', 'trunk', 'primary', 'secondary'], 2.2),
      {
        'id': 'boundary',
        'type': 'line',
        'source': 'openmaptiles',
        'source-layer': 'boundary',
        'filter': ['<=', 'admin_level', 4],
        'paint': {
          'line-color': c['bound'],
          'line-width': 1,
          'line-dasharray': [3, 2],
        },
      },
    ],
  };
}
