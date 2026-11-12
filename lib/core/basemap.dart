// The app's road / dark basemap: our own Protomaps vector tiles, OpenFreeMap as the keyless fallback (plan
// unified-map-system-plan-2026-11-08.md §2.3, M2). Same tiles, same styles and same fallback rules as the website
// (meshcore-insights src/components/tools/map-style.ts). Pure Dart.
//
// Why vector, drawn on the phone: the app's map engine is flutter_map, which draws raster tiles natively and vector tiles
// through vector_map_tiles (already used for the offline packs since WP13). Neither our tile server nor OpenFreeMap serves
// raster tiles, and a raster render farm would be a new server to run; vector_map_tiles renders our .bin tiles to
// images on the phone (raster mode, so every overlay keeps working as before) with labels as Flutter text in SF Pro.
// So no glyph files are needed in the app and the server's Noto glyphs are only for the website (decision M2, HANDOFF).
//
// Where the tiles are: https://api.meshsonar.com/basemap/t/<archive>/{z}/{x}/{y}.bin (meshsonar-infra stack/basemap).
// Fallback (automatic): the health probe `/basemap/t/<archive>.json` fails (4 s, at most once a minute for the whole app);
// [tileErrorsToFallback] tile errors in a row mid-session; or the view leaves the extract (back to ours when it returns).
// No map at all (the chart grid only) when OpenFreeMap also fails. OpenStreetMap's community server is never used
// (test/lint/no_osm_tile_server_test.dart).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'basemap_styles.g.dart';

/// Our basemap host and the current North America extract.
class OurBasemap {
  static const origin = 'https://api.meshsonar.com/basemap';

  /// Archive name = build date; a new extract is a new name (and a new URL, so no edge cache is ever stale).
  /// Keep equal to the website's `BASEMAP.archive`.
  static const archive = 'na-20261108';

  /// [west, south, east, north] of the extract.
  static const bounds = <double>[-170, 7, -50, 84];
  static const maxZoom = 14;
  static const tileUrl = '$origin/t/$archive/{z}/{x}/{y}.bin';
  static const tileJsonUrl = '$origin/t/$archive.json';
  static const attribution = 'Protomaps © OpenStreetMap contributors';
}

/// OpenFreeMap (keyless, OpenMapTiles schema). Its tile URL carries a weekly build name, so it is read from the TileJSON;
/// [defaultTileUrl] is used until that answer arrives.
class OpenFreeMapBasemap {
  static const tileJsonUrl = 'https://tiles.openfreemap.org/planet';
  static const defaultTileUrl = 'https://tiles.openfreemap.org/planet/20261101_080013_pt/{z}/{x}/{y}.pbf';
  static const maxZoom = 14;
  static const attribution = 'OpenFreeMap © OpenStreetMap contributors';
}

/// Where the basemap is drawn from.
enum BasemapSource {
  /// Our tiles (api.meshsonar.com/basemap).
  ours,

  /// OpenFreeMap, the fallback.
  openFreeMap,

  /// Neither answers: only the chart grid.
  none,
}

extension BasemapSourceX on BasemapSource {
  /// The source-id the style's layers read ('protomaps' or 'openmaptiles').
  String get styleSource => this == BasemapSource.openFreeMap ? 'openmaptiles' : 'protomaps';

  /// The credit line for this source (always on the map).
  String get attribution => switch (this) {
    BasemapSource.openFreeMap => OpenFreeMapBasemap.attribution,
    _ => OurBasemap.attribution,
  };
}

/// Which of our Protomaps looks a vector layer draws (M3): the Road / Light / Dark map, the Topo palette (the Map Definition's
/// `basemaps[topo].topo` overrides laid over Protomaps' light / dark flavour, baked by tool/basemap/make_basemap_styles.mjs), or
/// only the town and road names (drawn over Satellite imagery inside our extract, black flavour).
enum BasemapLook { road, topo, labels }

/// The style JSON (vector_tile_renderer subset, generated from the website's styles) for a source, theme and [look]. OpenFreeMap
/// has one look (its Positron / Dark): Topo falls back to it, and the labels look has no OpenFreeMap equivalent (never asked).
Map<String, dynamic> basemapStyle(BasemapSource source, {required bool dark, BasemapLook look = BasemapLook.road}) {
  final json = switch ((source, dark, look)) {
    (BasemapSource.openFreeMap, false, _) => openfreemapLightStyleJson,
    (BasemapSource.openFreeMap, true, _) => openfreemapDarkStyleJson,
    (_, _, BasemapLook.labels) => protomapsLabelsStyleJson,
    (_, false, BasemapLook.topo) => protomapsTopoLightStyleJson,
    (_, true, BasemapLook.topo) => protomapsTopoDarkStyleJson,
    (_, false, _) => protomapsLightStyleJson,
    (_, true, _) => protomapsDarkStyleJson,
  };
  return _parsed.putIfAbsent(json, () => jsonDecode(json) as Map<String, dynamic>);
}

final Map<String, Map<String, dynamic>> _parsed = {};

/// True when the view lies inside our extract (website `viewInsideBasemap`, same rule).
bool viewInsideOurBasemap({required double west, required double south, required double east, required double north, required double zoom}) {
  final b = OurBasemap.bounds;
  final w = b[0], s = b[1], e = b[2], n = b[3];
  if (zoom <= 3) return true;
  final cx = (west + east) / 2, cy = (south + north) / 2;
  if (cx < w || cx > e || cy < s || cy > n) return false;
  if (zoom <= 5) return true;
  return west >= w - 1 && east <= e + 1 && south >= s - 1 && north <= n + 1;
}

