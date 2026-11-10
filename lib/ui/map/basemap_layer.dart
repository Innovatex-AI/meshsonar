// The online road / dark basemap inside any flutter_map: our Protomaps vector tiles (api.meshsonar.com/basemap), OpenFreeMap
// as the fallback, drawn on the phone by vector_map_tiles in raster mode with the website's styles (core/basemap.dart).
// Every map in the app (the Drive map and the small maps) uses this layer, and [BasemapCredit] / the AttributionLine
// show the credit of the source actually drawn. Tile loads go through [MeshTileProvider]: the same disk cache, request
// gate, circuit breaker and health counters as before; a tile an installed offline pack draws is never requested.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../core/basemap.dart';
import 'tile_source.dart';

/// Serves our (or OpenFreeMap's) vector tiles to the renderer through a [MeshTileProvider].
class NetworkBasemapTileProvider extends VectorTileProvider {
  final BasemapSource source;
  final String Function() urlTemplate;
  final MeshTileProvider tiles;
  final BasemapHealth health;
  NetworkBasemapTileProvider({required this.source, required this.urlTemplate, required this.tiles, required this.health});

  static final Future<void> _never = Completer<void>().future;

  @override
  int get maximumZoom => source == BasemapSource.openFreeMap ? OpenFreeMapBasemap.maxZoom : OurBasemap.maxZoom;
  @override
  int get minimumZoom => 0;
  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  String urlFor(TileIdentity t) =>
      urlTemplate().replaceAll('{z}', '${t.z}').replaceAll('{x}', '${t.x}').replaceAll('{y}', '${t.y}');

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final skip = tiles.shouldSkip?.call(tile.z, tile.x, tile.y) ?? false;
    final (bytes, outcome) = await tiles.loadWithOutcome(urlFor(tile), skip: skip, cancel: _never);
    if (outcome == TileOutcome.failed) health.tileFailed(source);
    if (outcome == TileOutcome.networkOk || outcome == TileOutcome.notModified) health.tileOk(source);
    if (identical(bytes, TileProvider.transparentImage)) {
      throw ProviderException(message: 'no basemap tile ${tile.z}/${tile.x}/${tile.y}', retryable: Retryable.none);
    }
    return bytes;
  }
}

/// The source a map at [camera] draws (ours inside the extract while our server answers, else OpenFreeMap).
BasemapSource basemapSourceAt(MapCamera camera, {BasemapHealth? health}) {
  final b = camera.visibleBounds;
  final inside = viewInsideOurBasemap(west: b.west, south: b.south, east: b.east, north: b.north, zoom: camera.zoom);
  return (health ?? BasemapHealth.instance).sourceFor(inside: inside);
}

/// Shared themes (parsed once; the renderer's caches key on the theme id).
final Map<(BasemapSource, bool), vtr.Theme> _themes = {};
vtr.Theme basemapTheme(BasemapSource source, {required bool dark}) =>
    _themes.putIfAbsent((source, dark), () => vtr.ThemeReader().read(basemapStyle(source, dark: dark)));

class BasemapLayer extends StatefulWidget {
  /// Forces the dark (true) or light (false) look; null follows the app theme.
  final bool? dark;

  /// The loader to use (the Drive map passes its own, which skips tiles its offline pack draws). Null = a shared one.
  final MeshTileProvider? tiles;

  /// An event re-asks for every tile (the network came back, a pack was installed or removed).
  final Stream<void>? reset;
  const BasemapLayer({super.key, this.dark, this.tiles, this.reset});

  /// Widget tests replace the vector layer (it spins up isolates the test binding cancels). Gets the source drawn.
  @visibleForTesting
  static Widget Function(BasemapSource source, bool dark)? debugBuilder;

  /// False under `flutter test` (no network, no renderer isolates): the layer draws nothing unless [debugBuilder] is set.
  static bool enabled = () {
    try {
      return !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return true;
    }
  }();

  static MeshTileProvider? _shared;
  static MeshTileProvider get sharedTiles => _shared ??= MeshTileProvider();

  @override
  State<BasemapLayer> createState() => _BasemapLayerState();
}

class _BasemapLayerState extends State<BasemapLayer> {
  StreamSubscription<void>? _sub;
  StreamSubscription<void>? _resetSub;
  int _generation = 0;
  final Map<BasemapSource, TileProviders> _providers = {};
  MeshTileProvider? _forProviders;

