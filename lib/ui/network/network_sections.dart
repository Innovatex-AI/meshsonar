// The Network sections (build 71, "the site in the app"): ONE horizontally scrolling strip under the header,
//   Home · Packets · Live · Nodes · Channels · Observers · Analytics · Tools
// and the body of the shown section. No second bottom bar.
//   Home      : Findings | Overview (the old "Now"; the only section with a sub-switch)
//   Packets   : /v1/packets with filters, My radio, Decode a packet (AZ-3.2)
//   Live      : the live packet map with replay (AZ-3.3, lib/ui/network/live/live_map_view.dart; the old "Map")
//   Nodes     : the node directory, every role (AZ-3.4)
//   Channels  : lib/ui/network/channels/channels_section.dart (stream C)
//   Observers : the observer list (was a Nodes sub-view)
//   Analytics : the site's analytics tabs, lib/ui/network/analytics/analytics_section.dart (stream D)
//   Tools     : lib/ui/network/tools/tools_section.dart (stream D)
// "All regions" (the region switcher's entry) shows only the sections that need no region (networkHubSections), on the
// hub: Home there is the network summary, the global search and the busiest regions (a tap opens that region's Live).
// Only the shown section is built, so hidden panels never poll or hold a live stream (battery rules).
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_lookup.dart';
import '../../core/v1/busy_regions_api.dart';
import '../../core/v1/network_api.dart';
import '../app.dart';
import '../region/analyze_panel.dart';
import '../region/region_panels.dart';
import '../region/regions_screen.dart';
import 'analytics/analytics_section.dart';
import 'channels/channels_section.dart';
import 'live/live_map_view.dart';
import 'network_header.dart';
import 'network_search.dart';
import 'nodes/nodes_section.dart';
import 'packets/packet_list_view.dart';
import 'tools/tools_section.dart';

/// The sub-views of a section that has more than one (labels in display order). Only Home has any since build 71.
const Map<NetworkSection, List<String>> networkSubViews = {
  NetworkSection.home: ['Findings', 'Overview'],
};

/// The section strip: one line of section names that scrolls sideways, the shown one underlined. 44 pt tall (each
/// name is a full-height target); the labels grow only a little with the text size so the line stays one line.
class NetworkSectionStrip extends StatefulWidget {
  final List<NetworkSection> sections;
  final NetworkSection selected;
  final ValueChanged<NetworkSection> onChanged;
  const NetworkSectionStrip({super.key, this.sections = NetworkSection.values, required this.selected, required this.onChanged});

  static const double height = 44;

  @override
  State<NetworkSectionStrip> createState() => _NetworkSectionStripState();
}

class _NetworkSectionStripState extends State<NetworkSectionStrip> {
  final Map<NetworkSection, GlobalKey> _keys = {for (final s in NetworkSection.values) s: GlobalKey()};

  @override
  void initState() {
    super.initState();
    _reveal(animate: false);
  }

  @override
  void didUpdateWidget(NetworkSectionStrip old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal(animate: true);
  }

