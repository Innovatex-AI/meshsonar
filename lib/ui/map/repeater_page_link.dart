// "Open repeater page" from a map repeater sheet: the region's repeater detail screen, for a key in a roster the app
// knows (RepeaterPoint.region is set only then).
import 'package:flutter/widgets.dart';

import '../network/nodes/node_routes.dart' show openNetworkNode;
import 'layers/repeater_map_source.dart' show RepeaterPoint;

void openRepeaterPageFromMap(BuildContext context, RepeaterPoint p) {
  final r = p.region;
  if (r == null) return;
  openNetworkNode(context, baseUrl: r.baseUrl, regionSlug: r.slug, nodeKey: p.key);
}
