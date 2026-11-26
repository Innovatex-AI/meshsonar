// An observer's page in the Network tab (AZ-3.4). Website twin: `/observers/:id`.
//
// Shows what the API supplies, each section only when present: status and identity (kind, source, firmware, model,
// radio, uptime, reboots), the last hour (packets, noise floor, airtime with the duty-cycle warning, clock offset,
// battery), metrics over 24 h (noise floor, airtime TX/RX, packets, battery; reboot marks; a missing sample is a gap,
// never a zero), its neighbour report and the nodes it hears most. Star, Watch and Share in the app bar.
// `/v1` not live: today's region-observer (row, top nodes and the hourly charts as the metrics). Offline: the stored copy.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network_request.dart';
import '../../../core/v1/nodes_api.dart';
import '../../charts/chart_frame.dart';
import '../../charts/time_line_chart.dart';
import '../../map/map_preview.dart' show MapPreview;
import '../../map/still/place_map.dart';
import '../../map/still/still_nodes.dart' show stillRepeatersOf;
import '../../region/region_common.dart' show RegionOfflineAsOf, RegionOfflineEmpty, agoText;
import '../../theme.dart';
import '../network_context.dart';
import '../network_share.dart';
import '../packets/packet_ui.dart' show WebTwinLine, snrText;
import 'node_routes.dart';
import 'node_ui.dart';

class NetworkObserverScreen extends StatefulWidget {
  final String baseUrl, regionSlug, observerId;
  const NetworkObserverScreen({super.key, required this.baseUrl, required this.regionSlug, required this.observerId});
  @override
  State<NetworkObserverScreen> createState() => _NetworkObserverScreenState();
}

class _NetworkObserverScreenState extends State<NetworkObserverScreen> {
  late Future<ObserverPage> _f = _fetch();

  Future<ObserverPage> _fetch() async {
    final api = nodesApiFactory(widget.baseUrl);
    try {
      return await api.observer(widget.observerId);
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
  Widget build(BuildContext context) => FutureBuilder<ObserverPage>(
        future: _f,
        builder: (context, snap) {
          final p = snap.data;
          final id = widget.observerId;
          final name = p != null ? readableName(p.detail.row.name) : (id.length > 12 ? 'Observer ${id.substring(0, 8)}…' : 'Observer $id');
          return Scaffold(
            key: const Key('network-observer-screen'),
            appBar: AppBar(
              title: Text(name, key: const Key('observer-title'), maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                FavouriteStar(kind: FavouriteKind.observer, id: id, name: p?.detail.row.name, region: widget.regionSlug),
                WatchButton(kind: 'observer', target: id, name: p?.detail.row.name, region: widget.regionSlug),
                NetworkShareButton(request: NetworkRequest.observer(id, region: widget.regionSlug), subject: '$name on MeshSonar'),
              ],
            ),
            body: switch (snap.connectionState) {
              ConnectionState.done when snap.hasError => _error(context, snap.error),
              ConnectionState.done => RefreshIndicator(onRefresh: _reload, child: ObserverPageBody(page: p!, baseUrl: widget.baseUrl, regionSlug: widget.regionSlug)),
              _ => Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: Gap.m),
                    Text('Loading this observer…', style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ]),
                ),
            },
          );
        },
      );

  Widget _error(BuildContext context, Object? e) {
    if (e is V1Error && e.offline) return SingleChildScrollView(child: RegionOfflineEmpty(what: 'this observer', onRetry: _reload));
    final notFound = e is V1Error && e.notFound;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Gap.xl),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(notFound ? 'This observer is not in this region. It may report to another region.' : (e is V1Error ? e.message : 'The observer did not load.'),
              key: const Key('observer-error'), textAlign: TextAlign.center),
          const SizedBox(height: Gap.m),
          if (!notFound) FilledButton(key: const Key('observer-retry'), onPressed: _reload, child: const Text('Try again')),
          if (notFound) FilledButton(key: const Key('observer-error-back'), onPressed: () => Navigator.of(context).maybePop(), child: const Text('Go back')),
        ]),
      ),
    );
  }
}

String _uptime(int s) => s >= 86400 ? '${(s / 86400).toStringAsFixed(1)} days' : (s >= 3600 ? '${(s / 3600).round()} h' : '${(s / 60).round()} min');

class ObserverPageBody extends StatelessWidget {
  final ObserverPage page;
  final String baseUrl, regionSlug;
  const ObserverPageBody({super.key, required this.page, required this.baseUrl, required this.regionSlug});

