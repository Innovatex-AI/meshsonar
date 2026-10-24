// "Open repeater page" from a map repeater sheet: the region's repeater detail screen, for a key in a roster the app
// knows (RepeaterPoint.region is set only then).
import 'package:flutter/widgets.dart';

import '../region/repeater_detail_screen.dart' show openRepeaterDetail;
import 'layers/repeater_map_source.dart' show RepeaterPoint;

void openRepeaterPageFromMap(BuildContext context, RepeaterPoint p) {
  final r = p.region;
  if (r == null) return;
  openRepeaterDetail(context, baseUrl: r.baseUrl, regionSlug: r.slug, repeaterKey: p.key);
}
