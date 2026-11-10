// "Open the map here" (map_preview.dart): a preview asks the main map (the Drive tab's CoverageMap) to look at a spot. The
// request is kept until the main map takes it, so it works whether the Drive map is already built or is built after the tab
// switch. The main map stops following the position (the person asked to look elsewhere) until they press Recenter.
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

@immutable
class MapFocusRequest {
  final LatLng at;
  final double zoom;
  final int seq;
  const MapFocusRequest(this.at, this.zoom, this.seq);
}

class MainMapFocus {
  MainMapFocus._();
  static final ValueNotifier<MapFocusRequest?> notifier = ValueNotifier<MapFocusRequest?>(null);
  static int _seq = 0;

  static void request(LatLng at, double zoom) => notifier.value = MapFocusRequest(at, zoom.clamp(3, 18).toDouble(), ++_seq);

  /// The main map took [r]: clears it (only if nothing newer came in).
  static void taken(MapFocusRequest r) {
    if (identical(notifier.value, r)) notifier.value = null;
  }
}
