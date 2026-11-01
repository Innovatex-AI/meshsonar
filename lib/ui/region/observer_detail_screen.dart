// "Observer detail": what the website shows at `/observers/$key`, as a phone screen. Data: `region-observer` (lib/core/
// region_observer_detail_api.dart). Header chips, the figures, hardware, hourly noise floor / airtime / battery / packets over
// 7 days (each chart has a table view), packet types and the nodes it hears most (tap one to open that repeater).
//
// STATUS CHIPS: [ObserverStatusChips] is the one place that says what state the observer is in: Online / Offline plus the server's
// observer health (migration 0100: Hearing / Quiet / Deaf / No status, and the sentence for a deaf radio or a low battery). The
// same widget can be dropped into the list tile.
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/region_observer_detail_api.dart';
import '../../core/region_overview_api.dart' show RegionObserver;
import '../../core/region_packets_api.dart' show packetTypeName;
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';
import 'region_common.dart';
import 'region_dataset_view.dart';
import 'repeater_detail_screen.dart' show openRepeaterDetail;

Future<void> openObserverDetail(
  BuildContext context, {
  required String baseUrl,
  required String regionSlug,
  required RegionObserver observer,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      builder: (_) => ObserverDetailScreen(baseUrl: baseUrl, regionSlug: regionSlug, observerKey: observer.key, title: observer.displayName),
    ));

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
String _hour(DateTime t) {
  final l = t.toLocal();
  return '${_months[l.month - 1]} ${l.day} ${l.hour.toString().padLeft(2, '0')}:00';
}

String _day(DateTime t) {
  final l = t.toLocal();
  return '${_months[l.month - 1]} ${l.day}';
}

