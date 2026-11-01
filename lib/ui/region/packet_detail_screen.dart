// "Packet detail": the website's packet page as a phone screen. Data: `region-packet` (lib/core/region_packet_detail_api.dart),
// what this region's own observers heard: who heard it, when, at what signal, the path each took and the merged tree of hops.
// A flood packet also offers "Trace the flood route", which opens the native flood routes view on the same hash.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_packet_detail_api.dart';
import '../../core/region_packets_api.dart' show packetRouteName, packetTypeName;
import '../theme.dart';
import 'flood_trace_view.dart' show clockUtc, dayUtc;
import 'region_dataset_view.dart';
import 'routes_panel.dart' show openFloodRoutes;

Future<void> openPacketDetail(BuildContext context, {required String baseUrl, required String regionSlug, required String hash}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => PacketDetailScreen(baseUrl: baseUrl, regionSlug: regionSlug, hash: hash)));

class PacketDetailScreen extends StatelessWidget {
  final String baseUrl;
  final String regionSlug;
  final String hash;
  final http.Client? client;
  const PacketDetailScreen({super.key, required this.baseUrl, required this.regionSlug, required this.hash, this.client});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Packet')),
        body: RegionDatasetView<PacketDetailData>(
          id: 'pktdetail',
          title: 'Packet $hash',
          reloadKey: '$baseUrl|$hash',
          load: () => PacketDetailApi(baseUrl, client: client).fetch(hash),
          status: (d) => d.status,
          isEmpty: (d) => !d.hasRow,
          emptyText: 'No observer in this region has this packet on record.',
          build: (context, d) => _body(context, d),
        ),
      );

  List<Widget> _body(BuildContext context, PacketDetailData d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final flood = d.route == 0 || d.route == 1;
    String snr(double? v) => v == null ? 'no reading' : '${v.toStringAsFixed(v.truncateToDouble() == v ? 0 : 1)} dB';
    final rows = <Widget>[];
    void walk(PacketTreeNodeData n, int level) {
      rows.add(Padding(
        padding: EdgeInsets.only(left: 14.0 * level.clamp(0, 8), top: 2, bottom: 2),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(level == 0 ? Icons.cell_tower : Icons.subdirectory_arrow_right, size: 16, color: m.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(n.label, style: t.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (n.observers.isNotEmpty) Text('Heard by ${n.observers.length} observer${n.observers.length == 1 ? '' : 's'}', style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
              if (n.confidence == 'low') Text('Matched loosely: the node list was not complete', style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
            ]),
          ),
        ]),
      ));
      for (final c in n.children) {
        walk(c, level + 1);
      }
    }

    if (d.tree != null) walk(d.tree!, 0);
    return [
      Text('${packetTypeName(d.type)}${d.originName == null ? '' : ' from ${d.originName}'}', key: const Key('pktdetail-title'), style: t.textTheme.titleLarge),
      const SizedBox(height: 2),
      SelectableText(d.hash ?? hash, style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      const SizedBox(height: Gap.s),
      FigureStrip([
        ('Route', packetRouteName(d.route), null),
        ('First heard', dayUtc(d.firstAt), null),
        ('Observers', '${d.observers}', null),
        ('Fewest hops', d.minHops == 0 ? 'direct' : '${d.minHops}', null),
        ('Best SNR', snr(d.bestSnrDb), null),
      ]),
      if (flood) ...[
        const SizedBox(height: Gap.m),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('pktdetail-trace'),
            onPressed: () => openFloodRoutes(context, baseUrl: baseUrl, regionSlug: regionSlug, hash: d.hash ?? hash),
            icon: const Icon(Icons.alt_route),
            label: const Text('Trace the flood route'),
          ),
        ),
      ],
      const SizedBox(height: Gap.l),
      Text('Who heard it (${d.observations.length})', style: t.textTheme.titleMedium),
      const SizedBox(height: Gap.xs),
      for (final o in d.observations)
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text(o.who + (o.via == null ? '' : '  (via ${o.via})')),
          subtitle: Text([
            clockUtc(o.at),
            o.hops == 0 ? 'direct' : '${o.hops} hop${o.hops == 1 ? '' : 's'}',
            snr(o.snrDb),
            if (o.rssiDbm != null) '${o.rssiDbm!.round()} dBm',
            if (o.path.isNotEmpty) 'path ${o.path.join(' > ')}',
          ].join(' · ')),
        ),
      if (d.tree != null) ...[
        const SizedBox(height: Gap.l),
        Text('Path tree', style: t.textTheme.titleMedium),
        Text('Hops merged across observers. A hop whose code several repeaters share is not named.', style: t.textTheme.bodySmall?.copyWith(color: m.textMuted)),
        const SizedBox(height: Gap.xs),
        ...rows,
      ],
    ];
  }
}
