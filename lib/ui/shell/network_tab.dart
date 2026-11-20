// The Network tab (AZ-3.1; the Analyze tab until build 71): the phone home of the network analyzer for the viewed
// region. A region header (name, pulse chip, Export region report, region switcher), then five sections, Now, Packets,
// Nodes, Map, Insights (lib/ui/network/network_sections.dart), switched by a segmented bar that sits at the bottom of
// the screen on phones (thumb reach, one-handed) and under the header on wide screens.
//
// Opening it from anywhere: ShellScope.openNetwork(NetworkRequest...) (a deep link, a node or packet elsewhere in the
// app). The request is taken here: the region switches when it names another one, the section and sub-view are picked,
// and a node / observer / packet opens its page.
//
// Shell states: loading (the region list has never loaded), offline (it never loaded and the server cannot be reached),
// error (it never loaded and the server answered with an error), empty (no region to show). Each panel keeps its own
// loading / offline ("Offline - as of") / error states inside a section.
//
// Website twins (analyzer-api-contract.md web routes): Now = region home `/`, Packets = `/packets` (a packet:
// `/packets/:hash`, Decode a packet: `/tools/decode`), Nodes = `/nodes` (a node: `/nodes/:key`)
// and `/observers` (`/observers/:id`), Map = `/map?panel=live` (a packet's path: `&packet=<hash>&t=<time>`),
// Insights = `/insights?tab=`.
import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../app/app_state.dart';
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
import 'home_shell.dart' show shellRailWidth;

class NetworkTab extends StatefulWidget {
  const NetworkTab({super.key});
  @override
  State<NetworkTab> createState() => _NetworkTabState();
}

class _NetworkTabState extends State<NetworkTab> {
  /// The shown sub-view per section (Findings | Overview, List | Live, Repeaters | Observers).
  final Map<NetworkSection, int> _sub = {};

  /// The last link into Packets > List (its filters and window); the list is rebuilt from it.
  NetworkRequest? _packetsRequest;

