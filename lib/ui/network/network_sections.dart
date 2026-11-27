// The Network sections (build 71, "the site in the app"; build 72: Live first, no Home): ONE horizontally scrolling
// strip under the header,
//   Live · Packets · Nodes · Channels · Observers · Analytics · Tools
// and the body of the shown section. No second bottom bar.
//   Live      : the live packet map with replay (AZ-3.3, lib/ui/network/live/live_map_view.dart). The tab opens here.
//   Packets   : /v1/packets with filters, My radio, Decode a packet (AZ-3.2)
//   Nodes     : the node directory, every role (AZ-3.4)
//   Channels  : lib/ui/network/channels/channels_section.dart
//   Observers : the observer list
//   Analytics : Findings and Region overview (native; the Home section until build 72), then the site's analytics tabs
//               (lib/ui/network/analytics/analytics_section.dart)
//   Tools     : lib/ui/network/tools/tools_section.dart
// "All regions" (the region switcher's entry) shows the sections that need no region (networkHubSections), on the hub:
//   Regions · Channels · Analytics · Tools
// Regions is the network summary, the global search and the busiest regions (a tap opens that region's Live).
// Only the shown section is built, so hidden panels never poll or hold a live stream (battery rules).
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/network_request.dart' show analyticsFindingsSlug, analyticsRegionOverviewSlug, networkRegionSections;
import '../../core/region_cache.dart' show asOfLabel;
import '../../core/region_lookup.dart';
import '../../core/v1/busy_regions_api.dart';
import '../../core/v1/network_api.dart';
import '../app.dart';
import '../design/app_haptics.dart';
import '../region/analyze_panel.dart';
import '../region/region_panels.dart';
import '../region/regions_screen.dart';
import 'analytics/analytics_section.dart';
import 'analytics/my_repeaters_panel.dart';
import 'channels/channels_section.dart';
import 'live/live_map_view.dart';
import 'network_header.dart';
import 'network_search.dart';
import 'nodes/nodes_section.dart';
import 'packets/packet_list_view.dart';
import 'tools/tools_section.dart';

/// The section strip: one line of section names that scrolls sideways. The shown one is a filled pill (build 76: obvious
/// at a glance, in a car mount), and an edge fades wherever more names wait off screen, so the strip reads as scrollable.
/// 44 pt tall (each name is a full-height target); the labels grow only a little with the text size so the line stays
/// one line. A pick gives a selection tick (haptic).
class NetworkSectionStrip extends StatefulWidget {
  final List<NetworkSection> sections;
  final NetworkSection selected;
  final ValueChanged<NetworkSection> onChanged;
  const NetworkSectionStrip({super.key, this.sections = networkRegionSections, required this.selected, required this.onChanged});

  static const double height = 44;

  /// What each section is, in a few plain words (VoiceOver hint and the long-press tooltip).
  static String hintOf(NetworkSection s) => switch (s) {
        NetworkSection.live => 'Live map of radio traffic',
        NetworkSection.packets => 'Every radio message heard',
        NetworkSection.nodes => 'Radios on the network',
        NetworkSection.channels => 'Public group chats',
        NetworkSection.observers => 'Stations that listen and report',
        NetworkSection.analytics => 'Charts and findings',
        NetworkSection.tools => 'Look-ups and radio tools',
        NetworkSection.regions => 'The whole network',
      };

  @override
  State<NetworkSectionStrip> createState() => _NetworkSectionStripState();
}

class _NetworkSectionStripState extends State<NetworkSectionStrip> {
  final Map<NetworkSection, GlobalKey> _keys = {for (final s in NetworkSection.values) s: GlobalKey()};
  final ScrollController _scroll = ScrollController();

