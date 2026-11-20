// The five Network sections (AZ-3.1): Now, Packets, Nodes, Map, Insights. They re-home the old Analyze > Region area's
// thirteen tabs without changing any panel (each still takes the region host and slug):
//   Now      : Findings (old "Analyze" tab) | Overview
//   Packets  : List (AZ-3.2: /v1/packets with filters, My radio, Decode a packet) | Live (old "Live")
//   Nodes    : Nodes (every role, AZ-3.4) | Observers
//   Map      : the live packet map with replay (AZ-3.3, lib/ui/network/live/live_map_view.dart)
//   Insights : Analysis, RF, Growth, Reports, Stats, Silent repeaters, Wardrive share (each opens as its own page)
// Only the shown section and sub-view is built, so hidden panels never poll or hold a live stream (battery rules).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/airtime_share.dart';
import '../../core/region_lookup.dart';
import '../app.dart';
import '../region/analyze_panel.dart';
import '../region/growth_panel.dart';
import '../region/live_screen.dart';
import '../region/packet_analytics_panels.dart';
import '../region/region_panels.dart';
import '../region/rf_panel.dart';
import '../region/stats_panel.dart';
import 'live/live_map_view.dart';
import 'network_header.dart';
import 'nodes/nodes_section.dart';
import 'packets/packet_list_view.dart';

/// The sub-views of a section that has more than one (labels in display order).
const Map<NetworkSection, List<String>> networkSubViews = {
  NetworkSection.now: ['Findings', 'Overview'],
  NetworkSection.packets: ['List', 'Live'],
  NetworkSection.nodes: ['Nodes', 'Observers'],
};

/// One Insights entry: its id (also the `?tab=` names that open it), title, one line, and the panel.
class InsightEntry {
  final String id;
  final Set<String> tabs;
  final String title, subtitle;
  final IconData icon;
  final Widget Function(AppState s, RegionIndexEntry r) build;
  const InsightEntry(this.id, this.tabs, this.title, this.subtitle, this.icon, this.build);
}

final List<InsightEntry> insightEntries = [
  InsightEntry('analysis', {'analysis', 'hashes', 'roles', 'routes', 'overview'}, 'Analysis', 'Role mix, hash sizes, busiest hours, hops, top carriers',
      Icons.analytics_outlined, (s, r) => buildAnalysisPanel(r.url, r.slug)),
  InsightEntry('rf', {'rf', 'signal'}, 'RF', 'Noise floor by observer and hour, SNR spread', Icons.graphic_eq,
      (s, r) => RfPanel(baseUrl: r.url, regionSlug: r.slug, windows: s.siteConfig?.rfWindow ?? false)),
  InsightEntry('growth', {'growth'}, 'Growth', 'How the network grew', Icons.trending_up, (s, r) => GrowthPanel(baseUrl: r.url, regionSlug: r.slug)),
  InsightEntry('reports', {'reports', 'sources'}, 'Reports', 'Region report and its sources', Icons.description_outlined,
      (s, r) => buildReportsPanel(r.url, r.slug)),
  InsightEntry('stats', {'stats'}, 'Stats', 'Drives, pings and the leaderboard', Icons.leaderboard_outlined,
      (s, r) => StatsPanel(baseUrl: r.url, regionSlug: r.slug)),
  InsightEntry('silent', {'silent', 'health'}, 'Silent repeaters', 'Repeaters not heard lately', Icons.notifications_paused_outlined,
      (s, r) => SilentRepeatersPanel(baseUrl: r.url, regionSlug: r.slug, ownKeys: {for (final c in s.claims.active) c.pubkey.toLowerCase()})),
  InsightEntry('wardrive', {'wardrive', 'airtime'}, 'Wardrive share', 'How much airtime wardriving uses here', Icons.radar,
      (s, r) => AirtimeSharePanel(
            baseUrl: r.url,
            regionSlug: r.slug,
            radio: s.viewingPreset == null ? null : LoraRadio(s.viewingPreset!.sf, s.viewingPreset!.bwKhz, s.viewingPreset!.cr),
            radioLabel: s.viewingPreset?.name,
          )),
];

/// The Insights entry a `?tab=` name opens; null for a tab with no app page yet (Topology, Channels, ...: AZ-3.7/3.9).
InsightEntry? insightForTab(String? tab) {
  if (tab == null) return null;
  for (final e in insightEntries) {
    if (e.tabs.contains(tab)) return e;
  }
  return null;
}

