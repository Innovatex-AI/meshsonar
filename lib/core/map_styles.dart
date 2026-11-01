// Base maps the Map tab can show. Pure Dart. The cycler button steps through [BaseMapStyle.values].
//
//  chart   the app's own look: OpenStreetMap graded to the theme (and the downloaded offline pack when one covers the map).
//  street  plain OpenStreetMap colours, no grading: readable in sunlight, labels exactly as OSM draws them.
//  dark    OpenStreetMap forced to the dark chart grading whatever the app theme is (night driving).
//  topo    OpenTopoMap (free, OSM-based contour map) for terrain: line of sight, hills between you and a repeater.
//
// Offline: chart, street and dark use an installed region pack when it covers the map (street and chart draw the pack in its
// light style, dark in its dark style). Topo has no offline pack; it is drawn from the network only, and the sheet says so.
// Every style keeps the same attribution duty: [BaseMapStyle.attribution] is shown on the map.

enum BaseMapStyle {
  chart('chart', 'Chart', 'The app look, graded to your theme', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 19,
      '© OpenStreetMap contributors', true),
  street('street', 'Street', 'Plain OpenStreetMap colours', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 19,
      '© OpenStreetMap contributors', true),
  dark('dark', 'Dark', 'Dark chart for night driving', 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', 19,
      '© OpenStreetMap contributors', true),
  topo('topo', 'Topo', 'Terrain and contours (needs a connection)', 'https://tile.opentopomap.org/{z}/{x}/{y}.png', 17,
      '© OpenStreetMap contributors, SRTM | Map style © OpenTopoMap (CC-BY-SA)', false);

  final String id;
  final String label;
  final String blurb;
  final String tileUrl;

  /// Highest zoom the tile server has; the map scales these tiles beyond it.
  final int maxNativeZoom;
  final String attribution;

  /// An installed offline region pack may be drawn instead of the online tiles.
  final bool usesOfflinePack;
  const BaseMapStyle(this.id, this.label, this.blurb, this.tileUrl, this.maxNativeZoom, this.attribution, this.usesOfflinePack);

  /// The next style in the cycle (wraps).
  BaseMapStyle get next => values[(index + 1) % values.length];

  /// Plain OSM colours: the tile colour grading is skipped.
  bool get ungraded => this == BaseMapStyle.street || this == BaseMapStyle.topo;

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
