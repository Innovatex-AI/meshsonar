// Base maps the Drive tab can show. Pure Dart. The cycler button steps through [BaseMapStyle.values].
//
//  chart   the app's own map (plan §2.3 Road / Dark): our Protomaps vector tiles in the website's light or dark style,
//          following the app theme (and the downloaded offline pack when one covers the map).
//  street  the same map, always in the light style (readable in sunlight, whatever the app theme). The id stays 'street'
//          so a saved choice keeps working; it was plain OpenStreetMap colours before M2.
//  dark    the same map, always in the dark style (night driving).
//  topo    OpenTopoMap (free, OSM-based contour map) for terrain until M3 brings our own Topo.
//
// chart / street / dark are vector tiles from api.meshsonar.com/basemap with OpenFreeMap as the automatic fallback
// (core/basemap.dart); the credit on the map follows the source actually drawn. OpenStreetMap's community tile server is
// never used (test/lint/no_osm_tile_server_test.dart). Topo has no offline pack; it is drawn from the network only.
import 'basemap.dart' show OurBasemap;

enum BaseMapStyle {
  chart('chart', 'Chart', 'Our map, light or dark with your theme', null, 19, OurBasemap.attribution, true),
  street('street', 'Light', 'Always the light map (bright sun)', null, 19, OurBasemap.attribution, true),
  dark('dark', 'Dark', 'Always the dark map (night driving)', null, 19, OurBasemap.attribution, true),
  topo('topo', 'Topo', 'Terrain and contours (needs a connection)', 'https://tile.opentopomap.org/{z}/{x}/{y}.png', 17,
      '© OpenStreetMap contributors, SRTM | Map style © OpenTopoMap (CC-BY-SA)', false);

  final String id;
  final String label;
  final String blurb;
  /// The raster tile URL (Topo only); null for the vector basemap styles.
  final String? tileUrl;

  /// Highest zoom the tile server has; the map scales these tiles beyond it.
  final int maxNativeZoom;
  /// The default credit (the vector styles show the credit of the source drawn: ours or OpenFreeMap).
  final String attribution;

  /// An installed offline region pack may be drawn instead of the online tiles.
  final bool usesOfflinePack;
  const BaseMapStyle(this.id, this.label, this.blurb, this.tileUrl, this.maxNativeZoom, this.attribution, this.usesOfflinePack);

  /// The next style in the cycle (wraps).
  BaseMapStyle get next => values[(index + 1) % values.length];

  /// Drawn from our vector tiles (with the OpenFreeMap fallback); false = the raster [tileUrl].
  bool get isVector => tileUrl == null;

  /// No colour grading: the vector styles are already the website's light / dark styles and Topo is drawn as its server made it.
  bool get ungraded => true;

  /// The dark look: true / false forced, null = follow the app theme.
  bool? get darkLook => switch (this) {
    BaseMapStyle.dark => true,
    BaseMapStyle.street => false,
    _ => null,
  };

  /// Forces the dark grading (and the dark offline style) whatever the theme says.
  bool get forcesDark => this == BaseMapStyle.dark;

  /// The style stored as [id]; anything unknown (a newer app's choice, a damaged file) is the default.
  static BaseMapStyle parse(String? id) {
    for (final s in values) {
      if (s.id == id) return s;
    }
    return BaseMapStyle.chart;
  }
}