/// Opens one Insights page over the tab (its own app bar and Back).
void openInsight(BuildContext context, InsightEntry e, AppState s, RegionIndexEntry r) {
  Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => Scaffold(
      key: Key('insight-page-${e.id}'),
      appBar: AppBar(title: Text('${e.title} · ${r.code}')),
      body: e.build(s, r),
    ),
  ));
}

/// The small sub-view switch at the top of a section (Findings | Overview, ...).
class NetworkSubSwitch extends StatelessWidget {
  final NetworkSection section;
  final int selected;
  final ValueChanged<int> onChanged;
  const NetworkSubSwitch({super.key, required this.section, required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final labels = networkSubViews[section]!;
    final c = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
        child: Semantics(
          container: true,
          label: '${section.label} views',
          child: SizedBox(
            width: double.infinity,
            child: CupertinoSlidingSegmentedControl<int>(
              key: Key('network-sub-${section.name}'),
              groupValue: selected,
              thumbColor: c.surfaceContainerHighest,
              backgroundColor: c.onSurface.withValues(alpha: 0.10),
              children: {
                for (var i = 0; i < labels.length; i++)
                  i: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 36),
                    child: Center(child: Text(labels[i], key: Key('network-sub-${section.name}-$i'), maxLines: 1)),
                  ),
              },
              onValueChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// A section's body for [region]: the sub-switch (when it has sub-views) and the shown panel.
class NetworkSectionBody extends StatelessWidget {
  final NetworkSection section;
  final RegionIndexEntry region;
  final int sub;
  final ValueChanged<int> onSub;

  /// Opens Packets > Live (the Map section's "Live packets").
  final VoidCallback onOpenLive;

  /// The request that opened Packets > List (its filters and window), when a link named some.
  final NetworkRequest? packetsRequest;

  /// The request that opened the Map (a packet to draw, a time), when a link named one.
  final NetworkRequest? mapRequest;
  const NetworkSectionBody(
      {super.key,
      required this.section,
      required this.region,
      required this.sub,
      required this.onSub,
      required this.onOpenLive,
      this.packetsRequest,
      this.mapRequest});

  Widget _panel(BuildContext context, AppState s) {
    final r = region;
    switch (section) {
      case NetworkSection.now:
        return sub == 0
            ? AnalyzePanel(key: const Key('network-now-findings'), baseUrl: r.url, regionSlug: r.slug, regionName: r.name, timezone: s.viewingTimezone)
            : KeyedSubtree(key: const Key('network-now-overview'), child: buildOverviewPanel(r.url, r.slug));
      case NetworkSection.packets:
        return sub == 0
            ? KeyedSubtree(
                key: const Key('network-packets-list'),
                child: PacketListView(key: ValueKey(packetsRequest), baseUrl: r.url, regionSlug: r.slug, request: packetsRequest))
            : LivePanel(key: const Key('network-packets-live'), baseUrl: r.url, regionSlug: r.slug);
      case NetworkSection.nodes:
        return KeyedSubtree(key: Key(sub == 0 ? 'network-nodes-directory' : 'network-nodes-observers'), child: NetworkNodesSection(region: r, sub: sub, onSub: onSub));
      case NetworkSection.map:
        return NetworkLiveMap(key: ValueKey('network-live-map-${mapRequest?.packetHash}'), region: r, request: mapRequest);
      case NetworkSection.insights:
        return _InsightsList(region: r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    // Nodes draws its own Nodes | Observers switch (AZ-3.4).
    final hasSubs = networkSubViews.containsKey(section) && section != NetworkSection.nodes;
    return Column(
      key: Key('network-section-body-${section.name}'),
      children: [
        if (section == NetworkSection.now) NetworkSummaryLine(key: ValueKey('network-summary-${region.code}'), baseUrl: region.url),
        if (hasSubs) NetworkSubSwitch(section: section, selected: sub, onChanged: onSub),
        Expanded(child: _panel(context, s)),
      ],
    );
  }
}

class _InsightsList extends StatelessWidget {
  final RegionIndexEntry region;
  const _InsightsList({required this.region});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return ListView(
      key: const Key('network-insights-list'),
      children: [
        for (final e in insightEntries)
          ListTile(
            key: Key('insight-${e.id}'),
            leading: Icon(e.icon),
            title: Text(e.title),
            subtitle: Text(e.subtitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openInsight(context, e, s, region),
          ),
      ],
    );
  }
}
