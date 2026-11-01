// Region tabs of vertical W (website /analysis tabs "Hops and routes", "Silent repeaters", "Wardrive share"): native, same data
// (lib/core/region_packet_analytics_api.dart). Every tab shows its window, the age of the newest packet and the sample size;
// an empty window is said plainly and nothing is drawn. The source holds no packet text: the wardrive view reports the group-text
// share (the ceiling for the wardrive share) and says why. Airtime is modelled on the phone with the region's radio preset
// (lib/core/airtime_share.dart, pinned to the website's numbers).
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../core/airtime_share.dart';
import '../../core/region_packet_analytics_api.dart';
import '../app.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../theme.dart';
import 'region_common.dart';
import 'region_dataset_view.dart';

String _pct(double v, [int digits = 0]) => '${(v * 100).toStringAsFixed(digits)}%';
String _hopLabel(int h) => h >= 16 ? '16+' : '$h';

/// "Last 24 h - 130 observations - 90 distinct packets - 4 observers - newest packet 2 min ago".
String sampleLine(PacketSample s, {DateTime? now, String? extra}) {
  final b = StringBuffer('Last ${s.windowHours} h');
  b.write(s.observations == null ? ' - no sample' : ' - ${groupInt(s.observations!)} observation${s.observations == 1 ? '' : 's'}');
  if (s.packets != null) b.write(' - ${groupInt(s.packets!)} distinct packets');
  if (s.observers != null) b.write(' - ${groupInt(s.observers!)} observer${s.observers == 1 ? '' : 's'}');
  b.write(' - newest packet ${s.newest == null ? 'none' : agoText(s.newest, now: now)}');
  if (extra != null) b.write(' - $extra');
  return '$b.';
}

class _SampleText extends StatelessWidget {
  final String text;
  const _SampleText(this.text);
  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Text(text, key: const Key('sample-line'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    );
  }
}

class _HoursPicker extends StatelessWidget {
  final int value;
  final ValueChanged<int> onChanged;
  const _HoursPicker({required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.s, Gap.l, 0),
        child: SegmentedButton<int>(
          key: const Key('hours-picker'),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 6, label: Text('6 h')),
            ButtonSegment(value: 24, label: Text('24 h')),
            ButtonSegment(value: 48, label: Text('48 h')),
          ],
          selected: {value},
          onSelectionChanged: (v) => onChanged(v.first),
        ),
      );
}

// ---------------------------------------------------------------- hops and routes
class HopsPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;
  final http.Client? client;
  final DateTime Function() now;
  const HopsPanel({super.key, required this.baseUrl, required this.regionSlug, this.client, this.now = DateTime.now});
  @override
  State<HopsPanel> createState() => _HopsPanelState();
}

class _HopsPanelState extends State<HopsPanel> {
  int _hours = 24;
  bool _groupOnly = false;

  @override
  Widget build(BuildContext context) => Column(children: [
        _HoursPicker(value: _hours, onChanged: (h) => setState(() => _hours = h)),
        Expanded(
          child: RegionDatasetView<HopRoute>(
            id: 'hops',
            title: 'Hops and routes',
            reloadKey: '${widget.baseUrl}|${widget.regionSlug}|$_hours',
            now: widget.now,
            load: () => PacketAnalyticsApi(widget.baseUrl, client: widget.client).hopRoute(hours: _hours),
            status: (d) => d.status,
            isEmpty: (d) => (d.sample.observations ?? 0) == 0 || d.status.state.name == 'pending' || d.status.state.name == 'unavailable',
            emptyText: 'No packets in this window. Hop and route figures come from packets outside live feeds heard in this region.',
            build: (context, d) => _body(context, d),
          ),
        ),
      ]);