  /// The last link into Map (a packet to draw, a time).
  NetworkRequest? _mapRequest;
  ShellController? _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final shell = ShellScope.maybeOf(context);
    _shell = shell;
    final pending = shell != null && shell.tab == AppTab.network ? shell.takePendingNetwork() : null;
    if (pending != null) {
      // The section is already switched (openNetwork); pick the sub-view in this same build, then open the page.
      _pickSub(pending);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_apply(pending));
      });
    }
  }

  NetworkSection get _section => _shell?.networkSection ?? _localSection;
  NetworkSection _localSection = NetworkSection.now;

  void _select(NetworkSection s) {
    if (_shell != null) {
      _shell!.setNetworkSection(s);
    } else {
      setState(() => _localSection = s);
    }
  }

  void _setSub(NetworkSection s, int i) => setState(() => _sub[s] = i);

  /// The sub-view a request asks for (no setState: called while building).
  void _pickSub(NetworkRequest r) {
    if (r.section == NetworkSection.map) _mapRequest = r.packetHash == null ? null : r;
    if (r.section == NetworkSection.nodes) _sub[NetworkSection.nodes] = r.observersView ? 1 : 0;
    if (r.section == NetworkSection.packets) {
      _sub[NetworkSection.packets] = 0;
      final isList = r.packetHash == null || r.toWebUri().path == '/packets';
      if (isList) _packetsRequest = r;
    }
  }

  /// Takes a request after the frame: the region it names, then the page of the thing it names.
  Future<void> _apply(NetworkRequest r) async {
    final s = AppScope.read(context);
    var region = s.viewingRegion;
    if (r.region != null && r.region != region?.slug) {
      RegionIndexEntry? target;
      for (final e in s.regionIndex) {
        if (e.slug == r.region) target = e;
      }
      if (target == null) {
        showAppToast(context, 'That link is for a region this app does not know yet (${r.region!.toUpperCase()}). Showing ${region?.code ?? 'your region'}.');
      } else {
        await switchViewedRegion(s, target);
        region = target;
        if (!mounted) return;
      }
    }
    if (!mounted) return;
    final reg = region;
    if (reg == null || !mounted) return;
    final nav = Navigator.of(context);
    if (r.packetHash != null && r.section == NetworkSection.packets && r.toWebUri().path != '/packets') {
      nav.push(MaterialPageRoute<void>(builder: (_) => NetworkPacketScreen(baseUrl: reg.url, regionSlug: reg.slug, hash: r.packetHash!)));
    } else if (r.nodeKey != null && r.section == NetworkSection.nodes) {
      openNetworkNode(context, baseUrl: reg.url, regionSlug: reg.slug, nodeKey: r.nodeKey!);
    } else if (r.observerId != null && r.section == NetworkSection.nodes) {
      openNetworkObserver(context, baseUrl: reg.url, regionSlug: reg.slug, observerId: r.observerId!);
    } else if (r.section == NetworkSection.insights) {
      final e = insightForTab(r.insightsTab);
      if (e != null) openInsight(context, e, s, reg);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context);
    final region = s.viewingRegion;
    final wide = MediaQuery.sizeOf(context).width >= shellRailWidth;
    final bar = _SectionBar(selected: _section, onChanged: _select, wide: wide);
    return Scaffold(
      key: const Key('network-tab'),
      appBar: AppBar(
        title: Text(region?.name ?? 'Network', key: const Key('region-title'), maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (region != null)
            NetworkShareButton(
              request: NetworkRequest.section(_section, region: region.slug),
              subject: '${region.name} on MeshSonar',
            ),
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
      ),
      body: region == null
          ? _shellState(context, s)
          : Column(
              children: [
                if (s.locationNote != null)
                  Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 0), child: LocationNoteBanner(state: s)),
                if (region.machineDerived) MachineDerivedNote(regionName: region.name),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                  child: NetworkSearchField(key: ValueKey('network-search-${region.code}'), region: region),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: PulseChip(key: ValueKey('network-pulse-${region.code}'), baseUrl: region.url),
                  ),
                ),
                if (wide) bar,
                Expanded(
                  // Keyed by region: switching region rebuilds the section against the new region host.
                  child: NetworkSectionBody(
                    key: ValueKey('network-${region.code}-${_section.name}'),
                    section: _section,
                    region: region,
                    sub: _sub[_section] ?? 0,
                    onSub: (i) => _setSub(_section, i),
                    packetsRequest: _packetsRequest,
                    mapRequest: _mapRequest,
                    onOpenLive: () {
                      _select(NetworkSection.packets);
                      _setSub(NetworkSection.packets, 1);
                    },
                  ),
                ),
                if (!wide) bar,
              ],
            ),
    );
  }

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
      message: 'Pick a region to see its network: packets, nodes, findings and insights.',
      actionLabel: 'Choose a region',
      onAction: () => unawaited(showRegionSwitcher(context)),
    );
  }
}

/// The five-section switch. 44 pt tall segments; labels keep their size at every text size (as the Chat segments do).
class _SectionBar extends StatelessWidget {
  final NetworkSection selected;
  final ValueChanged<NetworkSection> onChanged;
  final bool wide;
  const _SectionBar({required this.selected, required this.onChanged, required this.wide});

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.surface,
        border: Border(
          top: wide ? BorderSide.none : BorderSide(color: c.outlineVariant.withValues(alpha: 0.5), width: 0.5),
          bottom: wide ? BorderSide(color: c.outlineVariant.withValues(alpha: 0.5), width: 0.5) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
          child: Semantics(
            container: true,
            label: 'Network sections',
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<NetworkSection>(
                key: const Key('network-sections'),
                groupValue: selected,
                thumbColor: c.surfaceContainerHighest,
                backgroundColor: c.onSurface.withValues(alpha: 0.10),
                padding: const EdgeInsets.all(2),
                children: {
                  for (final s in NetworkSection.values)
                    s: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 40),
                      child: Center(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(s.label, key: Key('network-section-${s.name}'), maxLines: 1, softWrap: false),
                        ),
                      ),
                    ),
                },
                onValueChanged: (v) {
                  if (v != null) onChanged(v);
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
