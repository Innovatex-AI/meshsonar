// Where an empty map should look: the centre of the region being viewed (from regions-index). Null until the
// index has loaded, in which case the map shows a whole-world view instead of guessing a city.
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/region_pick.dart';

LatLng? viewedRegionCenter(AppState s) {
  final r = s.viewingRegion;
  final c = r == null ? null : regionCenter(r);
  return c == null ? null : LatLng(c.lat, c.lon);
}