  /// Scrolls the shown section's name into view (a link or another screen may have picked one off the edge).
  void _reveal({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _keys[widget.selected]?.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, alignment: 0.5, duration: animate ? const Duration(milliseconds: 200) : Duration.zero);
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final c = t.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: c.outlineVariant.withValues(alpha: 0.5), width: 0.5))),
      child: SizedBox(
        height: NetworkSectionStrip.height,
        width: double.infinity,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3)),
          child: Semantics(
            container: true,
            label: 'Network sections',
            child: SingleChildScrollView(
              key: const Key('network-sections'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(children: [
                for (final s in widget.sections)
                  Semantics(
                    key: _keys[s],
                    button: true,
                    selected: s == widget.selected,
                    child: InkWell(
                      onTap: () => widget.onChanged(s),
                      child: Container(
                        height: NetworkSectionStrip.height,
                        constraints: const BoxConstraints(minWidth: 44),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          border: Border(bottom: BorderSide(color: s == widget.selected ? c.primary : Colors.transparent, width: 2)),
                        ),
                        child: Text(
                          s.label,
                          key: Key('network-section-${s.name}'),
                          maxLines: 1,
                          softWrap: false,
                          style: t.textTheme.labelLarge?.copyWith(
                            color: s == widget.selected ? c.primary : c.onSurfaceVariant,
                            fontWeight: s == widget.selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// The small sub-view switch at the top of a section (Findings | Overview).
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

/// What a link asked a section to open straight away (a channel, an analytics tab, a tool with its argument).
@immutable
class NetworkSectionTarget {
  final String? channelId, analyticsTab, tool, toolArg;
  const NetworkSectionTarget({this.channelId, this.analyticsTab, this.tool, this.toolArg});
  static const none = NetworkSectionTarget();
}

/// A section's body for [region]: the sub-switch (Home) and the shown panel.
class NetworkSectionBody extends StatelessWidget {
  final NetworkSection section;
  final RegionIndexEntry region;
  final int sub;
  final ValueChanged<int> onSub;

  /// The request that opened Packets (its filters and window), when a link named some.
  final NetworkRequest? packetsRequest;

  /// The request that opened Live (a packet to draw, a time), when a link named one.
  final NetworkRequest? mapRequest;
  final NetworkSectionTarget target;
  const NetworkSectionBody(
      {super.key,
      required this.section,
      required this.region,
      required this.sub,
      required this.onSub,
      this.packetsRequest,
      this.mapRequest,
      this.target = NetworkSectionTarget.none});

  Widget _panel(BuildContext context, AppState s) {
    final r = region;
    switch (section) {
      case NetworkSection.home:
        return sub == 0
            ? AnalyzePanel(key: const Key('network-now-findings'), baseUrl: r.url, regionSlug: r.slug, regionName: r.name, timezone: s.viewingTimezone)
            : KeyedSubtree(key: const Key('network-now-overview'), child: buildOverviewPanel(r.url, r.slug));
      case NetworkSection.packets:
        return KeyedSubtree(
            key: const Key('network-packets-list'),
            child: PacketListView(key: ValueKey(packetsRequest), baseUrl: r.url, regionSlug: r.slug, request: packetsRequest));
      case NetworkSection.live:
        return NetworkLiveMap(key: ValueKey('network-live-map-${mapRequest?.packetHash}'), region: r, request: mapRequest);
      case NetworkSection.nodes:
        return KeyedSubtree(
            key: const Key('network-nodes-directory'), child: NodeDirectoryView(key: ValueKey('nodes-dir-${r.code}'), baseUrl: r.url, regionSlug: r.slug));
      case NetworkSection.observers:
        return KeyedSubtree(
            key: const Key('network-observers'), child: ObserverListView(key: ValueKey('nodes-obs-${r.code}'), baseUrl: r.url, regionSlug: r.slug));
      case NetworkSection.channels:
      case NetworkSection.analytics:
      case NetworkSection.tools:
        return networkSiteSection(section, baseUrl: r.url, regionSlug: r.slug, target: target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return Column(
      key: Key('network-section-body-${section.name}'),
      children: [
        if (section == NetworkSection.home) NetworkSummaryLine(key: ValueKey('network-summary-${region.code}'), baseUrl: region.url),
        if (networkSubViews.containsKey(section)) NetworkSubSwitch(section: section, selected: sub, onChanged: onSub),
        Expanded(child: _panel(context, s)),
      ],
    );
  }
}

/// Channels, Analytics or Tools for a host: the region's ([regionSlug] set) or the hub's (null, "All regions").
/// Keyed by its target, so a new link reopens the section at what it names.
Widget networkSiteSection(NetworkSection section, {required String baseUrl, required String? regionSlug, NetworkSectionTarget target = NetworkSectionTarget.none}) =>
    switch (section) {
      NetworkSection.channels =>
        ChannelsSection(key: ValueKey('network-channels-$baseUrl-${target.channelId}'), baseUrl: baseUrl, regionSlug: regionSlug, initialChannelId: target.channelId),
      NetworkSection.analytics =>
        AnalyticsSection(key: ValueKey('network-analytics-$baseUrl-${target.analyticsTab}'), baseUrl: baseUrl, regionSlug: regionSlug, initialTab: target.analyticsTab),
      _ => ToolsSection(
          key: ValueKey('network-tools-$baseUrl-${target.tool}-${target.toolArg}'),
          baseUrl: baseUrl,
          regionSlug: regionSlug,
          initialTool: target.tool,
          initialArg: target.toolArg),
    };

/// "All regions": a section's body on the hub. Home is the network summary, the global search and the busiest
/// regions; Channels, Analytics and Tools are the same sections with no region.
class NetworkAllRegionsBody extends StatelessWidget {
  final NetworkSection section;
  final String hubUrl;

  /// The region the app is viewing (the "Back to" row); null when none is known yet.
  final RegionIndexEntry? viewed;

  /// Leaves "All regions" for the viewed region.
  final VoidCallback onBack;

  /// Opens a region's Live section (a busiest-regions row), by slug.
  final ValueChanged<String> onOpenRegion;
  final NetworkSectionTarget target;
  const NetworkAllRegionsBody(
      {super.key,
      required this.section,
      required this.hubUrl,
      required this.viewed,
      required this.onBack,
      required this.onOpenRegion,
      this.target = NetworkSectionTarget.none});

  @override
  Widget build(BuildContext context) {
    if (section != NetworkSection.home) {
      return KeyedSubtree(key: Key('network-section-body-${section.name}'), child: networkSiteSection(section, baseUrl: hubUrl, regionSlug: null, target: target));
    }
    final t = Theme.of(context);
    return ListView(
      key: const Key('network-all-regions'),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        NetworkSummaryLine(key: const ValueKey('network-summary-all'), baseUrl: hubUrl),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
          child: NetworkSearchField(key: const ValueKey('network-search-all'), region: null, hubUrl: hubUrl),
        ),
        if (viewed != null)
          ListTile(
            key: const Key('all-regions-back'),
            leading: const Icon(Icons.arrow_back),
            title: Text('Back to ${viewed!.name}', maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(viewed!.code),
            onTap: onBack,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Semantics(header: true, child: Text('Busiest regions, last 10 minutes', style: t.textTheme.titleSmall)),
        ),
        BusiestRegions(hubUrl: hubUrl, onOpen: onOpenRegion),
        const Divider(height: 24),
        ListTile(
          key: const Key('all-regions-every-region'),
          leading: const Icon(Icons.public),
          title: const Text('Every region'),
          subtitle: const Text('Compare every region and switch'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RegionsScreen()))),
        ),
      ],
    );
  }
}

/// The busiest regions of the last 10 minutes (`GET /v1/regions/busy` on the hub). Loads when shown and on Retry; no
/// polling. A row opens that region's Live section.
class BusiestRegions extends StatefulWidget {
  final String hubUrl;
  final ValueChanged<String> onOpen;
  final int limit;
  const BusiestRegions({super.key, required this.hubUrl, required this.onOpen, this.limit = 20});

  @override
  State<BusiestRegions> createState() => _BusiestRegionsState();
}

class _BusiestRegionsState extends State<BusiestRegions> {
  late Future<NetworkRead<List<BusyRegion>>> _f;

  @override
  void initState() {
    super.initState();
    _f = fetchBusyRegions(widget.hubUrl, limit: widget.limit);
  }

  @override
  void didUpdateWidget(BusiestRegions old) {
    super.didUpdateWidget(old);
    if (old.hubUrl != widget.hubUrl) _f = fetchBusyRegions(widget.hubUrl, limit: widget.limit);
  }

  void _retry() => setState(() => _f = fetchBusyRegions(widget.hubUrl, limit: widget.limit));

  static String _rate(double perMin) => perMin >= 10 ? perMin.round().toString() : perMin.toStringAsFixed(1);

  Widget _note(BuildContext context, Key key, String text, {bool retry = false}) {
    final t = Theme.of(context);
    return Padding(
      key: key,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(text, style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (retry) Align(alignment: Alignment.centerLeft, child: TextButton(key: const Key('busy-regions-retry'), onPressed: _retry, child: const Text('Try again'))),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<NetworkRead<List<BusyRegion>>>(
        future: _f,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              key: Key('busy-regions-loading'),
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          final e = snap.error;
          if (e != null) {
            if (e is V1NotLive) {
              return _note(context, const Key('busy-regions-not-live'), 'This server does not list the busiest regions yet.');
            }
            if (e is V1Error && e.offline) {
              return _note(context, const Key('busy-regions-offline'), 'You are offline. The busiest regions load when the phone is online.', retry: true);
            }
            return _note(context, const Key('busy-regions-error'), e is V1Error ? e.message : 'The busiest regions did not load.', retry: true);
          }
          final read = snap.data!;
          if (read.data.isEmpty) {
            return _note(context, const Key('busy-regions-empty'), 'No region has sent packets in the last 10 minutes.', retry: true);
          }
          final t = Theme.of(context);
          return Column(key: const Key('busy-regions'), children: [
            if (read.offlineAsOf != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(asOfLabel(read.offlineAsOf!, DateTime.now().toUtc(), offline: true),
                      style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
                ),
              ),
            for (final r in read.data)
              ListTile(
                key: Key('busy-region-${r.slug}'),
                title: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${r.code} · ${_rate(r.packetsPerMin)} packets/min'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => widget.onOpen(r.slug),
              ),
          ]);
        },
      );
}
