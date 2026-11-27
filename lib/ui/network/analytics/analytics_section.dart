// Network > Analytics (build 71, stream D): the website's 17 Analytics tabs as a plain list, same names and order as
// the site's Analytics menu (meshcore-insights src/components/analyzer/analytics/tabs.ts). A row opens the tab's site
// page inside the app ([SitePageView]); `initialTab` (from an `/analytics/<slug>` link) shows that tab in place inside
// the section, with a back arrow to the list.
// Build 72: the region's native Findings and Region overview panels (the Network Home section until then) are the first
// two rows ([AnalyticsNativeRow], supplied by network_sections.dart) and open in place the same way.
// Build 77 (Round 2 N-U10, W6): one Overview, the native one (the website "Overview" row is listed only on "All
// regions", where there is no native one; an `/analytics/overview` link opens the native page); the website "Prefix
// Tool" row is gone (the app's own Prefix Tool is the one tool, and `/analytics/prefix-tool` links open it); "My
// Repeaters" is native (the website page read stars saved in a browser and was always empty here); "Nodes" and
// "Channels" are "Node counts" and "Channel activity", so they are not mistaken for the Nodes and Channels sections.
import 'package:flutter/material.dart';

import '../../radio/inset_list.dart';
import 'in_place_header.dart';
import 'site_page_view.dart';

/// A native panel listed above the site's tabs (build 72: Findings and Region overview, the Network Home section until
/// then). It opens in place inside the section under the same header as a linked site tab. [slug] is app-internal
/// (`/analytics/<slug>` opens it; the site has no page under it).
class AnalyticsNativeRow {
  final String slug, label, about;
  final WidgetBuilder builder;
  const AnalyticsNativeRow({required this.slug, required this.label, required this.about, required this.builder});
}

/// One Analytics tab of the site: `/analytics/<slug>`.
class AnalyticsTab {
  final String slug, label;

  /// One plain line: what the tab shows.
  final String about;
  const AnalyticsTab(this.slug, this.label, this.about);

  String get path => '/analytics/$slug';
}

/// The website's Analytics pages the app shows, in the site's order. Keep the list in step when the site adds a tab.
/// Not here: the site's Prefix Tool (the app's own tool) and My Repeaters (native, [analyticsMyRepeatersSlug]). The
/// site's Overview is listed on "All regions" only ([analyticsHubOverview]).
const List<AnalyticsTab> analyticsTabs = [
  AnalyticsTab('rf-signal', 'RF / Signal', 'How strong packets arrive, and the background noise'),
  AnalyticsTab('topology', 'Topology', 'Which repeaters carry the traffic and how they link'),
  AnalyticsTab('channels', 'Channel activity', 'Messages and senders per channel'),
  AnalyticsTab('hash-stats', 'Hash Stats', 'How long the short IDs on packets are, how often they repeat'),
  AnalyticsTab('hash-issues', 'Hash Issues', 'Repeaters whose short IDs clash'),
  AnalyticsTab('route-patterns', 'Route Patterns', 'The paths packets take most, and how many hops'),
  AnalyticsTab('nodes', 'Node counts', 'Node counts by role and status, busiest nodes'),
  AnalyticsTab('repeater-metrics', 'Repeater Metrics', 'Each repeater: share of traffic, relays, quiet ones'),
  AnalyticsTab('distance', 'Distance', 'How far links and hops reach, and the longest'),
  AnalyticsTab('neighbor-graph', 'Neighbor Graph', 'Who hears whom, as a drawing'),
  AnalyticsTab('rf-health', 'RF Health', 'Noise and airtime at each observer'),
  AnalyticsTab('clock-health', 'Clock Health', 'Nodes whose clocks are wrong, and by how much'),
  AnalyticsTab('roles', 'Roles', 'Repeaters, rooms, sensors and companions over time'),
  AnalyticsTab('scopes', 'Scopes', 'Region tags on packets and who forwards them'),
];

/// The website's network-wide Overview, listed under "Start here" on "All regions" only (a region has the native one).
const AnalyticsTab analyticsHubOverview = AnalyticsTab('overview', 'Overview', 'Packets, nodes and signal across every region');

/// The app's own My Repeaters page (native, [AnalyticsNativeRow]); `/analytics/my-repeaters` opens it.
const String analyticsMyRepeatersSlug = 'my-repeaters';

/// The native rows that go under "Start here", in this order; any other native row sits in its group below.
const List<String> analyticsStartSlugs = ['findings', 'region-overview'];

/// How the list is shown on the phone (build 76): the pages under four plain headings instead of one long run, so a
/// person can find "signal" or "repeaters" without reading every row. Each site page appears exactly once (test:
/// analytics groups cover every tab); a native slug in a group shows only when its native row is given.
const List<(String header, List<String> slugs)> analyticsGroups = [
  ('Signal and traffic', ['rf-signal', 'rf-health', 'channels', 'distance']),
  ('Repeaters and nodes', ['nodes', analyticsMyRepeatersSlug, 'repeater-metrics', 'roles', 'clock-health']),
  ('Routes and links', ['topology', 'route-patterns', 'neighbor-graph', 'scopes']),
  ('Short IDs (hashes)', ['hash-stats', 'hash-issues']),
];

