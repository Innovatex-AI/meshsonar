// The six panels hosted by the Region tab. This file is the single integration point: each panel is its own file
// (overview_panel.dart, repeaters_panel.dart, observers_panel.dart, packets_panel.dart, analysis_panel.dart, reports_panel.dart,
// each taking baseUrl and regionSlug).
import 'package:flutter/material.dart';

import 'analysis_panel.dart';
import 'observers_panel.dart';
import 'overview_panel.dart';
import 'repeaters_panel.dart';
import 'reports_panel.dart';

// TODO(integration): Packets stays a stub until their panels land on origin/main.
Widget buildOverviewPanel(String baseUrl, String regionSlug) => SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: OverviewPanel(baseUrl: baseUrl, regionSlug: regionSlug),
    );
Widget buildRepeatersPanel(String baseUrl, String regionSlug) => RepeatersPanel(baseUrl: baseUrl, regionSlug: regionSlug);
Widget buildObserversPanel(String baseUrl, String regionSlug) => SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: ObserversPanel(baseUrl: baseUrl, regionSlug: regionSlug),
    );
Widget buildPacketsPanel(String baseUrl, String regionSlug) => _Stub('Packets', baseUrl);
Widget buildAnalysisPanel(String baseUrl, String regionSlug) => AnalysisPanel(baseUrl: baseUrl, regionSlug: regionSlug);
Widget buildReportsPanel(String baseUrl, String regionSlug) => ReportsPanel(baseUrl: baseUrl, regionSlug: regionSlug);

class _Stub extends StatelessWidget {
  final String name;
  final String baseUrl;
  const _Stub(this.name, this.baseUrl);
  @override
  Widget build(BuildContext context) =>
      Center(child: Text('$name panel coming from $baseUrl', key: Key('panel-stub-$name')));
}
