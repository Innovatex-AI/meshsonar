// The offline basemap: downloaded PMTiles region packs drawn with vector_map_tiles inside the existing flutter_map.
// Fallback order: installed pack covering the map -> online OSM raster tiles (flutter_map's own cache) -> chart grid.
// NOTE: the app's map engine is flutter_map (not maplibre_gl); a MapLibre-style JSON is used only as the *theme* format
// the vector renderer understands. See meshsonar-infra/docs/tiles-offline-packs.md.
import 'dart:async';
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
import '../../platform/app_lifecycle_bridge.dart';
import '../../platform/network_monitor.dart';

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
    final Uint8List? b;
    try {
      b = await reader.tile(tile.z, tile.x, tile.y);
    } on PmtilesException catch (e) {
      // The pack was closed (deleted/updated) or is damaged: an empty tile, never a crash.
      throw ProviderException(message: e.message, retryable: Retryable.none);
    }
    if (b == null) {
      throw ProviderException(message: 'no tile ${tile.z}/${tile.x}/${tile.y} in pack', retryable: Retryable.none);
    }
    return b;
  }
}

/// Process-wide holder of the pack manager and the open pack readers. Lazy: nothing touches disk until first use.
class OfflineBasemap extends ChangeNotifier {
  OfflineBasemap._();
  static final OfflineBasemap _shared = OfflineBasemap._();

  /// Widget tests point the map at a basemap built with [forTest] (null = the shared one).
  @visibleForTesting
  static OfflineBasemap? debugInstance;
  static OfflineBasemap get instance => debugInstance ?? _shared;

  /// Tests inject a directory and client instead of path_provider / the network.
  @visibleForTesting
  static OfflineBasemap forTest() => OfflineBasemap._();

  OfflinePackManager? _manager;
  Future<OfflinePackManager>? _opening;
  final Map<String, PmtilesReader> _readers = {};
  final Map<String, int> _readerVersion = {};
  OfflinePackManager? get managerOrNull => _manager;

  Future<OfflinePackManager> manager({Directory? root, http.Client? client, NetworkMonitor? network}) =>
      _opening ??= _open(root, client, network);

  /// The network the download policy sees (connectivity_plus in the app, a fake in tests).
  NetworkMonitor get network => _network ??= ConnectivityNetworkMonitor();
  NetworkMonitor? _network;
  AppLifecycleBridge? _lifecycle;
  StreamSubscription<NetworkKind>? _netSub;

  Future<OfflinePackManager> _open(Directory? root, http.Client? client, NetworkMonitor? network) async {
    if (network != null) _network = network;
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
    // Downloads the user started resume by themselves: now (launch), on return to the foreground, and when the
    // network changes (Wi-Fi back). On cellular with Wi-Fi only on they wait; nothing runs in the background.
    _netSub = this.network.changes.listen((k) => m.onNetwork(k));
    _lifecycle = AppLifecycleBridge((fg) {
      if (fg) unawaited(this.network.current().then(m.resumePending));
    })..attach();
    unawaited(this.network.current().then(m.resumePending));
    return m;
  }

  @visibleForTesting
  Future<void> debugClose() async {
    _lifecycle?.detach();
    await _netSub?.cancel();
    for (final r in _readers.values) {
      await r.close();
    }
    _readers.clear();
    _manager?.dispose();
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

  /// The open reader for an installed pack code (null when not installed, not opened, or unreadable).
  PmtilesReader? readerFor(String? code) => code == null ? null : _readers[code];

  /// Which pack the map should draw for a view centred at lat/lon, given the one it draws now ([current]).
  /// Sticky: while the current pack still covers the centre it is kept (no flicker where packs overlap); otherwise
  /// the smallest installed, readable pack covering the centre; null = online tiles.
  String? choosePack(double lat, double lon, {String? current}) {
    final m = _manager;
    if (m == null) return null;
    final cur = current == null ? null : m.installed[current];
    if (cur != null && cur.covers(lat, lon) && _readers.containsKey(cur.code)) return cur.code;
    final ip = m.packCovering(lat, lon, where: (c) => _readers.containsKey(c));
    return ip?.code;
  }
}

/// Keeps the map's offline pack in step with the camera: call [update] with every camera centre; it says when the
/// layer has to change (the view moved into another pack, out of all packs, or the installed set changed).
class OfflinePackSelection {
  final OfflineBasemap basemap;
  OfflinePackSelection(this.basemap);