class ObserverDetailScreen extends StatelessWidget {
  final String baseUrl;
  final String regionSlug;
  final String observerKey;
  final String title;
  final http.Client? client;
  const ObserverDetailScreen({super.key, required this.baseUrl, required this.regionSlug, required this.observerKey, required this.title, this.client});

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title, key: const Key('obsdetail-title'))),
        body: RegionDatasetView<ObserverDetailData>(
          id: 'obsdetail',
          title: 'Observer',
          reloadKey: '$baseUrl|$observerKey',
          load: () => ObserverDetailApi(baseUrl, client: client).fetch(observerKey),
          status: (d) => d.status,
          isEmpty: (d) => d.row == null,
          emptyText: 'This observer is not in the list for this region.',
          build: (context, d) => _body(context, d),
        ),
      );

  List<Widget> _body(BuildContext context, ObserverDetailData d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final r = d.row!;
    Widget section(String title, Widget child, {String? lead}) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.textTheme.titleMedium),
            if (lead != null) Padding(padding: const EdgeInsets.only(top: 2), child: Text(lead, style: t.textTheme.bodySmall?.copyWith(color: m.textMuted))),
            const SizedBox(height: Gap.s),
            child,
          ]),
        );
    Widget muted(String s) => Text(s, style: t.textTheme.bodyMedium?.copyWith(color: m.textMuted));

    List<(DateTime, double)> pts(List<HourPoint> l, {bool b = false}) => [
          for (final p in l)
            if ((b ? p.b : p.a) != null) (p.at, (b ? p.b : p.a)!),
        ];

    Widget hourly({
      required String id,
      required String title,
      required String unit,
      required List<ChartSeries> series,
      required List<HourPoint> source,
      required List<String> head,
      required List<String> Function(HourPoint) row,
      required String summary,
      bool signed = false,
    }) {
      final any = series.any((s) => s.points.length >= 2);
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: ChartFrame(
          id: id,
          title: title,
          summary: summary,
          height: 150,
          startWithTable: !any,
          caption: 'Hourly, last 7 days, in your time zone. A missing hour is a gap, not a zero.',
          table: ChartTable(head: ['Hour', ...head], rows: [for (final p in source.reversed.take(72)) [_hour(p.at), ...row(p)]]),
          chart: !any
              ? const SizedBox()
              : TimeLineChart(
                  series: series,
                  yLabel: unit,
                  breakGap: const Duration(hours: 3),
                  xFormat: _day,
                  legend: series.length > 1,
                  signedTicks: signed,
                ),
        ),
      );
    }

    String f1(double? v, String u) => v == null ? 'no reading' : '${v.toStringAsFixed(1)} $u';
    String range(List<(DateTime, double)> p, String u) {
      if (p.isEmpty) return 'No readings in the last 7 days.';
      final vs = [for (final e in p) e.$2]..sort();
      return 'Latest ${p.last.$2.toStringAsFixed(1)} $u, lowest ${vs.first.toStringAsFixed(1)} $u, highest ${vs.last.toStringAsFixed(1)} $u over ${p.length} hours.';
    }

    final noise = pts(d.noiseFloor);
    final tx = pts(d.airtime), rx = pts(d.airtime, b: true);
    final batt = pts(d.battery);
    final pph = pts(d.packetsPerHour);
    final typeTotal = d.packetTypes.fold<int>(0, (a, e) => a + e.$2);
    final types = [...d.packetTypes]..sort((a, b) => b.$2.compareTo(a.$2));

    return [
      ObserverStatusChips(row: r, health: d.health, staleSince: d.staleSince),
      const SizedBox(height: Gap.s),
      SelectableText(r.key, key: const Key('obsdetail-key'), style: t.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
      const SizedBox(height: 4),
      Text(
        'Last packet ${agoText(r.lastPacketAt)} · last status report ${agoText(r.lastStatusAt)}'
        '${!r.online && d.staleSince != null ? ' · quiet since ${agoText(d.staleSince)}' : ''}',
        style: t.textTheme.bodyMedium?.copyWith(color: m.textMuted),
      ),
      const SizedBox(height: Gap.m),
      FigureStrip([
        ('Packets per hour', r.packetsPerHour == null ? 'unknown' : groupInt(r.packetsPerHour!), null),
        ('Noise floor', r.noiseFloorDbm == null ? 'unknown' : '${r.noiseFloorDbm!.toStringAsFixed(1)} dBm', 'lower is better'),
        ('Nodes heard, 24 h', r.nodesHeard24h == null ? 'unknown' : groupInt(r.nodesHeard24h!), null),
        ('Battery', r.batteryMv == null ? 'unknown' : '${(r.batteryMv! / 1000).toStringAsFixed(2)} V', null),
      ]),
      const SizedBox(height: Gap.l),
      section(
        'Hardware',
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _fact(context, 'Radio', d.radio),
          _fact(context, 'Firmware', r.firmware),
          _fact(context, 'Model', r.model),
          _fact(context, 'Reports to', r.source == 'meshsonar' ? 'MeshSonar' : 'CoreScope'),
          if (r.lat != null && r.lon != null)
            _fact(context, 'Location', '${r.lat!.toStringAsFixed(4)}, ${r.lon!.toStringAsFixed(4)} (public: the operator chose to share it)')
          else
            _fact(context, 'Location', 'Private: the operator keeps it off the map'),
        ]),
      ),
      if (!d.hasCharts)
        section('Health and traffic', muted('No hourly history for this observer yet.'))
      else ...[
        section(
          'Health',
          Column(children: [
            hourly(
              id: 'obs-noise',
              title: 'Noise floor (dBm)',
              unit: 'dBm',
              series: [ChartSeries(name: 'Noise floor', points: noise, color: t.colorScheme.onSurface)],
              source: d.noiseFloor,
              head: ['dBm'],
              row: (p) => [f1(p.a, 'dBm')],
              summary: range(noise, 'dBm'),
              signed: true,
            ),
            hourly(
              id: 'obs-airtime',
              title: 'Airtime (% of time sending and receiving)',
              unit: '%',
              series: [ChartSeries(name: 'Transmit', points: tx, color: t.colorScheme.primary), ChartSeries(name: 'Receive', points: rx, color: m.snrStrong)],
              source: d.airtime,
              head: ['Transmit %', 'Receive %'],
              row: (p) => [f1(p.a, '%'), f1(p.b, '%')],
              summary: tx.isEmpty && rx.isEmpty ? 'No airtime readings.' : 'Transmit ${range(tx, '%')} Receive ${range(rx, '%')}',
            ),
            hourly(
              id: 'obs-battery',
              title: 'Battery (mV)',
              unit: 'mV',
              series: [ChartSeries(name: 'Battery', points: batt, color: m.beacon)],
              source: d.battery,
              head: ['mV'],
              row: (p) => [p.a == null ? 'no reading' : '${p.a!.round()} mV'],
              summary: range(batt, 'mV'),
            ),
          ]),
          lead: 'A higher (less negative) noise floor means more interference near this observer, which cuts how far it hears.',
        ),
        section(
          'Traffic',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            hourly(
              id: 'obs-pph',
              title: 'Packets per hour',
              unit: 'packets',
              series: [ChartSeries(name: 'Packets', points: pph, color: t.colorScheme.primary)],
              source: d.packetsPerHour,
              head: ['Packets'],
              row: (p) => [p.a == null ? 'no reading' : groupInt(p.a!.round())],
              summary: range(pph, 'packets'),
            ),
            Text('Packet types', style: t.textTheme.titleSmall),
            const SizedBox(height: Gap.xs),
            if (types.isEmpty)
              muted('No packets in the window.')
            else
              for (final e in types.take(12))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(children: [
                    Expanded(flex: 3, child: Text(packetTypeName(e.$1))),
                    Expanded(
                      flex: 4,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(value: typeTotal == 0 ? 0 : e.$2 / typeTotal, minHeight: 8),
                      ),
                    ),
                    SizedBox(width: 84, child: Text('${groupInt(e.$2)} · ${typeTotal == 0 ? 0 : (100 * e.$2 / typeTotal).round()}%', textAlign: TextAlign.end, style: t.textTheme.labelMedium)),
                  ]),
                ),
          ]),
        ),
      ],
      section(
        'Nodes it hears most',
        d.topNodes.isEmpty
            ? muted('This observer has not heard any node in the window.')
            : Column(children: [
                for (final n in d.topNodes.take(30))
                  ListTile(
                    key: Key('obsdetail-node-${n.key}'),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(n.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text('${groupInt(n.packets)} packets${n.bestSnrDb == null ? '' : ' · best SNR ${n.bestSnrDb!.toStringAsFixed(1)} dB'}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openRepeaterDetail(context, baseUrl: baseUrl, regionSlug: regionSlug, repeaterKey: n.key),
                  ),
              ]),
      ),
    ];
  }

  Widget _fact(BuildContext context, String k, String? v) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 104, child: Text(k, style: t.textTheme.labelLarge?.copyWith(color: MeshSonarColors.of(context).textMuted))),
        Expanded(child: Text(v ?? 'unknown')),
      ]),
    );
  }
}

