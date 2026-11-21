// The online road / dark basemap inside any flutter_map: our Protomaps vector tiles (api.meshsonar.com/basemap), OpenFreeMap
// as the fallback, drawn on the phone by vector_map_tiles in raster mode with the website's styles (core/basemap.dart).
// Every map in the app (the Drive map and the small maps) uses this layer, and [BasemapCredit] / the AttributionLine
// show the credit of the source actually drawn. Tile loads go through [MeshTileProvider]: the same disk cache, request
// gate, circuit breaker and health counters as before; a tile an installed offline pack draws is never requested.
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

import '../../core/basemap.dart';
import '../../core/power_profile.dart';
import 'basemap_cache.dart';
import 'tile_source.dart';

/// Whether a drive map shows coverage on a plain background instead of the basemap right now: a drive is running and the power
/// profile asks for it (PowerProfile.current.simpleBasemap: Saver, or Custom with "Simple basemap" on). Build 70, battery plan.
/// The renderer is not swapped; the basemap layers are simply left out (CoverageMap.plainBasemap).
bool simpleBasemapNow({required bool driving}) => driving && PowerProfile.current.simpleBasemap;

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

/// Shared themes (parsed once). The renderer keys its tile caches (memory and disk) and its isolate registries on the theme's
/// id and version: every style has its own (core/basemap.dart, [basemapStyleIdentity]); two styles must never share one.
final Map<(BasemapSource, bool, BasemapLook), vtr.Theme> _themes = {};
vtr.Theme basemapTheme(BasemapSource source, {required bool dark, BasemapLook look = BasemapLook.road}) =>
    _themes.putIfAbsent((source, dark, look), () => vtr.ThemeReader().read(basemapStyle(source, dark: dark, look: look)));

/// The renderer's knobs, sized for the screen (build 72: "slow" on an 11-inch iPad, which shows about 3.5 times the tiles of
/// a phone). vector_map_tiles 9.0.0-beta.13 renders each vector tile to a picture on the device; its defaults (4 workers, 20
/// parsed tiles and 10 MB of tile bytes in memory) are sized for a phone. The tile size is not an option in raster mode.
@immutable
class BasemapTuning {
  /// Worker isolates that parse and prepare tiles (the package's shared pool: the first map built sets it for the app run).
  final int concurrency;

  /// Parsed tiles and raw tile bytes kept in memory.
  final int tileDataCache;
  final int tileBytesCache;
  const BasemapTuning({required this.concurrency, required this.tileDataCache, required this.tileBytesCache});

  /// The package's own defaults (a phone).
  static const BasemapTuning packageDefaults = BasemapTuning(concurrency: 4, tileDataCache: 20, tileBytesCache: 10 * 1024 * 1024);

  /// False = [packageDefaults] and no previous-style picture kept (the simulator comparison run).
  static bool enabled = true;

  /// 256 pt tiles that a [size] screen shows at once (one extra row and column: the map is rarely tile-aligned).
  static int tilesOnScreen(Size size) => ((size.width / 256).ceil() + 1) * ((size.height / 256).ceil() + 1);

  /// For a [size] screen on a device with [processors] cores.
  static BasemapTuning forScreen(Size size, {int? processors}) {
    if (!enabled) return packageDefaults;
    final n = tilesOnScreen(size);
    final cores = processors ?? (() {
      try {
        return Platform.numberOfProcessors;
      } catch (_) {
        return 4;
      }
    })();
    return BasemapTuning(
      // Two cores stay free for the UI and raster threads; never fewer workers than the package default.
      concurrency: n <= 20 ? 4 : math.max(4, math.min(8, cores - 2)),
      // Two screens of parsed tiles (a pan or a style switch re-uses them), within reason for memory.
      tileDataCache: (n * 2).clamp(20, 64),
      tileBytesCache: n <= 20 ? 10 * 1024 * 1024 : 24 * 1024 * 1024,
    );
  }
}

class BasemapLayer extends StatefulWidget {
  /// Forces the dark (true) or light (false) look; null follows the app theme.
  final bool? dark;

  /// The loader to use (the Drive map passes its own, which skips tiles its offline pack draws). Null = a shared one.
  final MeshTileProvider? tiles;

  /// An event re-asks for every tile (the network came back, a pack was installed or removed).
  final Stream<void>? reset;

  /// Road / Light / Dark ([BasemapLook.road]), the Topo palette, or only the town and road names over Satellite imagery
  /// ([BasemapLook.labels]: drawn only while OUR tiles are the source, since OpenFreeMap has no label-only look).
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

  // No blank flash on a style switch: the previous style's layer stays UNDER the new one until the new tiles are drawn (the
  // renderer has nothing pending), 6 s at most. Not for the names-only look over Satellite, which is transparent.
  Widget? _current, _previous;
  Timer? _previousTimer;
  DateTime? _previousSince;

  void _keepPrevious(Widget was) {
    _previous = was;
    _previousSince = DateTime.now();
    _previousTimer?.cancel();
    _previousTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final age = DateTime.now().difference(_previousSince!);
      final drawn = age > const Duration(milliseconds: 750) && PaintingBinding.instance.imageCache.pendingImageCount == 0;
      if (!mounted || drawn || age > const Duration(seconds: 6)) _dropPrevious();
    });
  }

  void _dropPrevious() {
    _previousTimer?.cancel();
    _previousTimer = null;
    if (_previous != null && mounted) setState(() => _previous = null);
    _previous = null;
  }

  BasemapHealth get _health => BasemapHealth.instance;

  @override
  void initState() {
    super.initState();
    _sub = _health.changes.listen((_) {
      if (mounted) setState(() {});
    });
    if (BasemapLayer.enabled) unawaited(_health.check());
    if (BasemapLayer.enabled) BasemapRenderCache.purgeOldOnce();
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
    _previousTimer?.cancel();
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
    // Satellite names come from our tiles only (inside the extract, while our server answers); never from OpenFreeMap.
    if (widget.look == BasemapLook.labels && source != BasemapSource.ours) {
      _current = null;
      return const SizedBox.shrink();
    }
    final debug = BasemapLayer.debugBuilder;
    if (debug != null) {
      BasemapLayer.debugLook = widget.look;
      return debug(source, dark);
    }
    if (!BasemapLayer.enabled || source == BasemapSource.none) {
      _current = null;
      return const SizedBox.shrink();
    }
    final tuning = BasemapTuning.forScreen(MediaQuery.sizeOf(context));
    final key = ValueKey('basemap-${source.name}-${dark ? 'dark' : 'light'}-${widget.look.name}-$_generation');
    final was = _current;
    final layer = VectorTileLayer(
      key: key,
      theme: basemapTheme(source, dark: dark, look: widget.look),
      tileProviders: _providersFor(source, widget.tiles ?? BasemapLayer.sharedTiles),
      layerMode: VectorTileLayerMode.raster,
      maximumZoom: 19,
      concurrency: tuning.concurrency,
      memoryTileDataCacheMaxSize: tuning.tileDataCache,
      memoryTileCacheMaxSize: tuning.tileBytesCache,
    );
    if (was != null && was.key != key && BasemapTuning.enabled && widget.look != BasemapLook.labels) {
      // Kept after this frame: the timer's setState must not run during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _keepPrevious(was));
      });
    }
    _current = layer;
    final under = _previous;
    if (under == null || under.key == key) return layer;
    return Stack(fit: StackFit.expand, children: [under, layer]);
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
