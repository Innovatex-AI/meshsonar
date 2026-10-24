// The Region tab: the viewed region (switcher at the top) and seven tabs of website data for it.
import 'package:flutter/material.dart';

import '../app.dart';
import '../location_status.dart';
import 'live_screen.dart';
import 'region_panels.dart';
import 'stats_panel.dart';
import 'region_switcher.dart';

class RegionHubScreen extends StatelessWidget {
  const RegionHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final region = s.viewingRegion;
    return DefaultTabController(
      length: 8,
      child: Scaffold(
        appBar: AppBar(
          title: Text(region?.name ?? 'Region', key: const Key('region-title')),
          actions: const [RegionSwitcherChip(), SizedBox(width: 12)],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Repeaters'),
              Tab(text: 'Observers'),
              Tab(text: 'Packets'),
              Tab(text: 'Analysis'),
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
