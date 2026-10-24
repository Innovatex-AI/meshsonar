// Where an empty map should look (Stream 4, lib/core/startup_location.dart mapStartFor): the phone at once (last-known
// fix, refined by the fresh one), else the viewed region's centre, else the middle of every region, else (nothing
// known yet) a whole-world view rather than a guessed city.
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