  BasemapHealth get _health => BasemapHealth.instance;

  @override
  void initState() {
    super.initState();
    _sub = _health.changes.listen((_) {
      if (mounted) setState(() {});
    });
    if (BasemapLayer.enabled) unawaited(_health.check());
    _listenReset();
  }

  void _listenReset() {
    _resetSub?.cancel();
    _resetSub = widget.reset?.listen((_) {
      if (mounted) setState(() => _generation++); // a new layer key: tiles that failed are asked for again
    });
  }

  @override
  void didUpdateWidget(BasemapLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.reset, widget.reset)) _listenReset();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _resetSub?.cancel();
    super.dispose();
  }

  TileProviders _providersFor(BasemapSource source, MeshTileProvider tiles) {
    if (!identical(_forProviders, tiles)) {
      _providers.clear();
      _forProviders = tiles;
    }
    return _providers.putIfAbsent(source, () {
      final p = NetworkBasemapTileProvider(
        source: source,
        urlTemplate: source == BasemapSource.openFreeMap ? () => _health.openFreeMapTileUrl : () => OurBasemap.tileUrl,
        tiles: tiles,
        health: _health,
      );
      return TileProviders({source.styleSource: p});
    });
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    final source = basemapSourceAt(camera, health: _health);
    if (source == BasemapSource.openFreeMap && BasemapLayer.enabled) unawaited(_health.resolveOpenFreeMap());
    final dark = widget.dark ?? Theme.of(context).brightness == Brightness.dark;
    final debug = BasemapLayer.debugBuilder;
    if (debug != null) return debug(source, dark);
    if (!BasemapLayer.enabled || source == BasemapSource.none) return const SizedBox.shrink();
    return VectorTileLayer(
      key: ValueKey('basemap-${source.name}-${dark ? 'dark' : 'light'}-$_generation'),
      theme: basemapTheme(source, dark: dark),
      tileProviders: _providersFor(source, widget.tiles ?? BasemapLayer.sharedTiles),
      layerMode: VectorTileLayerMode.raster,
      maximumZoom: 19,
    );
  }
}

/// The base-map credit for the small maps: a pill in the bottom-right corner with the credit of the source drawn.
/// Put it last in a FlutterMap's children. Key 'mini-map-credit'.
class BasemapCredit extends StatelessWidget {
  const BasemapCredit({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final text = basemapSourceAt(MapCamera.of(context)).attribution;
    return Align(
      alignment: Alignment.bottomRight,
      child: IgnorePointer(
        child: Container(
          key: const Key('mini-map-credit'),
          margin: const EdgeInsets.all(3),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(color: t.colorScheme.surface.withValues(alpha: 0.78), borderRadius: BorderRadius.circular(3)),
          child: Text(text, style: (t.textTheme.labelSmall ?? const TextStyle()).copyWith(fontSize: 10, height: 1.2, color: t.colorScheme.onSurface)),
        ),
      ),
    );
  }
}

/// Rebuilds [builder] with the basemap source a map shows, for widgets that sit outside the FlutterMap (the Drive map's
/// AttributionLine). Follows the camera ([controller]) and the server health; rebuilds only when the source changes.
class BasemapSourceBuilder extends StatefulWidget {
  final MapController controller;
  final Widget Function(BuildContext context, BasemapSource source) builder;
  const BasemapSourceBuilder({super.key, required this.controller, required this.builder});

  @override
  State<BasemapSourceBuilder> createState() => _BasemapSourceBuilderState();
}

class _BasemapSourceBuilderState extends State<BasemapSourceBuilder> {
  StreamSubscription<void>? _health;
  StreamSubscription<MapEvent>? _events;
  BasemapSource _source = BasemapSource.ours;

  @override
  void initState() {
    super.initState();
    _health = BasemapHealth.instance.changes.listen((_) => _update());
    _events = widget.controller.mapEventStream.listen((_) => _update());
  }

  @override
  void didUpdateWidget(BasemapSourceBuilder old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      _events?.cancel();
      _events = widget.controller.mapEventStream.listen((_) => _update());
    }
  }

  void _update() {
    if (!mounted) return;
    BasemapSource next;
    try {
      next = basemapSourceAt(widget.controller.camera);
    } catch (_) {
      return; // the map is not ready yet
    }
    if (next != _source) setState(() => _source = next);
  }

  @override
  void dispose() {
    _health?.cancel();
    _events?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _source);
}