  List<Widget> _body(BuildContext context, HopRoute d) {
    final t = Theme.of(context);
    final m = MeshSonarColors.of(context);
    final bins = d.bins(_groupOnly);
    final n = HopRoute.totalOf(bins);
    final flood = HopRoute.floodOf(bins), direct = HopRoute.directOf(bins);
    final peak = HopRoute.peakOf(bins);
    final mean = HopRoute.meanOf(bins);
    final what = _groupOnly ? 'group texts' : 'packets';
    return [
      SegmentedButton<bool>(
        key: const Key('hops-scope'),
        showSelectedIcon: false,
        segments: const [ButtonSegment(value: false, label: Text('All packets')), ButtonSegment(value: true, label: Text('Group text'))],
        selected: {_groupOnly},
        onSelectionChanged: (v) => setState(() => _groupOnly = v.first),
      ),
      const SizedBox(height: Gap.m),
      if (n > 0 && peak != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Text(
            '${_pct(flood / n)} of $what heard here were flood-routed. Most arrive after '
            '${peak.hops >= 16 ? '16 or more' : '${peak.hops}'} hop${peak.hops == 1 ? '' : 's'} (${_pct(peak.total / n)}), '
            'on average ${mean!.toStringAsFixed(1)}.',
            key: const Key('hops-finding'),
            style: t.textTheme.bodyLarge,
          ),
        ),
      FigureStrip([
        ('Observations', groupInt(n), 'A packet heard by 3 observers counts 3 times'),
        ('Flood', n == 0 ? '-' : _pct(flood / n), 'Repeated by every repeater that hears it'),
        ('Direct', n == 0 ? '-' : _pct(direct / n), 'Follow a known path'),
        ('Average hops', mean == null ? '-' : mean.toStringAsFixed(1), '16+ counts as 16'),
      ]),
      const SizedBox(height: Gap.m),
      _SampleText(sampleLine(d.sample, now: widget.now())),
      if (n == 0)
        const DatasetCard(child: Text('No group text was heard in this window.', key: Key('hops-group-empty')))
      else
        DatasetCard(
          child: ChartFrame(
            id: 'hops-hist',
            title: 'Observations by hop count',
            summary: '${groupInt(n)} observations of $what: ${groupInt(flood)} flood, ${groupInt(direct)} direct. '
                '${peak == null ? '' : 'Most at ${_hopLabel(peak.hops)} hops.'}',
            caption: 'How many repeaters had relayed a packet when an outside observer heard it, by route type.',
            height: 200,
            table: ChartTable(head: const ['Hops', 'Flood', 'Direct', 'Other'], rows: [
              for (final b in bins) [_hopLabel(b.hops), groupInt(b.flood), groupInt(b.direct), groupInt(b.other)],
            ]),
            chart: BarChart(
              labels: [for (final b in bins) _hopLabel(b.hops)],
              series: [
                BarSeries(name: 'Flood', values: [for (final b in bins) b.flood.toDouble()], color: t.colorScheme.primary),
                BarSeries(name: 'Direct', values: [for (final b in bins) b.direct.toDouble()], color: m.snrStrong),
              ],
              legend: true,
            ),
          ),
        ),
    ];
  }
}

// ---------------------------------------------------------------- silent repeaters
class SilentRepeatersPanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// Repeater keys this phone's user has claimed: those rows are marked "Yours".
  final Set<String> ownKeys;
  final http.Client? client;
  final DateTime Function() now;
  const SilentRepeatersPanel(
      {super.key, required this.baseUrl, required this.regionSlug, this.ownKeys = const {}, this.client, this.now = DateTime.now});
  @override
  State<SilentRepeatersPanel> createState() => _SilentRepeatersPanelState();
}

class _SilentRepeatersPanelState extends State<SilentRepeatersPanel> {
  String _find = '';

  @override
  Widget build(BuildContext context) => RegionDatasetView<SilentRepeaters>(
        id: 'silent',
        title: 'Silent repeaters',
        reloadKey: '${widget.baseUrl}|${widget.regionSlug}',
        now: widget.now,
        load: () => PacketAnalyticsApi(widget.baseUrl, client: widget.client).silentRepeaters(),
        status: (d) => d.status,
        isEmpty: (d) => d.status.state.name == 'pending' || d.status.state.name == 'unavailable',
        emptyText: 'No verdict yet: see the reason above. Nothing is called silent without enough relayed traffic to judge by.',
        build: (context, d) => _body(context, d),
      );

