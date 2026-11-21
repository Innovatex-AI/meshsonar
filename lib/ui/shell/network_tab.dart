// The Network tab (build 71: the site in the app; AZ-3.1; the Analyze tab until build 71). One header line (region name
// that opens the region switcher, pulse chip, search, one overflow menu with Share link and Export region report:
// lib/ui/network/network_header.dart), then ONE horizontally scrolling section strip, Live · Packets · Nodes ·
// Channels · Observers · Analytics · Tools (lib/ui/network/network_sections.dart), then the shown section. The tab opens
// on Live (build 72: the Home section is gone; its Findings and Region overview are the first rows of Analytics). There
// is no second bottom bar: the only bar at the bottom is the app's tab bar.
//
// "All regions" (the switcher's entry; ShellController.networkAllRegions, session only): the whole network on the hub
// with the sections that need no region, Regions · Channels · Analytics · Tools. Regions has the network summary, the
// global search and the busiest regions; a region picked there (or in the switcher) becomes the viewed, remembered region.
//
// Opening it from anywhere: ShellScope.openNetwork(NetworkRequest...) (a deep link, a node or packet elsewhere in the
// app). The request is taken here: the region switches when it names another one, the section is picked, and a node /
// observer / packet opens its page; a channel, an analytics tab or a tool is handed to its section.
//
// Shell states: loading (the region list has never loaded), offline (it never loaded and the server cannot be reached),
// error (it never loaded and the server answered with an error), empty (no region to show: a prompt to choose one).
// Each panel keeps its own loading / offline ("Offline - as of") / error states inside a section.
//
// Website twins (analyzer-api-contract.md web routes): Live = `/live` (a packet's path: `/map?panel=live&packet=&t=`;
// the region home `/` and `/pulse` open Live too, `/pulse` with the pulse sheet), Packets = `/packets` (`/packets/:hash`),
// Nodes = `/nodes` (`/nodes/:key`), Channels = `/channels` (`/channels/:id`), Observers = `/observers`
// (`/observers/:id`), Analytics = `/analytics/<slug>`, Tools = `/tools/*`, `/scope-audit`, `/observers/compare`, `/status`.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/app_state.dart';
import '../../core/network_request.dart' show networkHubSections, networkRegionSections;
import '../../core/region_lookup.dart';
import '../app.dart';
import '../design/app_surfaces.dart' show showAppToast;
import '../design/app_symbols.dart';
import '../design/state_views.dart';
import '../location_status.dart';
import '../network/network_header.dart';
import '../network/network_search.dart';
import '../network/network_share.dart';
import '../network/network_sections.dart';
import '../network/nodes/node_routes.dart';
import '../network/packets/packet_detail_screen.dart';
import '../region/region_hub_screen.dart' show MachineDerivedNote;
import '../region/region_report_export_sheet.dart';
import '../region/region_switch_sheet.dart' show switchViewedRegion;
import '../region/region_switcher.dart';

