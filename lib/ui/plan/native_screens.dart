// The Plan tab's native planning screens, by tool id (lib/ui/shell/plan_tab.dart). A tool with an entry here opens its screen in the
// app; the others still open the website until they are converted.
import 'package:flutter/widgets.dart';

import 'planner_screen.dart';
import 'recommended_screen.dart';
import 'scenarios_screen.dart';
import 'sites_screen.dart';
import 'tracker_screen.dart';

final Map<String, WidgetBuilder> nativePlanScreens = {
  'planner': (_) => const PlannerScreen(),
  'recommended': (_) => const RecommendedScreen(),
  'sites': (_) => const SitesScreen(),
  'scenarios': (_) => const ScenariosScreen(),
  'tracker': (_) => const TrackerScreen(),
};
