// A node's page in the Network tab (AZ-3.4). Website twin: `/nodes/:key`.
//
// Sections, each shown only when the API supplied it (absent = hidden, never an empty box): identity and position,
// node actions, health, activity (packets per hour, packet types), SNR trend, heard by, neighbours, paths through,
// reach, your drives and drive reach (when it has a position), clock, battery, radio, hash size, recent adverts. The app bar has the favourite star, Watch (kept on the
// phone; alerts come with AZ-3.8) and Share (the region-host web link).
// `/v1` not live: today's region-repeater fills identity, health, SNR trend, packet types, heard by and neighbours;
// paths, reach, clock and battery do not exist there and stay hidden. Offline: the stored copy with "Offline - as of".
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network_request.dart';
import '../../../core/v1/nodes_api.dart';
import '../../charts/chart_frame.dart';
import '../../charts/time_line_chart.dart';
import '../../map/map_preview.dart' show MapPreview;
import '../../map/still/place_map.dart';
import '../../map/still/still_nodes.dart' show stillRepeatersOf;
import '../../nodes/node_actions.dart' show NodeActionBar;
import '../../nodes/node_ref.dart';
import '../../../core/repeater_detail_api.dart' show DailySnr;
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, agoText;
import '../../region/snr_trend_card.dart';
import '../../repeater_reach_section.dart';
import '../../your_drives_section.dart';
import '../../theme.dart';
import '../network_context.dart';
import '../network_share.dart';
import '../packets/packet_detail_screen.dart' show NetworkPacketScreen;
import '../packets/packet_ui.dart' show HopConfidenceBadge, WebTwinLine, plainServerText, snrText;
import '../../../core/v1/packet_models.dart' show hopConfidenceOf, packetTypeLabel;
import 'node_routes.dart';
import 'node_ui.dart';

class NetworkNodeScreen extends StatefulWidget {
  final String baseUrl, regionSlug, nodeKey;

  /// Draw map tiles in the drive sections (off under `flutter test`).
  final bool mapTiles;
  const NetworkNodeScreen({super.key, required this.baseUrl, required this.regionSlug, required this.nodeKey, this.mapTiles = true});
  @override
  State<NetworkNodeScreen> createState() => _NetworkNodeScreenState();
}

class _NetworkNodeScreenState extends State<NetworkNodeScreen> {
  late Future<NodePage> _f = _fetch();

  Future<NodePage> _fetch() async {
    final api = nodesApiFactory(widget.baseUrl);
    try {
      return await api.node(widget.nodeKey);
    } finally {
      api.close();
    }
  }

  Future<void> _reload() async {
    final f = _fetch();
    setState(() {
      _f = f;
    });
    try {
      await f;
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<NodePage>(
        future: _f,
        builder: (context, snap) {
          final p = snap.data;
          final name = p?.detail.label ?? 'Node ${widget.nodeKey.substring(0, 2)}';
          return Scaffold(
            key: const Key('network-node-screen'),
            appBar: AppBar(
              title: Text(name, key: const Key('node-title'), maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                FavouriteStar(kind: FavouriteKind.node, id: widget.nodeKey, name: p?.detail.name, region: widget.regionSlug),
                WatchButton(kind: 'node', target: widget.nodeKey, name: p?.detail.name, region: widget.regionSlug),
                NetworkShareButton(request: NetworkRequest.node(widget.nodeKey, region: widget.regionSlug), subject: '$name on MeshSonar'),
              ],
            ),
            body: switch (snap.connectionState) {
              ConnectionState.done when snap.hasError => _error(context, snap.error),
              ConnectionState.done => RefreshIndicator(onRefresh: _reload, child: NodePageBody(page: p!, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug, mapTiles: widget.mapTiles)),
              _ => const Center(child: CircularProgressIndicator()),
            },
          );
        },
      );

  Widget _error(BuildContext context, Object? e) {
    if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'this node', onRetry: _reload));
    final notFound = e is V1Error && e.notFound;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(notFound ? 'This region does not know that node.' : (e is V1Error ? e.message : 'The node did not load.'),
              key: const Key('node-error'), textAlign: TextAlign.center),
          const SizedBox(height: Gap.m),
          if (!notFound) FilledButton(onPressed: _reload, child: const Text('Try again')),
        ]),
      ),
    );
  }
}