/// The observer's state as chips: Online / Offline always, plus the server's health word and, for a deaf radio or a low battery,
/// the website's sentence (see the file header). Used by the detail screen; the list tile may use it too.
class ObserverStatusChips extends StatelessWidget {
  final RegionObserver row;
  final ObserverHealth? health;
  final DateTime? staleSince;
  const ObserverStatusChips({super.key, required this.row, this.health, this.staleSince});

  static String _clock(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final h = health;
    final n = h?.notice(_clock);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        Chip(
          key: Key(row.online ? 'obsdetail-online' : 'obsdetail-offline'),
          avatar: Icon(row.online ? Icons.check_circle_outline : Icons.cancel_outlined, size: 18),
          label: Text(row.online ? 'Online' : 'Offline'),
        ),
        if (h != null)
          Chip(
            key: const Key('obsdetail-health'),
            avatar: Icon(h.state == 'deaf' ? Icons.hearing_disabled_outlined : Icons.monitor_heart_outlined, size: 18, color: h.state == 'deaf' ? t.colorScheme.error : null),
            label: Text(h.state == 'deaf' ? 'Deaf' : h.state == 'ok' ? 'Hearing' : h.state == 'quiet' ? 'Quiet' : h.state == 'offline' ? 'No status' : h.state),
          ),
        Chip(label: Text(row.source == 'meshsonar' ? 'MeshSonar observer' : 'CoreScope observer')),
      ]),
      if (n != null)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(n.headline, key: const Key('obsdetail-health-reason'), style: t.textTheme.bodyMedium?.copyWith(color: n.bad ? t.colorScheme.error : null)),
        ),
    ]);
  }
}