/// Old links that name a native page by another slug: the site's `/analytics/overview` is the native Overview.
const Map<String, String> analyticsNativeAliases = {'overview': 'region-overview'};

AnalyticsTab? analyticsTabOf(String? slug) {
  if (slug == null) return null;
  final s = slug.trim().toLowerCase();
  for (final t in analyticsTabs) {
    if (t.slug == s) return t;
  }
  return null;
}

class AnalyticsSection extends StatefulWidget {
  final String baseUrl;
  final String? regionSlug;

  /// A tab slug to open straight away (from an `/analytics/<slug>` link); null shows the list.
  final String? initialTab;

  /// Native panels shown as the first rows, in their own group; empty for "All regions".
  final List<AnalyticsNativeRow> nativeRows;
  const AnalyticsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialTab, this.nativeRows = const []});

  @override
  State<AnalyticsSection> createState() => _AnalyticsSectionState();
}

class _AnalyticsSectionState extends State<AnalyticsSection> {
  /// The tab a link opened, shown in place inside the section (no page is pushed over the Network tab, so the section
  /// strip and the tab bar stay usable and a later link to another section is not hidden). Null = the list.
  late AnalyticsTab? _shown = _siteTabOf(widget.initialTab);

  /// The native panel shown in place (a row tapped, or a link to its slug). Null = none.
  late AnalyticsNativeRow? _native = _nativeOf(widget.initialTab);

  AnalyticsNativeRow? _nativeOf(String? slug) {
    final s = slug?.trim().toLowerCase();
    for (final r in widget.nativeRows) {
      if (r.slug == s || r.slug == analyticsNativeAliases[s]) return r;
    }
    return null;
  }

  @override
  void didUpdateWidget(AnalyticsSection old) {
    super.didUpdateWidget(old);
    // A new link shows its tab; an unknown slug or none shows the list.
    if (widget.initialTab != old.initialTab || widget.baseUrl != old.baseUrl) {
      _shown = _siteTabOf(widget.initialTab);
      _native = _nativeOf(widget.initialTab);
    }
  }

  /// The site page a link names, unless a native page answers it (the Overview on a region).
  AnalyticsTab? _siteTabOf(String? slug) {
    if (_nativeOf(slug) != null) return null;
    final s = slug?.trim().toLowerCase();
    if (s == analyticsHubOverview.slug) return analyticsHubOverview;
    return analyticsTabOf(s);
  }

  /// A row tapped in the list opens the tab as its own page.
  void _open(AnalyticsTab tab) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      settings: RouteSettings(name: tab.path),
      builder: (_) => SitePageView(baseUrl: widget.baseUrl, path: tab.path, title: tab.label),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final native = _native;
    if (native != null) {
      return Material(
        key: Key('analytics-native-${native.slug}'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(children: [
          InPlaceHeader(title: native.label, onBack: () => setState(() => _native = null), backLabel: 'Back to Analytics'),
          Expanded(child: native.builder(context)),
        ]),
      );
    }
    final shown = _shown;
    if (shown != null) {
      return SitePageView.inPlace(
        key: ValueKey('analytics-in-place-${widget.baseUrl}-${shown.slug}'),
        baseUrl: widget.baseUrl,
        path: shown.path,
        title: shown.label,
        onClose: () => setState(() => _shown = null),
      );
    }
    InsetRow siteRow(AnalyticsTab tab) => InsetRow(key: Key('analytics-tab-${tab.slug}'), title: tab.label, subtitle: tab.about, onTap: () => _open(tab));
    InsetRow nativeRow(AnalyticsNativeRow r) =>
        InsetRow(key: Key('analytics-tab-${r.slug}'), title: r.label, subtitle: r.about, onTap: () => setState(() => _native = r));
    InsetRow? rowOf(String slug) {
      for (final r in widget.nativeRows) {
        if (r.slug == slug) return nativeRow(r);
      }
      final tab = analyticsTabOf(slug);
      return tab == null ? null : siteRow(tab);
    }

    final start = [
      for (final slug in analyticsStartSlugs) ?(widget.nativeRows.any((r) => r.slug == slug) ? rowOf(slug) : null),
      // A native row the list does not place is shown first, so none is ever lost.
      for (final r in widget.nativeRows)
        if (!analyticsStartSlugs.contains(r.slug) && !analyticsGroups.any((g) => g.$2.contains(r.slug))) nativeRow(r),
      // "All regions" has no native Overview: the website's network-wide one stands in.
      if (!widget.nativeRows.any((r) => r.slug == analyticsNativeAliases[analyticsHubOverview.slug])) siteRow(analyticsHubOverview),
    ];
    // Every row is built (18 short rows), so a row far down can be scrolled to by name.
    return SingleChildScrollView(
      key: const Key('analytics-section'),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InsetGroup(header: 'Start here', rows: start),
        for (final (header, slugs) in analyticsGroups)
          InsetGroup(
            groupKey: Key('analytics-group-${slugs.first}'),
            header: header,
            footer: identical(slugs, analyticsGroups.last.$2) ? 'Website pages shown in the app. They need a connection.' : null,
            rows: [for (final slug in slugs) ?rowOf(slug)],
          ),
      ]),
    );
  }
}
