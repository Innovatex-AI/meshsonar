// Network > Analytics (build 71, stream D): the website's 17 Analytics tabs as a plain list, same names and order as
// the site's Analytics menu (meshcore-insights src/components/analyzer/analytics/tabs.ts). A row opens the tab's site
// page inside the app ([SitePageView]); `initialTab` (from an `/analytics/<slug>` link) shows that tab in place inside
// the section, with a back arrow to the list.
import 'package:flutter/material.dart';

import '../../radio/inset_list.dart';
import 'site_page_view.dart';

/// One Analytics tab of the site: `/analytics/<slug>`.
class AnalyticsTab {
  final String slug, label;

  /// One plain line: what the tab shows.
  final String about;
  const AnalyticsTab(this.slug, this.label, this.about);

  String get path => '/analytics/$slug';
}

/// Same order as the site. Keep the two lists in step when the site adds a tab.
const List<AnalyticsTab> analyticsTabs = [
  AnalyticsTab('overview', 'Overview', 'Packets, nodes and growth for the region at a glance'),
  AnalyticsTab('rf-signal', 'RF / Signal', 'SNR and RSSI spread, packets over time, noise floor'),
  AnalyticsTab('topology', 'Topology', 'Which repeaters carry the traffic and how they link'),
  AnalyticsTab('channels', 'Channels', 'Channel activity: messages and senders per channel'),
  AnalyticsTab('hash-stats', 'Hash Stats', 'Hash sizes in use and how often prefixes repeat'),
  AnalyticsTab('hash-issues', 'Hash Issues', 'Repeaters whose hash prefixes collide'),
  AnalyticsTab('route-patterns', 'Route Patterns', 'The paths packets take most and hop counts'),
  AnalyticsTab('nodes', 'Nodes', 'Node counts by role and status, busiest nodes'),
  AnalyticsTab('my-repeaters', 'My Repeaters', 'Repeaters starred on the site page; stars are kept in that page'),
  AnalyticsTab('repeater-metrics', 'Repeater Metrics', 'Per repeater: traffic share, relays, quiet ones'),
  AnalyticsTab('distance', 'Distance', 'Link and hop distances, the longest links'),
  AnalyticsTab('neighbor-graph', 'Neighbor Graph', 'Who hears whom, drawn as a graph'),
  AnalyticsTab('rf-health', 'RF Health', 'Noise floor and airtime per observer'),
  AnalyticsTab('clock-health', 'Clock Health', 'Nodes whose clocks are wrong, and by how much'),
  AnalyticsTab('roles', 'Roles', 'Repeaters, rooms, sensors and companions over time'),
  AnalyticsTab('scopes', 'Scopes', 'Region scopes seen on packets and who forwards them'),
  AnalyticsTab('prefix-tool', 'Prefix Tool', 'Find a free hash prefix for a new repeater'),
];

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
  const AnalyticsSection({super.key, required this.baseUrl, required this.regionSlug, this.initialTab});

  @override
  State<AnalyticsSection> createState() => _AnalyticsSectionState();
}

class _AnalyticsSectionState extends State<AnalyticsSection> {
  /// The tab a link opened, shown in place inside the section (no page is pushed over the Network tab, so the section
  /// strip and the tab bar stay usable and a later link to another section is not hidden). Null = the list.
  late AnalyticsTab? _shown = analyticsTabOf(widget.initialTab);

  @override
  void didUpdateWidget(AnalyticsSection old) {
    super.didUpdateWidget(old);
    // A new link shows its tab; an unknown slug or none shows the list.
    if (widget.initialTab != old.initialTab || widget.baseUrl != old.baseUrl) _shown = analyticsTabOf(widget.initialTab);
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
    return ListView(
      key: const Key('analytics-section'),
      padding: const EdgeInsets.only(top: 12, bottom: 24),
      children: [
        InsetGroup(
          header: 'Analytics',
          footer: 'These are the website\'s Analytics pages, shown inside the app. They need a connection.',
          rows: [
            for (final tab in analyticsTabs) InsetRow(key: Key('analytics-tab-${tab.slug}'), title: tab.label, subtitle: tab.about, onTap: () => _open(tab)),
          ],
        ),
      ],
    );
  }
}
