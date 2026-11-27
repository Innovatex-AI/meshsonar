// "Open the map" from a small map on a Network page (build 77, Round 1 N6): the Live map looks at that spot. Kept until the Live
// map takes it, so it works whether the map is already built or is built after the section switch.
import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';

class LiveMapFocus {
  LiveMapFocus._();
  static final ValueNotifier<(LatLng, double)?> notifier = ValueNotifier(null);

  static void request(LatLng at, double zoom) => notifier.value = (at, zoom.clamp(3, 18).toDouble());

  /// The Live map took it.
  static (LatLng, double)? take() {
    final v = notifier.value;
    notifier.value = null;
    return v;
  }
}
