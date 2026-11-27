// The online road / dark basemap inside any flutter_map: our Protomaps vector tiles (api.meshsonar.com/basemap), OpenFreeMap
// as the fallback, drawn on the phone by vector_map_tiles in raster mode with the website's styles (core/basemap.dart).
// Every map in the app (the Drive map and the small maps) uses this layer, and [BasemapCredit] / the AttributionLine
// show the credit of the source actually drawn. Tile loads go through [MeshTileProvider]: the same disk cache, request
// gate, circuit breaker and health counters as before.
import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../core/basemap.dart';
import 'basemap_cache.dart';
import 'tile_source.dart';

/// Serves our (or OpenFreeMap's) vector tiles to the renderer through a [MeshTileProvider].
class NetworkBasemapTileProvider extends VectorTileProvider {
  final BasemapSource source;
  final String Function() urlTemplate;
  final MeshTileProvider tiles;
  final BasemapHealth health;
  NetworkBasemapTileProvider({required this.source, required this.urlTemplate, required this.tiles, required this.health, this.retryDelays = defaultRetryDelays});

  static final Future<void> _never = Completer<void>().future;

  @override
  int get maximumZoom => source == BasemapSource.openFreeMap ? OpenFreeMapBasemap.maxZoom : OurBasemap.maxZoom;
  @override
  int get minimumZoom => 0;
  @override
  TileOffset get tileOffset => TileOffset.DEFAULT;

  String urlFor(TileIdentity t) =>
      urlTemplate().replaceAll('{z}', '${t.z}').replaceAll('{x}', '${t.x}').replaceAll('{y}', '${t.y}');

  /// A failed vector tile is asked for twice more (after 1 s and 3 s) before it is given up for now. Shorter than the raster
  /// tiles' waits: the renderer draws a few tiles at a time, and a tile that waits holds one of its places.
  static const List<Duration> defaultRetryDelays = [Duration(seconds: 1), Duration(seconds: 3)];
  final List<Duration> retryDelays;

