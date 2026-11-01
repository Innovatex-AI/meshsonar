// Where the privacy-zone map opens (Settings > Privacy & data sharing > Privacy zones). Pure: no widgets, no AppState.
// Order (Andy, Oct 31 2026): the saved zones, framed together; else the phone's last known position (no new permission
// prompt: the fix the app already holds); else the viewed region's bounds (or its centre); else the middle of every
// region; and only then a continental view, never the whole world.
import 'dart:math' as math;

import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import '../../core/privacy_zones.dart';
import '../../core/region_lookup.dart';
import '../map/region_center.dart' show continentalCenter, continentalZoom;

enum ZoneStartKind { zones, phone, region, fallback }

class ZoneStart {
  final ZoneStartKind kind;
  final LatLng center;
  final double zoom;

  /// Set when the view should fit an area (several zones, a region's bbox); then [zoom] is only the fallback.
  final LatLngBounds? bounds;
  const ZoneStart(this.kind, this.center, this.zoom, {this.bounds});
}

/// A zoom at which a circle of [radiusM] at [lat] is about 110 px in radius: the whole circle and its surroundings in view.
double zoneZoomFor(double radiusM, double lat) {
  final z =
      math.log(
        156543.03392 *
            math.cos(lat * math.pi / 180) *
            110 /
            math.max(radiusM, 1),
      ) /
      math.ln2;
  return z.clamp(9.0, 17.0);
}

/// The box that holds every zone circle in full.
LatLngBounds zonesBounds(List<PrivacyZone> zones) {
  var s = 90.0, n = -90.0, w = 180.0, e = -180.0;
  for (final z in zones) {
    final dLat = z.radiusM / 111320.0;
    final dLon =
        z.radiusM /
        (111320.0 * math.max(math.cos(z.lat * math.pi / 180), 0.01));
    s = math.min(s, z.lat - dLat);
    n = math.max(n, z.lat + dLat);
    w = math.min(w, z.lon - dLon);
    e = math.max(e, z.lon + dLon);
  }
  return LatLngBounds(
    LatLng(s.clamp(-85.0, 85.0), w.clamp(-180.0, 180.0)),
    LatLng(n.clamp(-85.0, 85.0), e.clamp(-180.0, 180.0)),
  );
}

ZoneStart zoneStart({
  required List<PrivacyZone> zones,
  ({double lat, double lon})? phone,
  RegionIndexEntry? region,
  LatLng? hub,
}) {
  if (zones.length == 1) {
    return ZoneStart(
      ZoneStartKind.zones,
      LatLng(zones.first.lat, zones.first.lon),
      zoneZoomFor(zones.first.radiusM, zones.first.lat),
    );
  }
  if (zones.length > 1) {
    final b = zonesBounds(zones);
    return ZoneStart(ZoneStartKind.zones, b.center, 12, bounds: b);
  }
  if (phone != null) {
    return ZoneStart(ZoneStartKind.phone, LatLng(phone.lat, phone.lon), 14);
  }
  final bb = region?.bbox;
  if (bb != null && bb.length == 4 && bb[0] < bb[2] && bb[1] < bb[3]) {
    final b = LatLngBounds(LatLng(bb[1], bb[0]), LatLng(bb[3], bb[2]));
    return ZoneStart(ZoneStartKind.region, b.center, 9, bounds: b);
  }
  if (hub != null) return ZoneStart(ZoneStartKind.region, hub, 9);
  return const ZoneStart(
    ZoneStartKind.fallback,
    continentalCenter,
    continentalZoom,
  );
}
