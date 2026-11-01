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
import '../../core/offline_style.dart';
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

  /// Forces the dark (true) or light (false) look; null follows the app theme.
  final bool? dark;
  const OfflineBasemapLayer({super.key, required this.reader, this.dark});

  /// Widget tests replace the vector layer (it spins up isolates the test binding cancels).
  @visibleForTesting
  static Widget Function(PmtilesReader reader)? debugBuilder;

  @override
  Widget build(BuildContext context) {
    final debug = debugBuilder;
    if (debug != null) return debug(reader);
    final dark = this.dark ?? Theme.of(context).brightness == Brightness.dark;
    return VectorTileLayer(
      theme: vtr.ThemeReader().read(offlineMapStyle(dark: dark)),
      tileProviders: TileProviders({'openmaptiles': PmtilesVectorTileProvider(reader)}),
      layerMode: VectorTileLayerMode.raster,
      maximumZoom: 19,
    );
  }
}

/// The app's offline style: OSM Carto colours through the same matrix as the online tiles (see core/offline_style.dart),
/// labels drawn with Flutter text from the bundled Barlow fonts (no glyph files needed in the app).
Map<String, dynamic> offlineMapStyle({required bool dark}) => offlineStyle(dark: dark);
