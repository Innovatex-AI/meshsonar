// Base maps the maps can show: the choices of the picker, and what each one draws. Pure Dart.
//
// The five choices (build 77, redesign Round 1 N3; ids are the saved setting and never change):
//  chart      "Road": our Protomaps vector tiles in the light or dark style, following the app theme. (Called Chart before
//             build 77; the id stays 'chart'.)
//  street     "Light": the same map, always light (readable in sunlight, whatever the app theme). Offered always since build
//             77: builds 74 to 76 hid it when the Map Definition merged Chart and Light, which left a dark-theme user with no
//             light road map. The id stays 'street' (it was plain OpenStreetMap colours before M2).
//  dark       "Dark": the same map, always dark (night driving).
//  topo       "Topo" (M3): the same vector tiles in the Map Definition's topographic palette. The id stays 'topo'.
//  satellite  "Satellite" (M3): aerial imagery (USGS NAIP in the US, Esri World Imagery through MeshSonar's own proxy elsewhere)
//             with our town and road names over it inside the basemap extract. Raster, the network only.
// Each has a real thumbnail for the picker ([BaseMapStyle.thumbnailAsset], assets/map/thumbs, rendered from the styles by
// tool/basemap/make_basemap_thumbs.mjs).
//
// What a choice draws is [BaseMapStyle.resolve]: with coverage on, Road / Light / Dark draw the data-first style (no building
// outlines until street zoom, dimmer side streets, brighter water, fewer street names) and the names are a second pass above
// the coverage; Topo and Satellite keep their look and also get the names pass. See core/basemap.dart [BasemapLook].
//
// chart / street / dark / topo are vector tiles from api.meshsonar.com/basemap with OpenFreeMap as the automatic fallback
// (core/basemap.dart); the credit on the map follows the source actually drawn. OpenStreetMap's community tile server is
// never used (test/lint/no_osm_tile_server_test.dart). Topo and Satellite are OFFERED only when the Map Definition advertises
// them (`capabilities`, core/map_basemaps.dart); an older definition offers the first three.
import 'basemap.dart' show BasemapLook, OurBasemap;
import 'map_basemaps.dart';
import 'map_definition.dart' show MapDefinition;
import 'map_definition_pages.dart';

enum BaseMapStyle {
  chart('chart', 'Road', 'Streets, light or dark with your theme', 19, OurBasemap.attribution),
  street('street', 'Light', 'Always light, easy to read in sun', 19, OurBasemap.attribution),
  dark('dark', 'Dark', 'Always dark, for night driving', 19, OurBasemap.attribution),
  topo('topo', 'Topo', 'Land cover and terrain colours', 19, OurBasemap.attribution),
  satellite('satellite', 'Satellite', 'Aerial photos', 18, '');

  final String id;
  final String label;
  final String blurb;

  /// Highest zoom the map draws for this style (the tiles scale beyond their own maximum).
  final int maxNativeZoom;
  /// The default credit (the vector styles show the credit of the source drawn: ours or OpenFreeMap; Satellite builds its own
  /// from the definition's imagery sources).
  final String attribution;
  const BaseMapStyle(this.id, this.label, this.blurb, this.maxNativeZoom, this.attribution);

  /// The next style among [available] (wraps; the current one when it is the only one).
  BaseMapStyle nextAvailable(List<BaseMapStyle> available) {
    if (available.isEmpty) return this;
    final i = available.indexOf(this);
    return available[(i + 1) % available.length];
  }

  /// Drawn from our vector tiles (with the OpenFreeMap fallback); false = Satellite's raster imagery.
  bool get isVector => this != BaseMapStyle.satellite;

  /// Aerial imagery under everything (a busy picture: overlays get a surface pill, the credit sits on a pill).
  bool get isSatellite => this == BaseMapStyle.satellite;

  /// Which Protomaps look the vector layer draws with coverage off (see [resolve] for the look under coverage).
  BasemapLook get look => this == BaseMapStyle.topo ? BasemapLook.topo : BasemapLook.road;

  /// No colour grading: the vector styles are already the website's light / dark styles and Satellite is drawn as served.
  bool get ungraded => true;

  /// The dark look: true / false forced, null = follow the app theme.
  bool? get darkLook => switch (this) {
    BaseMapStyle.dark => true,
    BaseMapStyle.street => false,
    _ => null,
  };

  /// Forces the dark grading whatever the theme says.
  bool get forcesDark => this == BaseMapStyle.dark;

  /// The map this choice draws is dark (light names, the dark credit pill): Dark and Satellite always, Light never, Road and
  /// Topo with the app theme ([appDark]).
  bool isDark({required bool appDark}) => isSatellite || (darkLook ?? appDark);

  /// The picker thumbnail (360 x 168 px, a real render of the style over downtown Columbus): Road is the light and the dark
  /// map split on the diagonal (it follows the theme), Topo is its light or dark palette with the app theme.
  String thumbnailAsset({required bool appDark}) => switch (this) {
    BaseMapStyle.chart => '$thumbnailFolder/road.png',
    BaseMapStyle.street => '$thumbnailFolder/light.png',
    BaseMapStyle.dark => '$thumbnailFolder/dark.png',
    BaseMapStyle.topo => '$thumbnailFolder/topo-${appDark ? 'dark' : 'light'}.png',
    BaseMapStyle.satellite => '$thumbnailFolder/satellite.png',
  };

