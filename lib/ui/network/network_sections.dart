// The five Network sections (AZ-3.1): Now, Packets, Nodes, Map, Insights. They re-home the old Analyze > Region area's
// thirteen tabs without changing any panel (each still takes the region host and slug):
//   Now      : Findings (old "Analyze" tab) | Overview
//   Packets  : List (AZ-3.2: /v1/packets with filters, My radio, Decode a packet) | Live (old "Live")
//   Nodes    : Repeaters | Observers
//   Map      : the full map with the network layers (NetworkMapPlaceholder until the live map, AZ-3.3)
//   Insights : Analysis, RF, Growth, Reports, Stats, Silent repeaters, Wardrive share (each opens as its own page)
// Only the shown section and sub-view is built, so hidden panels never poll or hold a live stream (battery rules).
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../app/app_state.dart';
import '../../core/airtime_share.dart';
import '../../core/region_lookup.dart';
import '../app.dart';
import '../design/app_symbols.dart';
import '../map/layers/repeater_map_source.dart' show kRosterLayerId;
import '../map/main_map_focus.dart';
import '../region/analyze_panel.dart';
import '../region/growth_panel.dart';
import '../region/live_screen.dart';
import '../region/packet_analytics_panels.dart';
import '../region/region_panels.dart';
import '../region/rf_panel.dart';
import '../region/stats_panel.dart';
import 'network_header.dart';
import 'packets/packet_list_view.dart';

/// The sub-views of a section that has more than one (labels in display order).
const Map<NetworkSection, List<String>> networkSubViews = {
  NetworkSection.now: ['Findings', 'Overview'],
  NetworkSection.packets: ['List', 'Live'],
  NetworkSection.nodes: ['Repeaters', 'Observers'],
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
  const NetworkSectionBody(
      {super.key, required this.section, required this.region, required this.sub, required this.onSub, required this.onOpenLive, this.packetsRequest});

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
        return sub == 0
            ? KeyedSubtree(key: const Key('network-nodes-repeaters'), child: buildRepeatersPanel(r.url, r.slug))
            : KeyedSubtree(key: const Key('network-nodes-observers'), child: buildObserversPanel(r.url, r.slug));
      case NetworkSection.map:
        return NetworkMapPlaceholder(region: r, onLive: onOpenLive);
      case NetworkSection.insights:
        return _InsightsList(region: r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final hasSubs = networkSubViews.containsKey(section);
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

/// The Map section until the live map with replay (AZ-3.3) is hosted here: it opens the app's full map (the Drive tab)
/// on this region with the network layers on, and points to the live packet feed.
class NetworkMapPlaceholder extends StatelessWidget {
  final RegionIndexEntry region;
  final VoidCallback onLive;
  const NetworkMapPlaceholder({super.key, required this.region, required this.onLive});

  /// The layers the Network map shows: repeaters, observers, links by SNR, estimated positions.
  static const Set<String> networkLayers = {kRosterLayerId, 'observers', 'snrlinks', 'estimated'};

  static LatLng? centreOf(RegionIndexEntry r) {
    final b = r.bbox;
    if (b == null || b.length != 4) return null;
    return LatLng((b[1] + b[3]) / 2, (b[0] + b[2]) / 2);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final centre = centreOf(region);
    return ListView(
      key: const Key('network-map-placeholder'),
      padding: const EdgeInsets.all(16),
      children: [
        Row(children: [
          const AppSymbolIcon(AppSymbols.map, size: 28),
          const SizedBox(width: 12),
          Expanded(child: Text('${region.name} on the map', style: t.textTheme.titleMedium)),
        ]),
        const SizedBox(height: 8),
        Text(
          'The full map shows the repeaters, observers and links of this region, with coverage. A live packet map with '
          'replay will open here in a later update; until then the live feed is under Packets.',
          style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('network-map-open'),
          icon: const Icon(Icons.map_outlined),
          label: const Text('Open the network map'),
          onPressed: () {
            if (centre != null) MainMapFocus.request(centre, 10, showLayers: networkLayers);
            ShellScope.maybeRead(context)?.openDrive();
          },
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('network-map-live'),
          icon: const Icon(Icons.podcasts),
          label: const Text('Live packets'),
          onPressed: onLive,
        ),
      ],
    );
  }
}
