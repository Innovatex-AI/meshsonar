// The region panels still hosted by the Network tab (overview_panel.dart, analysis_panel.dart, reports_panel.dart, each
// taking baseUrl and regionSlug). The old repeaters, observers and packets panels were retired in build 71: the lists
// and detail pages are the `/v1` ones in lib/ui/network/{nodes,packets}.
import 'package:flutter/material.dart';

import 'analysis_panel.dart';
import 'overview_panel.dart';
import 'reports_panel.dart';

Widget buildOverviewPanel(String baseUrl, String regionSlug) => SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: OverviewPanel(baseUrl: baseUrl, regionSlug: regionSlug),
    );
Widget buildAnalysisPanel(String baseUrl, String regionSlug) => AnalysisPanel(baseUrl: baseUrl, regionSlug: regionSlug);
Widget buildReportsPanel(String baseUrl, String regionSlug) => ReportsPanel(baseUrl: baseUrl, regionSlug: regionSlug);