NodeKind _kindOf(String role) => switch (role) {
      'room' => NodeKind.room,
      'companion' => NodeKind.companion,
      'sensor' => NodeKind.sensor,
      _ => NodeKind.repeater,
    };

/// The page content (also used by tests without the app bar).
class NodePageBody extends StatelessWidget {
  final NodePage page;
  final String baseUrl, regionSlug;
  final bool mapTiles;
  const NodePageBody({super.key, required this.page, required this.baseUrl, required this.regionSlug, this.mapTiles = true});

  @override
  Widget build(BuildContext context) {
    final d = page.detail;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final hidden = (d.name ?? '').contains('\u{1F6AB}');
    final ref = NodeRef(
      key: d.key,
      name: d.label,
      kind: _kindOf(d.role),
      lat: hidden ? null : d.position?.lat,
      lon: hidden ? null : d.position?.lon,
      source: NodeSource.region,
      positionHidden: hidden,
    );
    return ListView(
      key: const Key('node-page'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
      children: [
        if (page.offlineAsOf != null) RegionOfflineAsOf(asOf: page.offlineAsOf!),
        if (page.source == NetworkReadSource.legacy)
          Text('From the region repeater page: paths through, reach, clock and battery come with the new node service.',
              key: const Key('node-legacy-note'), style: muted),
        if (page.status != null && page.status!.state.name != 'ready' && plainServerText(page.status!.reason) != null)
          Padding(padding: const EdgeInsets.only(top: Gap.xs), child: Text(plainServerText(page.status!.reason)!, key: const Key('node-status-note'), style: muted)),
        _identity(context, d, hidden),
        // MAP slice 5: the node's small map (page `node`), when the definition presets one and the node has a public position.
        if (!hidden && d.position != null && MapPreview.presetOf('node') != null)
          Padding(
            key: const Key('node-map'),
            padding: const EdgeInsets.only(top: Gap.s),
            child: StillPlaceMap(page: 'node', role: d.role, name: d.label, lat: d.position!.lat, lon: d.position!.lon, tiles: mapTiles ? null : false, nodeKey: d.key, repeaters: stillRepeatersOf(context, regionSlug: regionSlug)),
          ),
        const SizedBox(height: Gap.s),
        NodeActionBar(node: ref),
        if (d.health != null) _health(context, d),
        if (page.activity != null) ..._activity(context, page.activity!),
        if (page.heardBy != null && page.heardBy!.isNotEmpty) _heardBy(context, page),
        if (page.neighbours != null && page.neighbours!.isNotEmpty) _neighbours(context, page.neighbours!),
        if (page.paths != null && page.paths!.isNotEmpty) _paths(context, page),
        if (page.reach != null && (page.reach!.links.isNotEmpty || page.reach!.directObservers.isNotEmpty)) _reach(context, page.reach!),
        // What this phone's own drives know about the node (they need its position, and show nothing without drives).
        if (!hidden && d.position != null) ...[
          Padding(
            key: const Key('node-your-drives'),
            padding: const EdgeInsets.only(top: Gap.l),
            child: YourDrivesSection(repeaterKey: d.key, lat: d.position!.lat, lon: d.position!.lon, mapTiles: mapTiles),
          ),
          Padding(
            key: const Key('node-drive-reach'),
            padding: const EdgeInsets.only(top: Gap.l),
            child: RepeaterReachSection(repeaterKey: d.key, lat: d.position!.lat, lon: d.position!.lon, mapTiles: mapTiles),
          ),
        ],
        if (page.clock != null || (d.clockSeverity != null && d.clockSeverity != 'no_clock')) _clock(context, d, page.clock),
        if (page.battery != null || d.batteryMv != null) _battery(context, d, page.battery),
        if (d.radio != null) _radio(context, d.radio!),
        if (d.hashSize != null) _hash(context, d),
        if (d.recentAdverts.isNotEmpty) _adverts(context, d),
        const SizedBox(height: Gap.m),
        WebTwinLine(Uri(scheme: 'https', host: '$regionSlug.meshsonar.com', path: '/nodes/${d.key}')),
      ],
    );
  }

  Widget _identity(BuildContext context, NodeDetail d, bool hidden) {
    final t = Theme.of(context);
    final status = d.health?.status;
    final pos = d.position;
    final posText = hidden
        ? 'Position hidden by the owner'
        : pos != null
            ? '${pos.lat.toStringAsFixed(4)}, ${pos.lon.toStringAsFixed(4)}${pos.precision.startsWith('rounded') ? ' (rounded)' : ''}'
            : switch (d.positionReason) {
                'hidden_by_owner' => 'Position hidden by the owner',
                'invalid' => 'The advertised position is not valid',
                _ => 'Never advertised a position',
              };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: Gap.s),
      Row(children: [
        if (status != null) ...[StatusDot(status, size: 12), const SizedBox(width: Gap.s)],
        Expanded(child: Text([nodeRoleLabel(d.role), if (status != null) nodeStatusLabel(status)].join(' · '), style: t.textTheme.titleSmall)),
      ]),
      if (d.aka.isNotEmpty) Text('Also seen as ${d.aka.join(', ')}', style: t.textTheme.bodySmall),
      const SizedBox(height: Gap.xs),
      SelectableText(d.key, key: const Key('node-key'), style: t.textTheme.bodySmall),
      KvRow('Hop prefix', [d.prefixes['1'] ?? d.prefix, ?d.prefixes['2'], ?d.prefixes['3']].join(' · ')),
      KvRow('Position', posText, valueKey: const Key('node-position')),
      if (d.lastHeardAt != null) KvRow('Last heard', agoText(d.lastHeardAt)),
      if (d.lastAdvertAt != null) KvRow('Last advert', agoText(d.lastAdvertAt)),
      if (d.firstSeen != null) KvRow('First seen', agoText(d.firstSeen)),
      if (d.claimed == true) const KvRow('Claimed', 'Claimed by its owner'),
    ]);
  }

  Widget _health(BuildContext context, NodeDetail d) {
    final h = d.health!;
    final how = switch (h.lastHeardHow) {
      'own_packet' => 'its own packet',
      'relay_unique_prefix' => 'relaying (unique prefix)',
      'relay_likely' => 'relaying (likely)',
      _ => null,
    };
    return NodeSection(id: 'health', title: 'Health', children: [
      KvRow('Status', nodeStatusLabel(h.status)),
      if (h.lastHeardAt != null) KvRow('Last heard', [agoText(h.lastHeardAt), ?how].join(', by ')),
      if (h.offlineAfterH != null) KvRow('Counts as silent after', '${h.offlineAfterH!.round()} h${h.thresholdKind == 'adaptive' ? ' (learned from this node)' : ''}'),
      if (h.packetsToday != null) KvRow('Packets today', '${h.packetsToday}'),
      if (h.relayed1h != null) KvRow('Relayed last hour', '${h.relayed1h}'),
      if (h.relayed24h != null) KvRow('Relayed in 24 h', '${h.relayed24h}'),
      if (h.avgSnr != null) KvRow('Mean SNR', snrText(h.avgSnr)),
      if (h.avgHops != null) KvRow('Mean hops', h.avgHops!.toStringAsFixed(1)),
      if (h.heard24h != null) KvRow('Heard (24 h)', shareText(h.heard24h!)),
      if (h.heard7d != null) KvRow('Heard (7 d)', shareText(h.heard7d!), valueKey: const Key('node-heard-7d')),
      if (h.heard30d != null) KvRow('Heard (30 d)', shareText(h.heard30d!)),
      if (h.heard7d != null || h.heard24h != null || h.heard30d != null)
        Text('Share of hours with traffic in which a source heard this node.', style: Theme.of(context).textTheme.bodySmall),
      if (d.usefulnessGrade != null)
        KvRow('Usefulness', '${d.usefulnessGrade}${d.usefulnessScore == null ? '' : ' (${shareText(d.usefulnessScore!)})'}'),
    ]);
  }

  String _hour(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} ${l.hour.toString().padLeft(2, '0')}:00';
  }

  List<Widget> _activity(BuildContext context, NodeActivity a) {
    final pal = chartPalette(context);
    final out = <Widget>[];
    if (a.timeline.isNotEmpty) {
      final peak = a.timeline.reduce((x, y) => y.$2 > x.$2 ? y : x);
      out.add(NodeSection(id: 'activity', title: 'Activity', children: [
        ChartFrame(
          id: 'node-activity',
          title: 'Packets per hour',
          summary: 'Peak ${peak.$2} packets at ${_hour(peak.$1)}.',
          table: ChartTable(head: const ['Hour', 'Packets', 'Relayed'], rows: [
            for (final r in a.timeline.reversed.take(72)) [_hour(r.$1), '${r.$2}', r.$3 == null ? '—' : '${r.$3}']
          ]),
          chart: TimeLineChart(
            series: [
              ChartSeries(name: 'Packets', points: [for (final r in a.timeline) (r.$1, r.$2.toDouble())], color: pal[0]),
              if (a.timeline.any((r) => r.$3 != null))
                ChartSeries(name: 'Relayed', points: [for (final r in a.timeline) if (r.$3 != null) (r.$1, r.$3!.toDouble())], color: pal[1]),
            ],
            yLabel: 'packets',
            xFormat: _hour,
            includeLo: 0,
            legend: true,
            breakGap: const Duration(hours: 2),
          ),
        ),
      ]));
    }
    if (a.types.isNotEmpty) {
      final sorted = a.types.entries.toList()..sort((x, y) => y.value.compareTo(x.value));
      out.add(NodeSection(id: 'types', title: 'Packet types', children: [
        for (final e in sorted) KvRow(packetTypeLabel(e.key), '${e.value}'),
      ]));
    }
    final snr = [for (final s in a.snrTrend) if (s.$2 != null) (s.$1, s.$2!)];
    if (snr.isNotEmpty) {
      String day(DateTime t) => '${t.month}/${t.day}';
      // Collapsed by default (a small screen): the header says the latest reading; the card (summary, chart, table) is
      // the one the old region repeater page had.
      out.add(Padding(
        key: const Key('node-section-snr'),
        padding: const EdgeInsets.only(top: Gap.l),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            key: const PageStorageKey('node-snr-tile'),
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Semantics(header: true, child: Text('SNR trend', style: Theme.of(context).textTheme.titleMedium)),
            subtitle: Text('Latest ${snrText(snr.last.$2)} on ${day(snr.last.$1)} · ${snr.length} days with readings', key: const Key('node-snr-latest')),
            children: [SnrTrendCard(daily: [for (final s in a.snrTrend) DailySnr(s.$1, s.$2, s.$3)])],
          ),
        ),
      ));
    }
    return out;
  }

  Widget _heardBy(BuildContext context, NodePage p) {
    final t = Theme.of(context);
    return NodeSection(id: 'heard-by', title: 'Heard by (${p.heardBy!.length})', children: [
      for (final h in p.heardBy!)
        ListTile(
          key: Key('heard-by-${h.observer.id}'),
          contentPadding: EdgeInsets.zero,
          title: Text(h.observer.name),
          subtitle: Text([
            observerKindLabel(h.observer.kind),
            h.direct ? 'heard directly' : 'heard through relays',
            '${h.packets} ${h.packets == 1 ? 'packet' : 'packets'}',
            if (h.avgSnr != null) 'mean ${snrText(h.avgSnr)}',
            if (h.bestSnr != null) 'best ${snrText(h.bestSnr)}',
            if (h.lastAt != null) 'last ${agoText(h.lastAt)}',
          ].join(' · ')),
          onTap: () => openNetworkObserver(context, baseUrl: baseUrl, regionSlug: regionSlug, observerId: h.observer.id),
        ),
      if (p.relayOnlyObservers != null && p.relayOnlyObservers! > 0)
        Text('${p.relayOnlyObservers} more observers heard it only as a relay.', style: t.textTheme.bodySmall),
    ]);
  }

  Widget _neighbours(BuildContext context, List<NeighbourRow> rows) => NodeSection(id: 'neighbours', title: 'Neighbours (${rows.length})', children: [
        for (final n in rows)
          ListTile(
            key: Key('neighbour-${n.node?.key ?? n.prefix}'),
            contentPadding: EdgeInsets.zero,
            title: Text(n.label),
            subtitle: Text([
              if (n.count != null) '${n.count} ${n.count == 1 ? 'packet' : 'packets'}',
              if (n.avgSnr != null) snrText(n.avgSnr),
              if (n.distanceKm != null) distanceText(context, n.distanceKm!),
              if (n.kinds.isNotEmpty) n.kinds.join(', '),
              if (n.node == null && n.candidates.isNotEmpty) 'could be ${n.candidates.map((c) => c.label).join(' or ')}',
            ].join(' · ')),
            trailing: HopConfidenceBadge(hopConfidenceOf(n.confidence)),
            onTap: n.node == null ? null : () => openNetworkNode(context, baseUrl: baseUrl, regionSlug: regionSlug, nodeKey: n.node!.key),
          ),
      ]);

  Widget _paths(BuildContext context, NodePage p) {
    final t = Theme.of(context);
    String hop(PacketHop h) => switch (h.confidence) {
          HopConfidence.unique => h.node?.label ?? h.prefix,
          HopConfidence.likely => '${h.node?.label ?? h.prefix} (likely)',
          HopConfidence.ambiguous => '${h.prefix}?',
          _ => '${h.prefix} (unknown)',
        };
    return NodeSection(id: 'paths', title: 'Paths through (${p.totalPaths ?? p.paths!.length})', children: [
      for (final r in p.paths!)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(r.hops.map(hop).join(' › ')),
          subtitle: Text(['${r.count} ${r.count == 1 ? 'packet' : 'packets'}', if (r.lastAt != null) 'last ${agoText(r.lastAt)}'].join(' · ')),
          onTap: r.sampleHash == null
              ? null
              : () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NetworkPacketScreen(baseUrl: baseUrl, regionSlug: regionSlug, hash: r.sampleHash!))),
        ),
      Text('A name with "(likely)" is a best guess; "?" and "(unknown)" hops could not be named.', style: t.textTheme.bodySmall),
    ]);
  }

  Widget _reach(BuildContext context, NodeReach r) => NodeSection(id: 'reach', title: 'Reach', children: [
        if (r.degree != null) KvRow('Direct links', '${r.degree}${r.degreeRank == null ? '' : ' (rank ${r.degreeRank} here)'}'),
        for (final l in r.links)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(l.node.label),
            subtitle: Text([
              l.bidirectional ? 'both ways' : 'one way',
              'it hears ${l.weHear}, heard by them ${l.theyHear}',
              if (l.distanceKm != null) distanceText(context, l.distanceKm!),
            ].join(' · ')),
            onTap: () => openNetworkNode(context, baseUrl: baseUrl, regionSlug: regionSlug, nodeKey: l.node.key),
          ),
        if (r.directObservers.isNotEmpty) KvRow('Observers in direct range', r.directObservers.map((o) => o.name).join(', ')),
      ]);

  Widget _clock(BuildContext context, NodeDetail d, NodeClock? c) {
    final sev = c?.severity ?? d.clockSeverity ?? 'no_clock';
    final skew = c?.skewS ?? d.clockSkewS;
    final drift = c?.driftSPerDay ?? d.clockDriftSPerDay;
    return NodeSection(id: 'clock', title: 'Clock', children: [
      KvRow('Clock', clockSeverityLabel(sev), valueKey: const Key('node-clock')),
      if (skew != null) KvRow('Offset', skewText(skew)),
      if (drift != null) KvRow('Drift', '${drift.toStringAsFixed(1)} s per day'),
      if (c?.bimodal == true) const KvRow('Note', 'Two different clocks seem to advertise this key'),
    ]);
  }

  Widget _battery(BuildContext context, NodeDetail d, NodeBattery? b) {
    final mv = b?.latestMv ?? d.batteryMv;
    final status = b?.status ?? d.batteryStatus ?? 'unknown';
    final pal = chartPalette(context);
    String day(DateTime t) => '${t.month}/${t.day}';
    return NodeSection(id: 'battery', title: 'Battery', children: [
      if (mv != null) KvRow('Battery', '${voltsText(mv)} · ${switch (status) { 'ok' => 'OK', 'low' => 'Low', 'critical' => 'Critical', _ => 'Unknown' }}', valueKey: const Key('node-battery')),
      if (b != null && b.series.length > 1)
        ChartFrame(
          id: 'node-battery',
          title: 'Battery voltage',
          summary: 'From ${voltsText(b.series.first.$2)} to ${voltsText(b.series.last.$2)}.',
          table: ChartTable(head: const ['Day', 'Voltage'], rows: [for (final s in b.series.reversed) [day(s.$1), voltsText(s.$2)]]),
          chart: TimeLineChart(
            series: [ChartSeries(name: 'Battery', points: [for (final s in b.series) (s.$1, s.$2 / 1000)], color: pal[0])],
            yLabel: 'V',
            xFormat: day,
            refLine: b.lowBelowMv / 1000,
            refLabel: 'low',
          ),
        ),
    ]);
  }

  Widget _radio(BuildContext context, NodeRadio r) => NodeSection(id: 'radio', title: 'Radio', children: [
        if (r.model != null) KvRow('Model', r.model!),
        if (r.firmware != null) KvRow('Firmware', r.firmware!),
        if (r.preset != null) KvRow('Preset', r.preset!),
        if (r.freqMhz != null) KvRow('Frequency', '${trimNumber(r.freqMhz!, 3)} MHz'),
        if (r.bwKhz != null || r.sf != null)
          KvRow('Settings', [if (r.bwKhz != null) 'BW ${trimNumber(r.bwKhz!, 2)} kHz', if (r.sf != null) 'SF ${r.sf}', if (r.cr != null) 'CR ${r.cr}'].join(' · ')),
        if (r.differsFromNearby) const KvRow('Note', 'Its radio settings differ from nearby nodes'),
      ]);

  Widget _hash(BuildContext context, NodeDetail d) {
    final col = d.collisions[(d.hashSize ?? 1).toString()];
    return NodeSection(id: 'hash', title: 'Hash size', children: [
      KvRow('Hop prefix size', '${d.hashSize} byte${d.hashSize == 1 ? '' : 's'}${d.hashInconsistent ? ' (changes between packets)' : ''}'),
      if (col != null) KvRow('Shares its prefix with', col == 0 ? 'no other relay' : '$col other relay${col == 1 ? '' : 's'}'),
    ]);
  }

  Widget _adverts(BuildContext context, NodeDetail d) => NodeSection(id: 'adverts', title: 'Recent adverts', children: [
        for (final a in d.recentAdverts.take(10))
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(a.at == null ? a.hash : agoText(a.at)),
            subtitle: Text([
              if (a.hops != null) '${a.hops} hops',
              if (a.observers != null) '${a.observers} observers',
              if (a.signatureValid == false) 'signature not valid',
            ].join(' · ')),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NetworkPacketScreen(baseUrl: baseUrl, regionSlug: regionSlug, hash: a.hash))),
          ),
      ]);
}
