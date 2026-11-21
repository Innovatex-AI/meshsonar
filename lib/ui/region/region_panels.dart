// The one region panel the Network tab still hosts: Home > Overview (overview_panel.dart). The old repeaters, observers,
// packets, analysis and reports builders were retired in build 71 (the `/v1` screens in lib/ui/network and the site's
// Analytics pages replace them).
import 'package:flutter/material.dart';

import 'overview_panel.dart';

Widget buildOverviewPanel(String baseUrl, String regionSlug) => SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: OverviewPanel(baseUrl: baseUrl, regionSlug: regionSlug),
    );