  String? _code;
  double? _lat, _lon;
  String? get code => _code;
  PmtilesReader? get reader => basemap.readerFor(_code);

  /// Returns true when the chosen pack changed.
  bool update(double lat, double lon) {
    _lat = lat;
    _lon = lon;
    final next = basemap.choosePack(lat, lon, current: _code);
    if (next == _code) return false;
    _code = next;
    return true;
  }

  /// Re-evaluates at the last centre (after a pack was installed, updated or deleted).
  bool refresh() => _lat == null ? false : update(_lat!, _lon!);
}



/// A flutter_map child layer drawing [reader]'s tiles. Build as a `children:` entry.
class OfflineBasemapLayer extends StatelessWidget {
  final PmtilesReader reader;
  const OfflineBasemapLayer({super.key, required this.reader});

  /// Widget tests replace the vector layer (it spins up isolates the test binding cancels).
  @visibleForTesting
  static Widget Function(PmtilesReader reader)? debugBuilder;

  @override
  Widget build(BuildContext context) {
    final debug = debugBuilder;
    if (debug != null) return debug(reader);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return VectorTileLayer(
      theme: vtr.ThemeReader().read(offlineMapStyle(dark: dark)),
      tileProviders: TileProviders({'openmaptiles': PmtilesVectorTileProvider(reader)}),
      layerMode: VectorTileLayerMode.raster,
      maximumZoom: 19,
    );
  }
}

/// Version of [offlineMapStyle]. Bump when layer ids or source-layer use change; the manifest's `style_version`
/// (designed in docs, not yet published) is compared against it before a hosted style is preferred.
const offlineStyleVersion = 2;

/// MapLibre-style JSON (OpenMapTiles schema, planetiler) in the app's chart palette, light and dark.
/// Labels need NO glyph PBFs here: vector_tile_renderer lays text out with Flutter's own TextPainter, using the
/// `text-font` name as a Flutter font family (Barlow / BarlowSemiCondensed are bundled; a name containing "Italic"
/// would fall back to the system font, so water names differ by colour, not slant). Glyph + sprite hosting is only needed for
/// MapLibre (web) parity; see docs. Halos are wide on purpose: the map is read at a glance in a moving car.
Map<String, dynamic> offlineMapStyle({required bool dark}) {
  final c = dark
      ? {
          'bg': '#0e1517',
          'water': '#17414f',
          'park': '#142a22',
          'land': '#182124',
          'bld': '#1f2b2f',
          'road': '#3a4a50',
          'major': '#5b727a',
          'motorway': '#7a8f96',
          'bound': '#6a7d84',
          'text': '#e3ecee',
          'textMuted': '#a9bbc0',
          'waterText': '#7fb4c6',
          'halo': '#0e1517',
        }
      : {
          'bg': '#eef1ee',
          'water': '#b9d6e2',
          'park': '#d3e5cf',
          'land': '#e4e8e2',
          'bld': '#d6d9d3',
          'road': '#ffffff',
          'major': '#f6d9a0',
          'motorway': '#eebc6a',
          'bound': '#8a9a96',
          'text': '#1f2a2d',
          'textMuted': '#4d5b5f',
          'waterText': '#2f6e86',
          'halo': '#ffffff',
        };
  const src = 'openmaptiles';
  Map<String, dynamic> fill(String id, String layer, String color, [List<dynamic>? filter]) => {
    'id': id,
    'type': 'fill',
    'source': src,
    'source-layer': layer,
    'filter': ?filter,
    'paint': {'fill-color': color},
  };
  Map<String, dynamic> widthStops(num w) => {
    'base': 1.4,
    'stops': [
      [8, w * 0.4],
      [14, w],
      [18, w * 4],
    ],
  };
  Map<String, dynamic> line(String id, String color, List<dynamic> filter, num w, {num? minzoom}) => {
    'id': id,
    'type': 'line',
    'source': src,
    'source-layer': 'transportation',
    'minzoom': ?minzoom,
    'filter': filter,
    'layout': {'line-cap': 'round', 'line-join': 'round'},
    'paint': {'line-color': color, 'line-width': widthStops(w)},
  };
  Map<String, dynamic> label(
    String id,
    String layer,
    List<dynamic>? filter, {
    required List<List<num>> size,
    required String color,
    num? minzoom,
    num? maxzoom,
    bool alongLine = false,
    bool bold = false,
    String field = '{name}',
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
      'text-font': [bold ? 'BarlowSemiCondensed' : 'Barlow'],
      'text-size': {'stops': size},
      'text-max-width': 8,
      if (alongLine) 'symbol-placement': 'line',
      if (alongLine) 'text-rotation-alignment': 'map',
    },
    'paint': {'text-color': color, 'text-halo-color': c['halo'], 'text-halo-width': 2},
  };
  return {
    'version': 8,
    // `id` + `metadata.version` are vector_map_tiles' cache key (memory AND the on-disk raster tile cache). Without
    // them both palettes were "default/none": the first palette rendered was reused for the other (seen on the
    // simulator: dark mode showed light tiles), and a style change would never reach already-cached tiles.
    'id': 'meshsonar-offline-${dark ? 'dark' : 'light'}',
    'name': 'meshsonar-offline',
    'metadata': {'version': '$offlineStyleVersion', 'meshsonar:style_version': offlineStyleVersion},
    'sources': {
      src: {'type': 'vector', 'minzoom': 0, 'maxzoom': 14},
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
      {
        'id': 'waterway',
        'type': 'line',
        'source': src,
        'source-layer': 'waterway',
        'filter': ['in', 'class', 'river', 'canal', 'stream'],
        'paint': {
          'line-color': c['water'],
          'line-width': {
            'base': 1.3,
            'stops': [
              [8, 0.8],
              [14, 2.5],
              [18, 8],
            ],
          },
        },
      },
      fill('building', 'building', c['bld']!),
      line('road-minor', c['road']!, ['in', 'class', 'minor', 'service', 'tertiary', 'track', 'path'], 1.2),
      line('road-major', c['major']!, ['in', 'class', 'trunk', 'primary', 'secondary'], 2.2),
      line('road-motorway', c['motorway']!, ['==', 'class', 'motorway'], 2.8),
      {
        'id': 'boundary',
        'type': 'line',
        'source': src,
        'source-layer': 'boundary',
        'filter': ['<=', 'admin_level', 4],
        'paint': {
          'line-color': c['bound'],
          'line-width': 1,
          'line-dasharray': [3, 2],
        },
      },
      // Labels, least important first (later layers win label collisions in vector_tile_renderer).
      label(
        'label-water',
        'water_name',
        null,
        size: [
          [10, 11],
          [14, 13],
        ],
        color: c['waterText']!,
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
        color: c['waterText']!,
        minzoom: 12,
        alongLine: true,
      ),
      label(
        'label-road-minor',
        'transportation_name',
        ['in', 'class', 'minor', 'tertiary'],
        size: [
          [14, 11],
          [17, 13],
        ],
        color: c['textMuted']!,
        minzoom: 14,
        alongLine: true,
      ),
      label(
        'label-road-major',
        'transportation_name',
        ['in', 'class', 'trunk', 'primary', 'secondary'],
        size: [
          [12, 11],
          [16, 14],
        ],
        color: c['text']!,
        minzoom: 12,
        alongLine: true,
      ),
      label(
        'label-motorway',
        'transportation_name',
        ['==', 'class', 'motorway'],
        size: [
          [10, 11],
          [16, 14],
        ],
        color: c['text']!,
        minzoom: 10,
        alongLine: true,
        field: '{ref}',
      ),
      label(
        'label-neighbourhood',
        'place',
        ['in', 'class', 'suburb', 'neighbourhood', 'quarter', 'hamlet'],
        size: [
          [12, 11],
          [16, 14],
        ],
        color: c['textMuted']!,
        minzoom: 12,
      ),
      label(
        'label-village',
        'place',
        ['==', 'class', 'village'],
        size: [
          [10, 11],
          [15, 15],
        ],
        color: c['text']!,
        minzoom: 10,
      ),
      label(
        'label-town',
        'place',
        ['==', 'class', 'town'],
        size: [
          [8, 12],
          [14, 17],
        ],
        color: c['text']!,
        minzoom: 8,
        bold: true,
      ),
      label(
        'label-city',
        'place',
        ['==', 'class', 'city'],
        size: [
          [5, 12],
          [10, 17],
          [14, 21],
        ],
        color: c['text']!,
        minzoom: 5,
        maxzoom: 15,
        bold: true,
      ),
    ],
  };
}
