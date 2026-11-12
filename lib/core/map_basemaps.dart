// What the Map Definition says about the basemaps the app may offer (M3, plan unified-map-system §8b rows M3-1 / M3-2; contract
// meshsonar-infra docs/planning/map-definition-contract.md "Changes", website meshcore-insights docs/PLATFORM_CONTRACT.md
// "Map Definition M3"). Pure Dart.
//
// A client checks the capability string before it relies on a feature: an older definition (a cached copy from before M3) has no
// `capabilities`, so Topo and Satellite are simply not offered from it and a saved choice of either falls back to Chart. Satellite
// needs a usable imagery source: Esri through our proxy when the server has the key (`esriAvailable`), and USGS NAIP (US only).
import 'map_definition.dart';

const capBasemapTopo = 'basemap.topo';
const capBasemapSatellite = 'basemap.satellite';
const capLayerEstimated = 'layer.estimated';
const capLayerRedundancy = 'layer.redundancy';
const capLayerSnrLinks = 'layer.snrlinks';

/// One imagery source of the Satellite basemap (`basemaps[satellite].satellite.sources[]`), bottom to top.
class SatelliteSourceDef {
  final String id, name, tiles;
  final int tileSize, minZoom, maxZoom;

  /// [west, south, east, north].
  final List<double> bounds;
  final List<String> attribution;

  /// The layer is drawn up to this zoom only (NAIP: 17, native tiles end at 16); null = at every zoom.
  final int? layerMaxZoom;
  const SatelliteSourceDef({
    required this.id,
    required this.name,
    required this.tiles,
    required this.tileSize,
    required this.minZoom,
    required this.maxZoom,
    required this.bounds,
    required this.attribution,
    this.layerMaxZoom,
  });

  factory SatelliteSourceDef.fromJson(Map<String, dynamic> j) => SatelliteSourceDef(
    id: j['id'] as String,
    name: j['name'] as String? ?? j['id'] as String,
    tiles: j['tiles'] as String,
    tileSize: (j['tileSize'] as num?)?.toInt() ?? 256,
    minZoom: (j['minzoom'] as num?)?.toInt() ?? 0,
    maxZoom: (j['maxzoom'] as num?)?.toInt() ?? 18,
    bounds: [for (final b in (j['bounds'] as List? ?? const [-180, -85.0511, 180, 85.0511])) (b as num).toDouble()],
    attribution: [for (final a in (j['attribution'] as List? ?? const [])) if (a is String) a],
    layerMaxZoom: (j['layerMaxZoom'] as num?)?.toInt(),
  );
}

/// `basemaps[satellite].satellite`.
class SatelliteDef {
  final List<SatelliteSourceDef> sources;

  /// False = the server has no Esri key: the client leaves `esri` out (only NAIP, US only).
  final bool esriAvailable;

  /// Our vector label layers are drawn over the imagery inside our extract.
  final bool labels;
  const SatelliteDef({required this.sources, required this.esriAvailable, required this.labels});

  /// The sources to draw, bottom to top: `esri` only when the server can serve it.
  List<SatelliteSourceDef> get usable => [for (final s in sources) if (s.id != 'esri' || esriAvailable) s];

  /// The credit lines of the [usable] sources (what the map must show while it draws them).
  List<String> get credits => [for (final s in usable) ...s.attribution];

  /// Honest one-liner for the picker / credits: what the imagery covers right now.
  String get coverageNote => esriAvailable
      ? 'Imagery: USGS NAIP in the US, Esri World Imagery elsewhere. Needs a connection.'
      : 'Imagery: USGS NAIP in the US. Outside the US there is no satellite imagery right now. Needs a connection.';
}

extension MapBasemaps on MapDefinition {
  /// `basemaps[satellite].satellite`, null when the definition has none (an older copy) or it is unusable.
  SatelliteDef? get satellite {
    final s = basemap('satellite')?['satellite'];
    if (s is! Map) return null;
    try {
      final def = SatelliteDef(
        sources: [for (final e in (s['sources'] as List? ?? const [])) if (e is Map) SatelliteSourceDef.fromJson(e.cast<String, dynamic>())],
        esriAvailable: s['esriAvailable'] == true,
        labels: s['labels'] is Map,
      );
      return def.sources.isEmpty ? null : def;
    } catch (_) {
      return null; // a source the app cannot read: Satellite is not offered from this definition
    }
  }

  /// The palette overrides of Topo exist (the app's baked Topo style, tool/basemap/make_basemap_styles.mjs, reads them).
  bool get hasTopo => basemap('topo')?['topo'] is Map;

  /// Topo is offered: the capability string AND a topo palette in the definition.
  bool get offersTopo => hasCapability(capBasemapTopo) && hasTopo;

  /// Satellite is offered: the capability string AND at least one imagery source the app can draw (`esri` with the key, or NAIP).
  bool get offersSatellite {
    if (!hasCapability(capBasemapSatellite)) return false;
    final s = satellite;
    return s != null && s.usable.isNotEmpty;
  }

  /// The credit lines the definition requires for basemap [id] ("Protomaps", the OpenStreetMap line, imagery credits...).
  List<String> basemapCredits(String id) => [for (final a in (basemap(id)?['attribution'] as List? ?? const [])) if (a is String) a];
}