  /// Where the thumbnails are bundled (pubspec.yaml lists the folder).
  static const thumbnailFolder = 'assets/map/thumbs';

  /// Every thumbnail file the picker can ask for.
  static List<String> get thumbnailAssets => {
    for (final s in values)
      for (final appDark in [false, true]) s.thumbnailAsset(appDark: appDark),
  }.toList();

  /// What this choice draws on a map of an app in the [appDark] theme.
  ///
  /// [coverageOn]: a coverage layer (Measured, Predicted, Heard, This drive) is showing. Road, Light and Dark then draw the
  /// data-first style, and every choice gets its names as a second pass to draw ABOVE the coverage.
  /// [labelsAbove] false keeps the names in the base layer (one map layer instead of two: a small map, or a phone that fails
  /// the map performance gate with two).
  ///
  /// On the OpenFreeMap fallback the base layer draws OpenFreeMap's own style, names included, and the names pass draws
  /// nothing (ui/map/basemap_layer.dart), so names are under the coverage there.
  static ResolvedBasemap resolve(BaseMapStyle choice, {required bool appDark, required bool coverageOn, bool labelsAbove = true}) {
    final dark = choice.isDark(appDark: appDark);
    final split = coverageOn && labelsAbove;
    if (choice.isSatellite) return ResolvedBasemap(choice, dark: true, base: null, labels: split ? BasemapLook.labels : null);
    if (choice == BaseMapStyle.topo) {
      return split
          ? ResolvedBasemap(choice, dark: dark, base: BasemapLook.topoBase, labels: BasemapLook.topoLabels)
          : ResolvedBasemap(choice, dark: dark, base: BasemapLook.topo, labels: null);
    }
    if (!coverageOn) return ResolvedBasemap(choice, dark: dark, base: BasemapLook.road, labels: null);
    return split
        ? ResolvedBasemap(choice, dark: dark, base: BasemapLook.dataBase, labels: BasemapLook.dataLabels)
        : ResolvedBasemap(choice, dark: dark, base: BasemapLook.data, labels: null);
  }

  /// The definition says the basemaps as variables (`variables.basemap`, schemaMinor 7). Builds 74 to 76 then hid Light; build
  /// 77 offers Road, Light and Dark whatever the definition says, so this no longer changes the list or a name.
  static bool roadMerged(MapDefinition d) => d.basemapVariableIds != null;

  /// The name shown for this style ([label]; the definition no longer changes it. Kept for the callers of builds 74 to 76).
  String labelIn(MapDefinition d) => label;

  /// The choices the person may pick given the Map Definition in use, in picker order: Road, Light and Dark always; Topo and
  /// Satellite only when the definition advertises them (and Satellite has an imagery source).
  static List<BaseMapStyle> availableFor(MapDefinition d) => [
    BaseMapStyle.chart,
    BaseMapStyle.street,
    BaseMapStyle.dark,
    if (d.offersTopo) BaseMapStyle.topo,
    if (d.offersSatellite) BaseMapStyle.satellite,
  ];

  /// What is drawn when [wanted] (the saved choice) is not offered by [d] (a cached definition from before M3): Road.
  static BaseMapStyle effective(BaseMapStyle wanted, MapDefinition d) => availableFor(d).contains(wanted) ? wanted : BaseMapStyle.chart;

  /// The choice stored as [id]. Every id a build has ever saved maps onto today's choices: `chart` (Chart, now Road), `street`
  /// (Light), `dark`, `topo`, `satellite`; the Map Definition's own names for them (`road`, `light`) are read too. Anything
  /// unknown (a newer app's choice, a damaged file) is Road.
  static BaseMapStyle parse(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return switch (id) {
      'light' => BaseMapStyle.street,
      _ => BaseMapStyle.chart, // 'road', 'relief', 'plain' and anything unknown
    };
  }
}

/// What a base map choice draws ([BaseMapStyle.resolve]).
class ResolvedBasemap {
  final BaseMapStyle choice;

  /// The map drawn is dark (pass it to `BasemapLayer.dark`; names and the credit take the light ink).
  final bool dark;

  /// The vector look of the bottom layer; null = Satellite's imagery (ui/map/satellite_layers.dart).
  final BasemapLook? base;

  /// The names-only look to draw above the coverage; null = the names are part of [base] (for Satellite: drawn straight over
  /// the imagery, as before build 77).
  final BasemapLook? labels;
  const ResolvedBasemap(this.choice, {required this.dark, required this.base, required this.labels});

  bool get isSatellite => base == null;

  @override
  bool operator ==(Object other) => other is ResolvedBasemap && other.choice == choice && other.dark == dark && other.base == base && other.labels == labels;
  @override
  int get hashCode => Object.hash(choice, dark, base, labels);
  @override
  String toString() => 'ResolvedBasemap(${choice.id}, ${dark ? 'dark' : 'light'}, base: ${base?.name}, labels: ${labels?.name})';
}
