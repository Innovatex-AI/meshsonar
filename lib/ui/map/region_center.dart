// Where an empty map should look (Stream 4, lib/core/startup_location.dart mapStartFor): the phone at once (last-known
// fix, refined by the fresh one), else the viewed region's centre, else the middle of every region, else (nothing
// known yet) a whole-world view rather than a guessed city.
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/startup_location.dart';

/// The fallback centre for a map with nothing of its own (no position, no pings): the viewed region's centre, else
/// the hub's middle; null = whole world. (The phone itself is supplied as the map's position, see [idleMapPosition].)
LatLng? viewedRegionCenter(AppState s) {
  final m = s.mapStart;
  final start = m.kind == MapStartKind.phone
      ? mapStartFor(phone: null, viewing: s.viewingRegion, viewingIsManual: s.viewingIsManual, viewingRemembered: true, index: s.regionIndex)
      : m;
  return start.lat == null || start.lon == null ? null : LatLng(start.lat!, start.lon!);
}

/// The phone's position for a map that is not following a drive: shown at once from the last-known fix, then moved to
/// the fresh fix (the map recentres only while the person has not dragged it). Null when the phone was never located,
/// or the person is viewing a region they picked that does not contain it.
LatLng? idleMapPosition(AppState s) {
  final m = s.mapStart;
  return m.kind == MapStartKind.phone ? LatLng(m.lat!, m.lon!) : null;
}

/// The viewed region's bbox as map bounds, or null without a viewed region or a usable bbox. One reading of the bbox for
/// every empty map (Drive / Map, full-screen map, privacy zones editor).
LatLngBounds? viewedRegionBounds(AppState s) {
  final b = s.viewingRegion?.bbox;
  if (b == null || b.length != 4 || !(b[0] < b[2] && b[1] < b[3])) return null;
  return LatLngBounds(LatLng(b[1], b[0]), LatLng(b[3], b[2]));
}

/// The view of last resort for an empty map when nothing at all is known (no fix, no region, no index): the lower 48 and
/// southern Canada, never the whole world.
const LatLng continentalCenter = LatLng(39.5, -98.5);
const double continentalZoom = 3.5;
