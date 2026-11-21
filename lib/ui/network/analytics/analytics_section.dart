// Network > Analytics (build 71 seam; stream D fills this in). The signature is fixed: stream A builds the section strip
// against it. Shows the list of the site's analytics tabs and opens each one in [SitePageView].
import 'package:flutter/material.dart';

class AnalyticsSection extends StatelessWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A tab slug to open straight away (from an `/analytics/<slug>` link); null shows the list.
  final String? initialTab;
  const AnalyticsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialTab});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