  @override
  Widget build(BuildContext context) {
    final d = page.detail;
    final r = d.row;
    final t = Theme.of(context);
    final muted = t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant);
    final lastHour = <Widget>[
      if (r.packets1h != null) KvRow('Packets last hour', '${r.packets1h}'),
      if (r.packets24h != null) KvRow('Packets in 24 h', '${r.packets24h}'),
      if (r.noiseFloorDbm != null) KvRow('Noise floor', '${r.noiseFloorDbm!.round()} dBm'),
      if (r.airtimeTxPct1h != null) KvRow('Airtime sending', '${r.airtimeTxPct1h!.toStringAsFixed(1)}%'),
      if (r.airtimeRxPct1h != null) KvRow('Airtime receiving', '${r.airtimeRxPct1h!.toStringAsFixed(1)}%'),
      if (r.clockOffsetS != null) KvRow('Clock', skewText(r.clockOffsetS!)),
      if (r.batteryMv != null) KvRow('Battery', voltsText(r.batteryMv!)),
    ];
    final hardware = <Widget>[
      if (d.model != null) KvRow('Model', d.model!),
      if (r.firmware != null) KvRow('Firmware', r.firmware!),
      if (d.radio != null) KvRow('Radio', radioText(d.radio!), valueKey: const Key('observer-radio')),
      if (d.uptimeS != null) KvRow('Up for', _uptime(d.uptimeS!)),
      if (d.reboots7d != null) KvRow('Restarts in 7 days', '${d.reboots7d}${d.lastReboot == null ? '' : ', last ${agoText(d.lastReboot)}'}'),
      if (d.qualityFlags.isNotEmpty) KvRow('Data quality', d.qualityFlags.join(', ')),
      if (d.trusted == false) const KvRow('Data quality', 'Not trusted for hop naming'),
    ];
    return ListView(
      key: const Key('observer-page'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, Gap.xl),
      children: [
        if (page.offlineAsOf != null) RegionOfflineAsOf(asOf: page.offlineAsOf!),
        const SizedBox(height: Gap.xs),
        // The whole name (the app bar cuts a long one short), what it is and whether it is reporting.
        Semantics(header: true, child: Text(readableName(r.name), key: const Key('observer-name'), maxLines: 3, overflow: TextOverflow.ellipsis, style: t.textTheme.headlineSmall)),
        const SizedBox(height: Gap.xs),
        Row(children: [
          StatusDot(r.status, size: 12),
          const SizedBox(width: Gap.s),
          Expanded(child: Text('${observerKindLabel(r.kind)} · ${observerStatusLabel(r.status)}', style: t.textTheme.titleMedium)),
        ]),
        Text(r.lastSeen == null ? 'No report yet' : 'Last report ${agoText(r.lastSeen)}${r.iata == null ? '' : ' · area ${r.iata}'}',
            key: const Key('observer-seen'), style: t.textTheme.bodyMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        if (r.dutyCycleWarn)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text('Sending more than the duty-cycle limit', key: const Key('observer-duty-warn'), style: t.textTheme.bodyMedium?.copyWith(color: MeshSonarColors.of(context).beacon)),
          ),
        if (r.kind == 'phone') Text('Phone observers never show a position.', style: muted),
        // MAP slice 5: the observer's small map (page `observer`), when the definition presets one and it has a public position.
        if (r.kind != 'phone' && r.position != null && MapPreview.presetOf('observer') != null)
          Padding(
            key: const Key('observer-map'),
            padding: const EdgeInsets.only(top: Gap.s),
            child: StillPlaceMap(page: 'observer', role: 'observer', name: r.name, lat: r.position!.lat, lon: r.position!.lon, freshness: switch (r.status) { 'online' => 'fresh', 'stale' => 'recent', _ => 'stale' }, repeaters: stillRepeatersOf(context, regionSlug: regionSlug)),
          ),
        if (lastHour.isNotEmpty) NodeSection(id: 'observer-now', title: 'Right now', children: lastHour),
        if (hardware.isNotEmpty)
          NodeSection(
              id: 'observer-hardware',
              title: 'Hardware',
              collapsible: true,
              summary: [?d.model, ?r.firmware, if (d.model == null && r.firmware == null) 'Radio settings, uptime, restarts'].join(' · '),
              children: hardware),
        if (page.metrics != null) ..._metrics(context, page.metrics!),
        if (d.neighbours.isNotEmpty)
          NodeSection(id: 'observer-neighbours', title: 'Hears directly (${d.neighbours.length})', collapsible: true, summary: 'Nodes in radio range of this observer${d.neighbourReportAt == null ? '' : ' · reported ${agoText(d.neighbourReportAt)}'}', children: [
            NodeMoreList(id: 'observer-neighbours', children: [
            for (final n in d.neighbours)
              ListTile(
                contentPadding: EdgeInsets.zero,
                trailing: const Icon(Icons.chevron_right),
                title: Text(readableName(n.node.label), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text([if (n.snr != null) snrText(n.snr), if (n.heardAgoS != null) 'heard ${agoText(DateTime.now().toUtc().subtract(Duration(seconds: n.heardAgoS!)))}'].join(' · ')),
                onTap: () => openNetworkNode(context, baseUrl: baseUrl, regionSlug: regionSlug, nodeKey: n.node.key),
              ),
            ]),
          ]),
        if (d.topNodes.isNotEmpty)
          NodeSection(id: 'observer-top', title: 'Heard most', collapsible: true, summary: 'Top: ${readableName(d.topNodes.first.$1.label)} · ${d.topNodes.first.$2} packets', children: [
            NodeMoreList(id: 'observer-top', children: [
            for (final (n, c) in d.topNodes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(readableName(n.label), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('$c ${c == 1 ? 'packet' : 'packets'}'),
                trailing: n.key.length == 64 ? const Icon(Icons.chevron_right) : null,
                onTap: n.key.length == 64 ? () => openNetworkNode(context, baseUrl: baseUrl, regionSlug: regionSlug, nodeKey: n.key) : null,
              ),
            ]),
          ]),
        const SizedBox(height: Gap.m),
        if (page.source == NetworkReadSource.legacy)
          Text('Some parts (airtime per hour, restarts, the nodes it hears directly) are not available for this region yet.', key: const Key('observer-legacy-note'), style: muted),
        WebTwinLine(Uri(scheme: 'https', host: '$regionSlug.meshsonar.com', path: '/observers/${Uri.encodeComponent(r.id)}')),
      ],
    );
  }

  String _time(DateTime t) {
    final l = t.toLocal();
    return '${l.month}/${l.day} ${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  List<Widget> _metrics(BuildContext context, ObserverMetrics m) {
    final pal = chartPalette(context);
    final gap = m.fiveMinute ? const Duration(minutes: 11) : const Duration(hours: 2);
    final reboots = [for (final s in m.samples) if (s.rebooted) (s.at, Theme.of(context).colorScheme.error)];
    Widget chart(String id, String title, String unit, List<ChartSeries> series, String Function(ObserverSample) cell, {double? ref, String? refLabel}) {
      final pts = series.expand((s) => s.points).toList();
      final last = series.first.points.isEmpty ? null : series.first.points.reduce((a, b) => b.$1.isAfter(a.$1) ? b : a);
      return ChartFrame(
        id: id,
        title: title,
        summary: last == null ? 'No readings.' : 'Latest ${last.$2.toStringAsFixed(1)} $unit at ${_time(last.$1)}; ${pts.length} readings.',
        table: ChartTable(head: const ['Time', 'Value'], rows: [for (final s in m.samples.reversed.take(96)) [_time(s.at), cell(s)]]),
        // The dashed line is named in the caption under the chart, never on top of the data line.
        caption: '${ref == null || refLabel == null ? '' : 'Dashed line: $refLabel (${trimNumber(ref, 1)} $unit). '}'
            'One reading every ${m.fiveMinute ? '5 minutes' : 'hour'}. Gaps are missing readings; red ticks are restarts.',
        chart: TimeLineChart(series: series, yLabel: unit, xFormat: _time, breakGap: gap, floorMarks: reboots, refLine: ref, legend: series.length > 1),
      );
    }

    final nf = [for (final s in m.samples) if (s.noiseFloorDbm != null) (s.at, s.noiseFloorDbm!)];
    final tx = [for (final s in m.samples) if (s.airtimeTxPct != null) (s.at, s.airtimeTxPct!)];
    final rx = [for (final s in m.samples) if (s.airtimeRxPct != null) (s.at, s.airtimeRxPct!)];
    final pk = [for (final s in m.samples) if (s.packetsRx != null) (s.at, s.packetsRx!.toDouble())];
    final bt = [for (final s in m.samples) if (s.batteryMv != null) (s.at, s.batteryMv! / 1000)];
    String v(double? x, [int dp = 1]) => x == null ? '—' : x.toStringAsFixed(dp);
    return [
      NodeSection(id: 'observer-metrics', title: 'Last 24 hours', children: [
        if (nf.isNotEmpty)
          chart('obs-noise', 'Noise floor', 'dBm', [ChartSeries(name: 'Noise floor', points: nf, color: pal[0])], (s) => v(s.noiseFloorDbm, 0),
              ref: -100, refLabel: 'interference above this'),
        if (tx.isNotEmpty || rx.isNotEmpty)
          chart(
              'obs-airtime',
              'Airtime',
              '%',
              [
                if (tx.isNotEmpty) ChartSeries(name: 'Sending', points: tx, color: pal[1]),
                if (rx.isNotEmpty) ChartSeries(name: 'Receiving', points: rx, color: pal[0]),
              ],
              (s) => '${v(s.airtimeTxPct)} / ${v(s.airtimeRxPct)}',
              ref: m.dutyCycleWarnPct,
              refLabel: 'duty limit'),
        if (pk.isNotEmpty) chart('obs-packets', 'Packets received', 'packets', [ChartSeries(name: 'Packets', points: pk, color: pal[2])], (s) => s.packetsRx == null ? '—' : '${s.packetsRx}'),
        if (bt.isNotEmpty) chart('obs-battery', 'Battery', 'V', [ChartSeries(name: 'Battery', points: bt, color: pal[3])], (s) => s.batteryMv == null ? '—' : voltsText(s.batteryMv!)),
      ]),
    ];
  }
}
