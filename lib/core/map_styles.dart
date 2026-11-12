// Base maps the Drive tab can show. Pure Dart. The cycler button steps through [availableBaseStyles].
//
//  chart      the app's own map (plan §2.3 Road / Dark): our Protomaps vector tiles in the website's light or dark style,
//             following the app theme (and the downloaded offline pack when one covers the map).
//  street     the same map, always in the light style (readable in sunlight, whatever the app theme). The id stays 'street'
//             so a saved choice keeps working; it was plain OpenStreetMap colours before M2.
//  dark       the same map, always in the dark style (night driving).
//  topo       (M3) the same vector tiles in the Map Definition's topographic palette (land cover, water and roads in earth
//             tones; the definition's `basemaps[topo].topo` overrides over Protomaps' flavour). It replaced OpenTopoMap, which
//             the app no longer calls. No offline pack; the network only. The id stays 'topo'.
//  satellite  (M3) aerial imagery: USGS NAIP in the US, Esri World Imagery through MeshSonar's own proxy elsewhere, with our town
//             and road names over it inside the basemap extract. Raster, the network only, credits always on the map.
//
// chart / street / dark / topo are vector tiles from api.meshsonar.com/basemap with OpenFreeMap as the automatic fallback
// (core/basemap.dart); the credit on the map follows the source actually drawn. OpenStreetMap's community tile server is
// never used (test/lint/no_osm_tile_server_test.dart). Topo and Satellite are OFFERED only when the Map Definition advertises
// them (`capabilities`, core/map_basemaps.dart); an older definition offers the first three.
import 'basemap.dart' show BasemapLook, OurBasemap;
import 'map_basemaps.dart';
import 'map_definition.dart' show MapDefinition;

enum BaseMapStyle {
  chart('chart', 'Chart', 'Our map, light or dark with your theme', 19, OurBasemap.attribution, true),
  street('street', 'Light', 'Always the light map (bright sun)', 19, OurBasemap.attribution, true),
  dark('dark', 'Dark', 'Always the dark map (night driving)', 19, OurBasemap.attribution, true),
  topo('topo', 'Topo', 'Land cover and terrain colours (needs a connection)', 19, OurBasemap.attribution, false),
  satellite('satellite', 'Satellite', 'Aerial imagery (needs a connection)', 18, '', false);

  final String id;
  final String label;
  final String blurb;

  /// Highest zoom the map draws for this style (the tiles scale beyond their own maximum).
  final int maxNativeZoom;
  /// The default credit (the vector styles show the credit of the source drawn: ours or OpenFreeMap; Satellite builds its own
  /// from the definition's imagery sources).
  final String attribution;

  /// An installed offline region pack may be drawn instead of the online tiles.
  final bool usesOfflinePack;
  const BaseMapStyle(this.id, this.label, this.blurb, this.maxNativeZoom, this.attribution, this.usesOfflinePack);

  /// The next style in the cycle over every style (wraps); the cycler uses [nextAvailable].
  BaseMapStyle get next => values[(index + 1) % values.length];

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

  /// Which Protomaps look the vector layer draws.
  BasemapLook get look => this == BaseMapStyle.topo ? BasemapLook.topo : BasemapLook.road;

  /// Needs the network: no offline pack draws it, so offline-only use gets an honest message instead of a blank map.
  bool get needsNetwork => !usesOfflinePack;

  /// No colour grading: the vector styles are already the website's light / dark styles and Satellite is drawn as served.
  bool get ungraded => true;

  /// The dark look: true / false forced, null = follow the app theme.
  bool? get darkLook => switch (this) {
    BaseMapStyle.dark => true,
    BaseMapStyle.street => false,
    _ => null,
  };

  /// Forces the dark grading (and the dark offline style) whatever the theme says.
  bool get forcesDark => this == BaseMapStyle.dark;

  /// The styles the person may pick given the Map Definition in use: Chart, Light and Dark always; Topo and Satellite only when
  /// the definition advertises them (and Satellite has an imagery source).
  static List<BaseMapStyle> availableFor(MapDefinition d) => [
    BaseMapStyle.chart,
    BaseMapStyle.street,
    BaseMapStyle.dark,
    if (d.offersTopo) BaseMapStyle.topo,
    if (d.offersSatellite) BaseMapStyle.satellite,
  ];

  /// What is drawn when [wanted] (the saved choice) is not offered by [d] (a cached definition from before M3): Chart.
  static BaseMapStyle effective(BaseMapStyle wanted, MapDefinition d) => availableFor(d).contains(wanted) ? wanted : BaseMapStyle.chart;

  /// The style stored as [id]; anything unknown (a newer app's choice, a damaged file) is the default.
  static BaseMapStyle parse(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return BaseMapStyle.chart;
  }
}
