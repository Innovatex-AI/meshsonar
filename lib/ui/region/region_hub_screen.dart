// The Region tab: the viewed region (switcher at the top), ten tabs of website data for it, and Export region report.
import 'package:flutter/material.dart';

import '../app.dart';
import '../location_status.dart';
import 'growth_panel.dart';
import 'live_screen.dart';
import 'region_panels.dart';
import 'region_report_export_sheet.dart';
import 'rf_panel.dart';
import 'stats_panel.dart';
import 'region_switcher.dart';

class RegionHubScreen extends StatelessWidget {
  const RegionHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final region = s.viewingRegion;
    return DefaultTabController(
      length: 10,
      child: Scaffold(
        appBar: AppBar(
          title: Text(region?.name ?? 'Region', key: const Key('region-title')),
          actions: [
            if (region != null)
              IconButton(
                key: const Key('region-report-export'),
                tooltip: 'Export region report',
                icon: const Icon(Icons.ios_share),
                onPressed: () => showRegionReportExport(context, baseUrl: region.url, regionSlug: region.slug),
              ),
            const RegionSwitcherChip(),
            const SizedBox(width: 12),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Repeaters'),
              Tab(text: 'Observers'),
              Tab(text: 'Packets'),
              Tab(text: 'Analysis'),
              Tab(text: 'RF'),
              Tab(text: 'Growth'),
              Tab(text: 'Reports'),
              Tab(text: 'Stats'),
              Tab(text: 'Live'),
            ],
          ),
        ),
        body: region == null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    s.regionIndexLoaded
                        ? 'No region to show yet.'
                        : 'Loading regions. Connect to the internet once and they are remembered.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : Column(
                children: [
                  if (s.locationNote != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: LocationNoteBanner(state: s),
                    ),
                  Expanded(
                    child: TabBarView(
                      // Keyed by region: switching region rebuilds every panel against the new region host.
                      key: ValueKey('region-tabs-${region.code}'),
                      children: [
                        buildOverviewPanel(region.url, region.slug),
                        buildRepeatersPanel(region.url, region.slug),
                        buildObserversPanel(region.url, region.slug),
                        buildPacketsPanel(region.url, region.slug),
                        buildAnalysisPanel(region.url, region.slug),
                        RfPanel(baseUrl: region.url, regionSlug: region.slug, windows: s.siteConfig?.rfWindow ?? false),
                        GrowthPanel(baseUrl: region.url, regionSlug: region.slug),
                        buildReportsPanel(region.url, region.slug),
                        StatsPanel(baseUrl: region.url, regionSlug: region.slug),
                        LivePanel(baseUrl: region.url, regionSlug: region.slug),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