  @override
  Future<Uint8List> provide(TileIdentity tile) async {
    final (bytes, outcome) = await tiles.loadWithRetry(urlFor(tile), cancel: _never, delays: retryDelays);
    // Only a server that really failed us counts towards the OpenFreeMap fallback: not a phone with no network (the gate is
    // shut, nothing was asked), where falling back would only change the credit over a map that cannot load either.
    if (outcome == TileOutcome.failed && !tiles.gate.isOpen) health.tileFailed(source);
    if (outcome == TileOutcome.networkOk || outcome == TileOutcome.notModified) health.tileOk(source);
    if (outcome == TileOutcome.failed || outcome == TileOutcome.offlineEmpty) {
      // Thrown, so nothing is kept for this tile: the renderer caches no bytes and no picture, and the map asks again when
      // the tile next comes into view or the network comes back (BasemapLayer re-asks on TileFetchGate.recoveries).
      throw ProviderException(message: 'no basemap tile ${tile.z}/${tile.x}/${tile.y} (${outcome.name})', retryable: Retryable.retry);
    }
    if (identical(bytes, TileProvider.transparentImage)) {
      // The server has no tile there (404): the renderer draws an empty tile (the style's background).
      throw ProviderException(message: 'no basemap tile ${tile.z}/${tile.x}/${tile.y}', retryable: Retryable.none, statusCode: 404);
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

/// The background a style paints under its tiles: what the map shows where a tile is not (yet) drawn. Null for a names-only
/// look ([BasemapLook.isLabelsOnly]). Build 72: the map's own background was the app theme's, so a Dark map with tiles missing on a light iPad was a pale
/// sheet that looked like another basemap.
Color? basemapBackgroundColor(BasemapSource source, {required bool dark, BasemapLook look = BasemapLook.road}) {
  for (final l in basemapStyle(source, dark: dark, look: look)['layers'] as List) {
    if (l is Map && l['type'] == 'background') return parseStyleColor((l['paint'] as Map?)?['background-color']);
  }
  return null;
}

/// `#RRGGBB` or `rgb(r,g,b)` from a style (the two forms the generator writes for a background); null for anything else.
Color? parseStyleColor(Object? v) {
  if (v is! String) return null;
  final hex = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(v);
  if (hex != null) return Color(0xFF000000 | int.parse(hex.group(1)!, radix: 16));
  final rgb = RegExp(r'^rgb\((\d+),\s*(\d+),\s*(\d+)\)$').firstMatch(v);
  if (rgb != null) return Color.fromARGB(255, int.parse(rgb.group(1)!), int.parse(rgb.group(2)!), int.parse(rgb.group(3)!));
  return null;
}

/// Shared themes (parsed once). The renderer keys its tile caches (memory and disk) and its isolate registries on the theme's
/// id and version: every style has its own (core/basemap.dart, [basemapStyleIdentity]); two styles must never share one.
final Map<(BasemapSource, bool, BasemapLook), vtr.Theme> _themes = {};
vtr.Theme basemapTheme(BasemapSource source, {required bool dark, BasemapLook look = BasemapLook.road}) =>
    _themes.putIfAbsent((source, dark, look), () => vtr.ThemeReader().read(basemapStyle(source, dark: dark, look: look)));

/// Sizes the tile request queue for the screen (build 72: tiles that stayed blank on an 11-inch iPad).
///
/// Measured on the iPad Pro 11-inch simulator before deciding what else to tune: with the package's own renderer settings
/// (vector_map_tiles 9.0.0-beta.13: 4 workers, 20 parsed tiles in memory; raster mode has no tile-size option) a style
/// switch settled in 0.4 to 1.9 s and a one-screen pan in 1.0 s, with never more than about 1 % of the map bare. More workers
/// and bigger caches, and keeping the previous style's layer under the new one, were tried and measured no better
/// (0.5 to 6 s, noisier), so the renderer keeps its defaults and a style switch simply replaces the layer.
abstract final class BasemapTuning {
  /// False = the phone-sized queue of builds up to 71 (the simulator comparison run).
  static bool enabled = true;

  /// 256 pt tiles that a [size] screen shows at once (one extra row and column: the map is rarely tile-aligned).
  static int tilesOnScreen(Size size) => ((size.width / 256).ceil() + 1) * ((size.height / 256).ceil() + 1);

  /// Tile requests one [size] screen can have waiting at once: every tile in view plus the one-tile pan buffer around it, for
  /// the three tile layers Satellite draws (two imagery sources and our names), twice over so a pan or zoom does not drop
  /// what is still in view. The gate's phone default (48) is less than ONE iPad screen of one layer (56): the requests beyond
  /// it were dropped and those tiles stayed blank until they were scrolled away and back.
  static int requestsFor(Size size) => ((size.width / 256).ceil() + 3) * ((size.height / 256).ceil() + 3) * 3 * 2;

  /// Requests in flight at once for a [size] screen (one host, HTTP/2).
  static int requestConcurrencyFor(Size size) => tilesOnScreen(size) <= 20 ? 6 : 10;
}

class BasemapLayer extends StatefulWidget {
  /// Forces the dark (true) or light (false) look; null follows the app theme.
  final bool? dark;

  /// The loader to use (the Drive map passes its own). Null = a shared one.
  final MeshTileProvider? tiles;

  /// An event re-asks for every tile (the network came back, a pack was installed or removed).
  final Stream<void>? reset;

  /// Road / Light / Dark ([BasemapLook.road]), the Topo palette, the data-first map drawn under coverage, a map without its
  /// names, or only the names ([BasemapLook.isLabelsOnly]: drawn only while OUR tiles are the source, since OpenFreeMap has no
  /// names-only look; on the fallback the base layer draws OpenFreeMap's whole map, names included).
  final BasemapLook look;
  const BasemapLayer({super.key, this.dark, this.tiles, this.reset, this.look = BasemapLook.road});

  /// Widget tests replace the vector layer (it spins up isolates the test binding cancels). Gets the source drawn (and the look
  /// through [debugLook]).
  @visibleForTesting
  static Widget Function(BasemapSource source, bool dark)? debugBuilder;

  /// The look the last build asked for (tests).
  @visibleForTesting
  static BasemapLook? debugLook;

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

  // The network came back after failures: ask again for the tiles that failed (a new layer key; drawn tiles come straight
  // from the renderer's caches). A map that hands in its own [BasemapLayer.reset] does this itself.
  TileFetchGate? _watched;
  final TileReask _reask = TileReask();
  Timer? _reaskTimer;

  void _watchGate() {
    final g = widget.reset != null ? null : (widget.tiles ?? BasemapLayer.sharedTiles).gate;
    if (identical(g, _watched)) return;
    _watched?.recoveries.removeListener(_onRecovered);
    _watched = g?..recoveries.addListener(_onRecovered);
  }

  /// Before the tiles are asked again: Flutter's image cache keeps a tile image that FAILED (its stream reported an error)
  /// as a live, pending entry under the tile's key, and hands that same failed stream to the next widget that asks for the
  /// key. A new layer alone would therefore get the old error back and fetch nothing (seen on the simulator: 2 tiles loaded
  /// after the network came back, the rest stayed blank). The renderer's key type is private, so the failed entries cannot
  /// be evicted one by one: the image cache is emptied. Drawn tiles come back from the renderer's disk cache.
  void _forgetFailedTiles() {
    final ic = PaintingBinding.instance.imageCache;
    ic.clear();
    ic.clearLiveImages();
  }

  void _onRecovered() {
    if (!mounted || _reaskTimer != null) return;
    final wait = _reask.waitAt(DateTime.now());
    _reaskTimer = Timer(wait, () {
      _reaskTimer = null;
      if (!mounted) return;
      _reask.done(DateTime.now());
      _forgetFailedTiles();
      setState(() => _generation++);
    });
  }

  @override
  void initState() {
    super.initState();
    _sub = _health.changes.listen((_) {
      if (mounted) setState(() {});
    });
    if (BasemapLayer.enabled) unawaited(_health.check());
    if (BasemapLayer.enabled) BasemapRenderCache.purgeOldOnce();
    if (BasemapLayer.enabled) _watchGate();
    _listenReset();
  }

  void _listenReset() {
    _resetSub?.cancel();
    _resetSub = widget.reset?.listen((_) {
      if (!mounted) return;
      _forgetFailedTiles();
      setState(() => _generation++); // a new layer key: tiles that failed are asked for again
    });
  }

  @override
  void didUpdateWidget(BasemapLayer old) {
    super.didUpdateWidget(old);
    if (!identical(old.reset, widget.reset)) _listenReset();
    if (BasemapLayer.enabled) _watchGate();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _resetSub?.cancel();
    _reaskTimer?.cancel();
    _watched?.recoveries.removeListener(_onRecovered);
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
    // A names-only pass (over Satellite imagery, or above coverage) comes from our tiles only (inside the extract, while our
    // server answers); never from OpenFreeMap, whose one style already carries its names in the base layer.
    if (widget.look.isLabelsOnly && source != BasemapSource.ours) return const SizedBox.shrink();
    final debug = BasemapLayer.debugBuilder;
    if (debug != null) {
      BasemapLayer.debugLook = widget.look;
      return debug(source, dark);
    }
    if (!BasemapLayer.enabled || source == BasemapSource.none) return const SizedBox.shrink();
    if (BasemapTuning.enabled) {
      final screen = MediaQuery.sizeOf(context);
      (widget.tiles ?? BasemapLayer.sharedTiles).gate.ensureRoom(waiting: BasemapTuning.requestsFor(screen), concurrent: BasemapTuning.requestConcurrencyFor(screen));
    }
    return VectorTileLayer(
      key: ValueKey('basemap-${source.name}-${dark ? 'dark' : 'light'}-${widget.look.name}-$_generation'),
      theme: basemapTheme(source, dark: dark, look: widget.look),
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
