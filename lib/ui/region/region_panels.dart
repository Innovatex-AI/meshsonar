// The six panels hosted by the Region tab. Each is built by a sibling work package as its own file
// (overview_panel.dart, repeaters_panel.dart, observers_panel.dart, packets_panel.dart, analysis_panel.dart, reports_panel.dart, each taking baseUrl and
// regionSlug). This file is the single integration point.
import 'package:flutter/material.dart';

// TODO(integration): replace each stub with the real panel once it lands on origin/main.
Widget buildOverviewPanel(String baseUrl, String regionSlug) => _Stub('Overview', baseUrl);
Widget buildRepeatersPanel(String baseUrl, String regionSlug) => _Stub('Repeaters', baseUrl);
Widget buildObserversPanel(String baseUrl, String regionSlug) => _Stub('Observers', baseUrl);
Widget buildPacketsPanel(String baseUrl, String regionSlug) => _Stub('Packets', baseUrl);
Widget buildAnalysisPanel(String baseUrl, String regionSlug) => _Stub('Analysis', baseUrl);
Widget buildReportsPanel(String baseUrl, String regionSlug) => _Stub('Reports', baseUrl);

class _Stub extends StatelessWidget {
  final String name;
  final String baseUrl;
  const _Stub(this.name, this.baseUrl);
  @override
  Widget build(BuildContext context) =>
      Center(child: Text('$name panel coming from $baseUrl', key: Key('panel-stub-$name')));
}
