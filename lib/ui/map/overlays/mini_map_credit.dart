// The map credit for the small maps that are not the shared CoverageMap (Where to drive, repeater position / reach / your
// drives, contact, radio tools, live packets, message path, plan tools, drive report, privacy zones, home observer). The
// OpenStreetMap Attribution Guidelines want the credit visible in a corner without interaction; the Drive map has its own
// AttributionLine + Credits sheet. Every small map draws the shared basemap (BasemapLayer), so the line is the credit of
// the source drawn: "Protomaps © OpenStreetMap contributors" on our tiles, OpenFreeMap's credit on the fallback.
// Put it last in a FlutterMap's children (it reads the map camera). Key 'mini-map-credit'.
export '../basemap_layer.dart' show BasemapCredit;

import '../basemap_layer.dart' show BasemapCredit;

/// The small maps' credit widget (kept under its old name).
typedef MiniMapCredit = BasemapCredit;