class NetworkTab extends StatefulWidget {
  const NetworkTab({super.key});
  @override
  State<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<NetworkTab> {
  /// The last link into Packets (its filters and window); the list is rebuilt from it.
  NetworkRequest? _packetsRequest;

  /// The last link into Live (a packet to draw, a time).
  NetworkRequest? _mapRequest;

  /// What the last link asked Channels / Analytics / Tools to open; cleared when the person picks a section by hand.
  NetworkSectionTarget _target = NetworkSectionTarget.none;
  ShellController? _shell;

  /// Without a shell above (a test that pumps this tab alone): the section and "All regions" live here.
  NetworkSection _localSection = NetworkSection.live;
  bool _localAll = false;

  /// The manual region pick seen when "All regions" was entered: a new pick (the switcher) leaves "All regions".
  bool _wasAll = false;
  String? _manualAtAll;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.maybeOf(context);
    _shell = shell;
    final pending = shell != null && shell.tab == AppTab.network ? shell.takePendingNetwork() : null;
    if (pending != null) _take(pending);
    final manual = AppScope.of(context).settings.regionManual;
    if (_all && !_wasAll) _manualAtAll = manual;
    if (_all && _wasAll && manual != _manualAtAll) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _setAll(false);
      });
    }
    _wasAll = _all;
  }

  NetworkSection get _section {
    final s = _shell?.networkSection ?? _localSection;
    if (_all) return networkHubSections.contains(s) ? s : NetworkSection.regions;
    // Regions exists only in All regions; a region opens on Live.
    return s == NetworkSection.regions ? NetworkSection.live : s;
  }

  bool get _all => _shell?.networkAllRegions ?? _localAll;

  void _setAll(bool v) {
    if (_shell != null) {
      _shell!.setNetworkAllRegions(v);
    } else {
      setState(() {
        _localAll = v;
        if (v && !networkHubSections.contains(_localSection)) _localSection = NetworkSection.regions;
        if (!v && _localSection == NetworkSection.regions) _localSection = NetworkSection.live;
      });
    }
  }

  /// The person picked a section on the strip: what a link asked that section to open no longer applies.
  void _select(NetworkSection s) {
    _target = NetworkSectionTarget.none;
    if (_shell != null) {
      if (s == _shell!.networkSection) {
        setState(() {});
      } else {
        _shell!.setNetworkSection(s);
      }
    } else {
      setState(() => _localSection = s);
    }
  }

  /// Opens [r] in this tab: through the shell when there is one (it also switches to this tab).
  void _open(NetworkRequest r) {
    if (_shell != null) {
      _shell!.openNetwork(r);
      return;
    }
    setState(() {
      _localSection = r.section;
      if (r.region != null || !networkHubSections.contains(r.section)) _localAll = false;
      _take(r);
    });
  }

  /// Takes a request: what its section should show now (no setState: may run while building), then, after the
  /// frame, the region it names and the page of the thing it names.
  void _take(NetworkRequest r) {
    if (r.section == NetworkSection.live) _mapRequest = r.packetHash == null ? null : r;
    if (r.section == NetworkSection.packets) {
      final isList = r.packetHash == null || r.toWebUri().path == '/packets';
      if (isList) _packetsRequest = r;
    }
    _target = NetworkSectionTarget(channelId: r.channelId, analyticsTab: r.analyticsTab, tool: r.tool, toolArg: r.toolArg);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_apply(r));
    });
  }

  Future<void> _apply(NetworkRequest r) async {
    final s = AppScope.read(context);
    if (_all) {
      // "All regions" is still on only for a hub section with no region: nothing to switch, no region page to open.
      if (r.pulse) await openPulseSheet(context, s.settings.serverUrl);
      return;
    }
    var region = s.viewingRegion;
    if (r.region != null && r.region != region?.slug) {
      RegionIndexEntry? target;
      for (final e in s.regionIndex) {
        if (e.slug == r.region) target = e;
      }
      if (target == null) {
        showAppToast(context, 'That link is for a region this app does not know yet (${r.region!.toUpperCase()}). Showing ${region?.code ?? 'your region'}.');
      } else {
        // The app's one switch: saved as the manual pick, so the region is remembered.
        await switchViewedRegion(s, target);
        region = target;
        if (!mounted) return;
      }
    }
    if (!mounted) return;
    final reg = region;
    if (reg == null) return;
    final nav = Navigator.of(context);
    if (r.packetHash != null && r.section == NetworkSection.packets && r.toWebUri().path != '/packets') {
      unawaited(nav.push(MaterialPageRoute<void>(builder: (_) => NetworkPacketScreen(baseUrl: reg.url, regionSlug: reg.slug, hash: r.packetHash!))));
    } else if (r.nodeKey != null && r.section == NetworkSection.nodes) {
      openNetworkNode(context, baseUrl: reg.url, regionSlug: reg.slug, nodeKey: r.nodeKey!);
    } else if (r.observerId != null && r.section == NetworkSection.observers) {
      openNetworkObserver(context, baseUrl: reg.url, regionSlug: reg.slug, observerId: r.observerId!);
    } else if (r.pulse) {
      await openPulseSheet(context, reg.url);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final all = _all;
    final region = s.viewingRegion;
    final hub = s.settings.serverUrl;
    final section = _section;
    final ready = all || region != null;
    return Scaffold(
      key: const Key('network-tab'),
      appBar: AppBar(
        automaticallyImplyLeading: false,
        titleSpacing: 0,
        toolbarHeight: NetworkHeaderBar.height,
        title: NetworkHeaderBar(
          title: all ? 'All regions' : (region?.name ?? 'Network'),
          pulseBaseUrl: all ? hub : region?.url,
          onRegion: () => unawaited(showRegionSwitcher(context)),
          onSearch: !ready ? null : () => unawaited(openNetworkSearch(context, all ? null : region, hubUrl: hub)),
          onShare: !ready
              ? null
              : () => unawaited(shareNetworkLink(context, NetworkRequest.section(section, region: all ? null : region!.slug),
                  subject: '${all ? 'The MeshCore network' : region!.name} on MeshSonar')),
          onExport: all || region == null ? null : () => showRegionReportExport(context, baseUrl: region.url, regionSlug: region.slug),
        ),
        bottom: !ready
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(NetworkSectionStrip.height),
                child: NetworkSectionStrip(
                  sections: all ? networkHubSections : networkRegionSections,
                  selected: section,
                  onChanged: _select,
                ),
              ),
      ),
      body: all
          ? NetworkAllRegionsBody(
              key: ValueKey('network-hub-${section.name}'),
              section: section,
              hubUrl: hub,
              viewed: region,
              target: _target,
              onBack: () => _setAll(false),
              onOpenRegion: (slug) => _open(NetworkRequest.section(NetworkSection.live, region: slug)),
            )
          : region == null
              ? _shellState(context, s)
              : Column(
                  children: [
                    if (s.locationNote != null)
                      Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: LocationNoteBanner(state: s)),
                    if (region.machineDerived) MachineDerivedNote(regionName: region.name),
                    Expanded(
                      // Keyed by region: switching region rebuilds the section against the new region host.
                      child: NetworkSectionBody(
                        key: ValueKey('network-${region.code}-${section.name}'),
                        section: section,
                        region: region,
                        packetsRequest: _packetsRequest,
                        mapRequest: _mapRequest,
                        target: _target,
                      ),
                    ),
                  ],
                ),
    );
  }

  /// No region to show: never a blank. The region list is loading, could not load, or is empty (choose a region).
  Widget _shellState(BuildContext context, AppState s) {
    if (!s.regionIndexLoaded) {
      if (s.regionIndexOffline) {
        return AppEmptyView(
          key: const Key('network-offline'),
          symbol: AppSymbols.wifi,
          title: 'You are offline',
          message: 'The region list loads the first time the phone is online, and is remembered after that.',
          actionLabel: 'Try again',
          onAction: () => unawaited(s.refreshRegionIndex()),
        );
      }
      if (s.regionIndexStale) {
        return AppErrorView(
          key: const Key('network-error'),
          title: 'The region list did not load',
          message: 'The server answered with an error. Try again in a moment.',
          onRetry: () => unawaited(s.refreshRegionIndex()),
        );
      }
      return AppLoadingView(
        key: const Key('network-loading'),
        label: 'Loading regions',
        onRetry: () => unawaited(s.refreshRegionIndex()),
      );
    }
    return AppEmptyView(
      key: const Key('network-empty'),
      symbol: AppSymbols.globe,
      title: 'No region to show yet',
      message: 'Pick a region to see its network: packets, live map, nodes, channels and analytics.',
      actionLabel: 'Choose a region',
      onAction: () => unawaited(showRegionSwitcher(context)),
    );
  }
}