/// The app-wide health of both tile servers. One probe of ours per [probeEvery] (website: one per page per minute),
/// [probeTimeout] budget; [tileErrorsToFallback] tile errors in a row mark a server down until the next probe.
class BasemapHealth {
  static const probeEvery = Duration(minutes: 1);
  static const probeTimeout = Duration(seconds: 4);
  static const tileErrorsToFallback = 4;

  static BasemapHealth instance = BasemapHealth();

  final http.Client Function() _client;
  DateTime Function() clock;
  BasemapHealth({http.Client Function()? client, DateTime Function()? clock}) : _client = client ?? http.Client.new, clock = clock ?? DateTime.now;

  bool? _oursUp; // null = not probed yet (treated as up: the website also starts on ours)
  DateTime? _probedAt;
  Future<bool>? _probe;
  int _oursErrors = 0, _ofmErrors = 0;
  bool _ofmDown = false;
  DateTime? _ofmDownAt;
  String _ofmTileUrl = OpenFreeMapBasemap.defaultTileUrl;
  bool _ofmTileJsonAsked = false;
  final _changes = StreamController<void>.broadcast();

  /// Fires when the chosen source may have changed.
  Stream<void> get changes => _changes.stream;

  /// OpenFreeMap's current tile URL template.
  String get openFreeMapTileUrl => _ofmTileUrl;

  bool get oursUp => _oursUp ?? true;
  bool get openFreeMapUp {
    final at = _ofmDownAt;
    if (_ofmDown && at != null && clock().difference(at) >= probeEvery) _ofmDown = false; // try it again after a minute
    return !_ofmDown;
  }

  /// Probes our server unless a probe ran in the last [probeEvery]. Never throws.
  Future<bool> check() {
    final at = _probedAt;
    final p = _probe;
    if (p != null && at != null && clock().difference(at) < probeEvery) return p;
    _probedAt = clock();
    http.Client? c;
    Future<bool> ask() async {
      try {
        c = _client();
        final r = await c!.get(Uri.parse(OurBasemap.tileJsonUrl)).timeout(probeTimeout);
        return r.statusCode == 200;
      } catch (_) {
        return false;
      } finally {
        c?.close();
      }
    }

    final f = ask().then((ok) {
          final was = oursUp;
          _oursUp = ok;
          if (ok) _oursErrors = 0;
          if (was != ok) _changes.add(null);
          return ok;
        });
    _probe = f;
    return f;
  }

  /// Reads OpenFreeMap's TileJSON once per run (only when the fallback is first needed). Never throws.
  Future<void> resolveOpenFreeMap() async {
    if (_ofmTileJsonAsked) return;
    _ofmTileJsonAsked = true;
    http.Client? c;
    try {
      c = _client();
      final r = await c.get(Uri.parse(OpenFreeMapBasemap.tileJsonUrl)).timeout(const Duration(seconds: 6));
      if (r.statusCode != 200) return;
      final tiles = (jsonDecode(r.body) as Map<String, dynamic>)['tiles'];
      final url = tiles is List && tiles.isNotEmpty ? tiles.first : null;
      if (url is String && url.startsWith('https://tiles.openfreemap.org/') && url.contains('{z}')) {
        if (url != _ofmTileUrl) {
          _ofmTileUrl = url;
          _changes.add(null);
        }
      }
    } catch (_) {
      // keep the default URL
    } finally {
      c?.close();
    }
  }

  /// A tile came back from [source].
  void tileOk(BasemapSource source) {
    if (source == BasemapSource.ours) {
      _oursErrors = 0;
    } else if (source == BasemapSource.openFreeMap) {
      _ofmErrors = 0;
    }
  }

  /// A tile request to [source] failed (network or HTTP error; a 204 empty tile is not an error).
  void tileFailed(BasemapSource source) {
    if (source == BasemapSource.ours) {
      if (++_oursErrors >= tileErrorsToFallback && oursUp) {
        _oursUp = false;
        _probedAt = clock(); // the next probe in a minute may bring it back
        _probe = Future.value(false);
        _changes.add(null);
      }
    } else if (source == BasemapSource.openFreeMap) {
      if (++_ofmErrors >= tileErrorsToFallback && !_ofmDown) {
        _ofmDown = true;
        _ofmDownAt = clock();
        _ofmErrors = 0;
        _changes.add(null);
      }
    }
  }

  /// The source for a view: ours when it is up and the view is inside the extract, else OpenFreeMap, else none.
  BasemapSource sourceFor({required bool inside}) {
    if (inside && oursUp) return BasemapSource.ours;
    if (openFreeMapUp) return BasemapSource.openFreeMap;
    return inside ? BasemapSource.ours : BasemapSource.none; // ours "down" but nothing else: keep trying ours
  }

  /// Tests: forget everything.
  void resetForTest() {
    _oursUp = null;
    _probedAt = null;
    _probe = null;
    _oursErrors = _ofmErrors = 0;
    _ofmDown = false;
    _ofmDownAt = null;
    _ofmTileUrl = OpenFreeMapBasemap.defaultTileUrl;
    _ofmTileJsonAsked = false;
  }
}