  List<Widget> _body(BuildContext context, SilentRepeaters d) {
    final t = Theme.of(context);
    final rows = d.silent.where((r) => r.matches(_find)).toList();
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Text(
          d.advertising == 0
              ? 'No repeater was heard advertising in the last 24 hours, so there is nothing to compare.'
              : d.silentCount == 0
                  ? 'All ${groupInt(d.advertising)} repeaters heard advertising also appeared as a relay hop in the last ${d.sample.windowHours} hours.'
                  : '${groupInt(d.silentCount)} of ${groupInt(d.advertising)} repeaters heard advertising never appeared as a relay hop in the last ${d.sample.windowHours} hours.',
          key: const Key('silent-finding'),
          style: t.textTheme.bodyLarge,
        ),
      ),
      FigureStrip([
        ('Repeaters listed', groupInt(d.repeaters), null),
        ('Heard advertising', groupInt(d.advertising), 'In the last 24 hours'),
        ('Seen relaying', groupInt(d.relaying), null),
        ('Silent', groupInt(d.silentCount), null),
      ]),
      const SizedBox(height: Gap.m),
      _SampleText(sampleLine(d.sample, now: widget.now(), extra: '${groupInt(d.relayEvidence)} relay hops from outside live feeds and our observers')),
      if (d.silent.isEmpty)
        const DatasetCard(child: Text('No silent repeater found.', key: Key('silent-empty')))
      else ...[
        TextField(
          key: const Key('silent-find'),
          decoration: const InputDecoration(labelText: 'Find a repeater', hintText: 'Name or key', prefixIcon: Icon(Icons.search)),
          onChanged: (v) => setState(() => _find = v),
        ),
        const SizedBox(height: Gap.m),
        if (rows.isEmpty) const Text('No repeater matches that search.', key: Key('silent-nomatch')),
        for (final r in rows) _SilentCard(r, yours: widget.ownKeys.contains(r.key), now: widget.now()),
      ],
      DatasetCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, key: const Key('silent-caveats'), children: [
          Text('What this cannot see', style: t.textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final c in d.caveats) Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('- $c', style: t.textTheme.bodySmall)),
          Text(
            'At least 300 relay hops are needed in the window before any repeater is called silent. Nothing is ever sent to a repeater: '
            'these are hints from what the network heard.',
            style: t.textTheme.bodySmall,
          ),
        ]),
      ),
    ];
  }
}