  /// (more names to the left, more names to the right).
  final ValueNotifier<(bool, bool)> _more = ValueNotifier((false, false));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_edges);
    _reveal(animate: false);
  }

  @override
  void didUpdateWidget(NetworkSectionStrip old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected) _reveal(animate: true);
    if (old.sections != widget.sections) WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
  }

  @override
  void dispose() {
    _scroll.dispose();
    _more.dispose();
    super.dispose();
  }

  void _edges() {
    if (!mounted || !_scroll.hasClients) return;
    final p = _scroll.position;
    if (!p.hasContentDimensions) return;
    _more.value = (p.pixels > p.minScrollExtent + 4, p.pixels < p.maxScrollExtent - 4);
  }

  /// Scrolls the shown section's name into view (a link or another screen may have picked one off the edge).
  void _reveal({required bool animate}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _edges();
      final ctx = _keys[widget.selected]?.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(ctx, alignment: 0.5, duration: animate ? const Duration(milliseconds: 200) : Duration.zero);
    });
  }

  /// The edge where more names wait: the arrow sits on a solid plate of the background ([_edgePlate] wide) and the
  /// names fade out before they reach it, so the arrow is never drawn over a word (Round 2 N-V2).
  static const double _edgePlate = 20, _edgeFade = 18;

  Widget _fade(Color surface, {required bool left}) => Positioned(
        left: left ? 0 : null,
        right: left ? null : 0,
        top: 0,
        bottom: 1,
        width: _edgePlate + _edgeFade,
        child: IgnorePointer(
          child: DecoratedBox(
            key: Key(left ? 'network-sections-more-left' : 'network-sections-more-right'),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: left ? Alignment.centerLeft : Alignment.centerRight,
                end: left ? Alignment.centerRight : Alignment.centerLeft,
                colors: [surface, surface, surface.withValues(alpha: 0)],
                stops: const [0, _edgePlate / (_edgePlate + _edgeFade), 1],
              ),
            ),
            child: Align(
              alignment: left ? Alignment.centerLeft : Alignment.centerRight,
              child: SizedBox(width: _edgePlate, child: Icon(left ? Icons.chevron_left : Icons.chevron_right, size: 16)),
            ),
          ),
        ),
      );

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
            child: Stack(children: [
              Positioned.fill(
                child: NotificationListener<ScrollMetricsNotification>(
                  onNotification: (_) {
                    WidgetsBinding.instance.addPostFrameCallback((_) => _edges());
                    return false;
                  },
                  child: SingleChildScrollView(
                    key: const Key('network-sections'),
                    controller: _scroll,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(children: [
                      for (final s in widget.sections)
                        Semantics(
                          key: _keys[s],
                          button: true,
                          selected: s == widget.selected,
                          hint: NetworkSectionStrip.hintOf(s),
                          child: Tooltip(
                            message: NetworkSectionStrip.hintOf(s),
                            excludeFromSemantics: true,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(18),
                              onTap: () {
                                if (s != widget.selected) unawaited(AppHaptics.selection());
                                widget.onChanged(s);
                              },
                              // The whole 44 pt of height is the target; the pill inside it is 34 pt.
                              child: Container(
                                height: NetworkSectionStrip.height,
                                constraints: const BoxConstraints(minWidth: 44),
                                padding: const EdgeInsets.symmetric(horizontal: 2),
                                alignment: Alignment.center,
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  height: 34,
                                  padding: const EdgeInsets.symmetric(horizontal: 12),
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    color: s == widget.selected ? c.primaryContainer : Colors.transparent,
                                    borderRadius: BorderRadius.circular(17),
                                  ),
                                  child: Text(
                                    s.label,
                                    key: Key('network-section-${s.name}'),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: t.textTheme.labelLarge?.copyWith(
                                      color: s == widget.selected ? c.onPrimaryContainer : c.onSurfaceVariant,
                                      fontWeight: s == widget.selected ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ]),
                  ),
                ),
              ),
              ValueListenableBuilder<(bool, bool)>(
                valueListenable: _more,
                builder: (context, more, _) => Stack(children: [
                  if (more.$1) _fade(t.scaffoldBackgroundColor, left: true),
                  if (more.$2) _fade(t.scaffoldBackgroundColor, left: false),
                ]),
              ),
            ]),
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

/// A section's body for [region]: the shown panel.
class NetworkSectionBody extends StatelessWidget {
  final NetworkSection section;
  final RegionIndexEntry region;

  /// The request that opened Packets (its filters and window), when a link named some.
  final NetworkRequest? packetsRequest;

  /// The request that opened Live (a packet to draw, a time), when a link named one.
  final NetworkRequest? mapRequest;
  final NetworkSectionTarget target;
  const NetworkSectionBody(
      {super.key, required this.section, required this.region, this.packetsRequest, this.mapRequest, this.target = NetworkSectionTarget.none});

  Widget _panel(BuildContext context, AppState s) {
    final r = region;
    switch (section) {
      case NetworkSection.live:
      case NetworkSection.regions: // hub only; a region shows Live in its place
        // A new packet, or another reception of the same one ("Replay on map"), is a new map.
        return NetworkLiveMap(
            key: ValueKey('network-live-map-${mapRequest?.packetHash}${mapRequest?.observationId == null ? '' : '-${mapRequest!.observationId}'}'), region: r, request: mapRequest);
      case NetworkSection.packets:
        return KeyedSubtree(
            key: const Key('network-packets-list'),
            child: PacketListView(key: ValueKey(packetsRequest), baseUrl: r.url, regionSlug: r.slug, request: packetsRequest));
      case NetworkSection.nodes:
        return KeyedSubtree(
            key: const Key('network-nodes-directory'), child: NodeDirectoryView(key: ValueKey('nodes-dir-${r.code}'), baseUrl: r.url, regionSlug: r.slug));
      case NetworkSection.observers:
        return KeyedSubtree(
            key: const Key('network-observers'), child: ObserverListView(key: ValueKey('nodes-obs-${r.code}'), baseUrl: r.url, regionSlug: r.slug));
      case NetworkSection.channels:
      case NetworkSection.tools:
        return networkSiteSection(section, baseUrl: r.url, regionSlug: r.slug, target: target);
      case NetworkSection.analytics:
        return networkSiteSection(section, baseUrl: r.url, regionSlug: r.slug, target: target, nativeRows: regionAnalyticsRows(r, timezone: s.viewingTimezone));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    return KeyedSubtree(key: Key('network-section-body-${section.name}'), child: _panel(context, s));
  }
}

/// The region's native panels at the top of Analytics (the Network Home section until build 72): Findings ("What
/// changed", "What needs attention") and Region overview.
List<AnalyticsNativeRow> regionAnalyticsRows(RegionIndexEntry r, {required String? timezone}) => [
      AnalyticsNativeRow(
        slug: analyticsFindingsSlug,
        label: 'Findings',
        about: 'What changed and what needs attention in this region',
        builder: (_) => AnalyzePanel(key: const Key('network-findings'), baseUrl: r.url, regionSlug: r.slug, regionName: r.name, timezone: timezone),
      ),
      // The app's one Overview (Round 2 N-U10): the website's Overview row is gone and its link opens this.
      AnalyticsNativeRow(
        slug: analyticsRegionOverviewSlug,
        label: 'Overview',
        about: 'Packets, observers, repeaters and signal at a glance',
        builder: (_) => KeyedSubtree(key: const Key('network-region-overview'), child: buildOverviewPanel(r.url, r.slug)),
      ),
      // Native since build 77 (Round 2 W6): the person's own starred and claimed repeaters.
      AnalyticsNativeRow(
        slug: analyticsMyRepeatersSlug,
        label: 'My Repeaters',
        about: 'The repeaters you starred or claimed in the app',
        builder: (_) => KeyedSubtree(key: const Key('network-my-repeaters'), child: MyRepeatersPanel(baseUrl: r.url, regionSlug: r.slug)),
      ),
    ];

/// Channels, Analytics or Tools for a host: the region's ([regionSlug] set) or the hub's (null, "All regions").
/// Keyed by its target, so a new link reopens the section at what it names.
Widget networkSiteSection(NetworkSection section,
        {required String baseUrl, required String? regionSlug, NetworkSectionTarget target = NetworkSectionTarget.none, List<AnalyticsNativeRow> nativeRows = const []}) =>
    switch (section) {
      NetworkSection.channels =>
        ChannelsSection(key: ValueKey('network-channels-$baseUrl-${target.channelId}'), baseUrl: baseUrl, regionSlug: regionSlug, initialChannelId: target.channelId),
      NetworkSection.analytics =>
        AnalyticsSection(
            key: ValueKey('network-analytics-$baseUrl-${target.analyticsTab}'),
            baseUrl: baseUrl,
            regionSlug: regionSlug,
            initialTab: target.analyticsTab,
            nativeRows: nativeRows),
      _ => ToolsSection(
          key: ValueKey('network-tools-$baseUrl-${target.tool}-${target.toolArg}'),
          baseUrl: baseUrl,
          regionSlug: regionSlug,
          initialTool: target.tool,
          initialArg: target.toolArg),
    };

/// "All regions": a section's body on the hub. Regions is the network summary, the global search and the busiest
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
    if (section != NetworkSection.regions) {
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
            subtitle: const Text('Return to the region you were viewing'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onBack,
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(header: true, child: Text('Busiest regions right now', style: t.textTheme.titleSmall)),
            Text('Radio traffic in the last 10 minutes. Tap a region to open its live map.',
                key: const Key('busy-regions-hint'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          ]),
        ),
        BusiestRegions(hubUrl: hubUrl, onOpen: onOpenRegion),
        const Divider(height: 24),
        ListTile(
          key: const Key('all-regions-every-region'),
          leading: const Icon(Icons.public),
          title: const Text('Every region'),
          subtitle: const Text('The full list, with numbers to compare'),
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

  void _retry() => setState(() {
        _f = fetchBusyRegions(widget.hubUrl, limit: widget.limit);
      });

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
              child: Center(
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 12),
                  Flexible(child: Text('Finding the busiest regions…')),
                ]),
              ),
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
                subtitle: Text('${_rate(r.packetsPerMin)} packets a minute · ${r.code}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => widget.onOpen(r.slug),
              ),
          ]);
        },
      );
}