class _SilentCard extends StatelessWidget {
  final SilentRepeater r;
  final bool yours;
  final DateTime now;
  const _SilentCard(this.r, {required this.yours, required this.now});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final signal = r.signalGrade != null ? 'Grade ${r.signalGrade}' : (r.snrMeanDb != null ? '${r.snrMeanDb!.toStringAsFixed(1)} dB' : 'No signal figure');
    return Card(
      key: Key('silent-${r.key}'),
      margin: const EdgeInsets.only(bottom: Gap.m),
      child: ExpansionTile(
        title: Text('${r.title}${yours ? '  (yours)' : ''}'),
        subtitle: Text('Code ${r.hashPrefix} - last heard ${agoText(r.lastHeardAt, now: now)} - $signal'),
        childrenPadding: const EdgeInsets.fromLTRB(Gap.l, 0, Gap.l, Gap.m),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(r.hintText, style: t.textTheme.bodyMedium),
          const SizedBox(height: Gap.s),
          Text('What to check', style: t.textTheme.titleSmall),
          for (var i = 0; i < r.checks.length; i++)
            Padding(padding: const EdgeInsets.only(top: 4), child: Text('${i + 1}. ${r.checks[i]}', style: t.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- wardrive airtime share
class AirtimeSharePanel extends StatefulWidget {
  final String baseUrl;
  final String regionSlug;

  /// The viewed region's radio preset; null = MeshCore's US default, said on screen.
  final LoraRadio? radio;
  final String? radioLabel;
  final http.Client? client;
  final DateTime Function() now;
  const AirtimeSharePanel(
      {super.key, required this.baseUrl, required this.regionSlug, this.radio, this.radioLabel, this.client, this.now = DateTime.now});
  @override
  State<AirtimeSharePanel> createState() => _AirtimeSharePanelState();
}

class _AirtimeSharePanelState extends State<AirtimeSharePanel> {
  int _hours = 24;

  @override
  Widget build(BuildContext context) => Column(children: [
        _HoursPicker(value: _hours, onChanged: (h) => setState(() => _hours = h)),
        Expanded(
          child: RegionDatasetView<AirtimeShareData>(
            id: 'airtime',
            title: 'Wardrive share of airtime',
            reloadKey: '${widget.baseUrl}|${widget.regionSlug}|$_hours|${widget.radio?.sf}',
            now: widget.now,
            load: () => PacketAnalyticsApi(widget.baseUrl, client: widget.client).airtimeShare(hours: _hours),
            status: (d) => d.status,
            isEmpty: (d) => (d.transmissions ?? 0) == 0 || d.status.state.name == 'pending' || d.status.state.name == 'unavailable',
            emptyText: 'No packets in this window. The share is worked out from packets outside live feeds heard in this region.',
            build: (context, d) => _body(context, d),
          ),
        ),
      ]);

  List<Widget> _body(BuildContext context, AirtimeShareData d) {
    final t = Theme.of(context);
    final radio = widget.radio ?? LoraRadio.meshcoreUs;
    final m = d.model(radio);
    final radioText = widget.radio != null
        ? '${widget.radioLabel ?? 'this region\'s preset'} (SF${radio.sf}, ${radio.bwKhz} kHz, 4/${radio.cr})'
        : 'MeshCore\'s US default (SF${radio.sf}, ${radio.bwKhz} kHz, 4/${radio.cr}); no preset on file';
    return [
      if (m.groupTextTxShare != null)
        Padding(
          padding: const EdgeInsets.only(bottom: Gap.m),
          child: Text(
            'Group text is ${_pct(m.groupTextTxShare!)} of the unique transmissions heard in the last ${d.sample.windowHours} hours and about '
            '${_pct(m.groupTextAirtimeShare ?? 0)} of the modelled airtime. Wardrive pings are part of that share, not all of it.',
            key: const Key('airtime-finding'),
            style: t.textTheme.bodyLarge,
          ),
        ),
      FigureStrip([
        ('Group text, share of transmissions', m.groupTextTxShare == null ? '-' : _pct(m.groupTextTxShare!, 1), 'Counted, not modelled'),
        ('Group text, share of airtime', m.groupTextAirtimeShare == null ? '-' : _pct(m.groupTextAirtimeShare!, 1), 'Modelled; the ceiling for wardrive pings'),
        ('Unique transmissions', groupInt(m.transmissions), 'Same packet and path = one'),
        ('Group text airtime', '${m.groupTextAirtimeS.toStringAsFixed(1)} s', 'In ${d.sample.windowHours} h, as heard'),
      ]),
      const SizedBox(height: Gap.m),
      _SampleText(sampleLine(d.sample, now: widget.now())),
      Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Text(d.note, key: const Key('airtime-note'), style: t.textTheme.bodyMedium),
      ),
      DatasetCard(
        child: ChartFrame(
          id: 'airtime-type',
          title: 'Share of modelled airtime, by packet type',
          summary: m.byType.isEmpty
              ? 'No transmissions.'
              : '${m.byType.first.label} takes the most modelled airtime (${_pct(m.byType.first.airtimeShare)}); group text ${_pct(m.groupTextAirtimeShare ?? 0)}.',
          caption: 'Modelled at $radioText.',
          height: 200,
          table: ChartTable(head: const ['Type', 'Transmissions', 'Share', 'Airtime (s)', 'Share of airtime'], rows: [
            for (final b in m.byType)
              [b.label, groupInt(b.transmissions), _pct(b.txShare, 1), b.airtimeS.toStringAsFixed(1), _pct(b.airtimeShare, 1)],
          ]),
          chart: BarChart(
            labels: [for (final b in m.byType) b.label.length > 8 ? b.label.substring(0, 8) : b.label],
            series: [BarSeries(name: 'Share of airtime', values: [for (final b in m.byType) b.airtimeShare * 100], color: t.colorScheme.primary)],
            yLabel: '%',
          ),
        ),
      ),
      DatasetCard(
        child: ExpansionTile(
          key: const Key('airtime-assumptions'),
          tilePadding: EdgeInsets.zero,
          title: const Text('How the airtime is modelled'),
          children: [
            Text('Frame bytes = 1 header + 1 path length + hops x hash size (+4 on transport routes) + the payload assumed for the type. '
                'Time on air follows Semtech\'s formula, as in the website\'s airtime calculator.', style: t.textTheme.bodySmall),
            const SizedBox(height: 6),
            for (final a in d.assumptions) Text('${a.label}: ${a.payloadBytes} B - ${a.basis}', style: t.textTheme.bodySmall),
          ],
        ),
      ),
    ];
  }
}
