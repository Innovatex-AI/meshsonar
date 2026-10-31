// Noise floor and radio health, live. Samples only while this screen is open (NoiseMonitor, lowest command priority).
// Thresholds and wording are the website's (lib/core/rf_thresholds.dart).
import 'package:flutter/material.dart';

import '../../core/rf_thresholds.dart';
import '../../radio/protocol.dart' show RadioErrFlag;
import '../../radio/tools/noise_monitor.dart';
import '../../radio/tools/radio_tools.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../theme.dart';
import 'tool_kit.dart';

/// The words for the radio's sticky error-flag bitmask (src/Dispatcher.h), empty when none is set.
List<String> noiseErrorWords(int? flags) => [
      if (flags != null && flags & RadioErrFlag.queueFull != 0) 'The send queue filled up at some point since boot.',
      if (flags != null && flags & RadioErrFlag.cadTimeout != 0) 'Channel-activity detection timed out: the channel was busy for a long time.',
      if (flags != null && flags & RadioErrFlag.startRxTimeout != 0) 'The receiver failed to start in time.',
    ];

class NoiseScreen extends StatefulWidget {
  const NoiseScreen({super.key});
  @override
  State<NoiseScreen> createState() => _NoiseScreenState();
}

class _NoiseScreenState extends State<NoiseScreen> {
  RadioTools? _tools;

  @override
  void dispose() {
    _tools?.noise.stop();
    super.dispose();
  }

  void _attach(RadioTools tools) {
    if (identical(_tools, tools)) return;
    _tools?.noise.stop();
    _tools = tools;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_tools, tools)) tools.noise.start();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ToolPage(
      id: 'noise',
      title: 'Noise floor and health',
      builder: (context, host, tools) {
        _attach(tools);
        return ToolListener(
          sources: [tools.noise.changed],
          builder: (context) => _NoiseBody(tools: tools),
        );
      },
    );
  }
}

class _NoiseBody extends StatelessWidget {
  final RadioTools tools;
  const _NoiseBody({required this.tools});

  static const _intervals = [5, 10, 30, 60];

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final n = tools.noise;
    final stats = n.stats;
    final samples = n.samples;
    return ListView(
      key: const Key('noise-list'),
      padding: const EdgeInsets.fromLTRB(Gap.l, Gap.m, Gap.l, Gap.xl),
      children: [
        Text('Sampling only while this screen is open. Reads cost a few bytes on Bluetooth and nothing on air.',
            key: const Key('noise-sampling-note'), style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        Row(children: [
          Text('Every', style: t.textTheme.bodyMedium),
          const SizedBox(width: Gap.s),
          Expanded(
            child: SegmentedButton<int>(
              key: const Key('noise-interval'),
              showSelectedIcon: false,
              style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.padded, minimumSize: WidgetStatePropertyAll(Size(kToolTarget, kToolTarget))),
              segments: [for (final s in _intervals) ButtonSegment(value: s, label: Text('$s s'), tooltip: 'Read every $s seconds')],
              selected: {n.interval.inSeconds},
              onSelectionChanged: (s) => n.setInterval(Duration(seconds: s.first)),
            ),
          ),
        ]),
        const SizedBox(height: Gap.m),
        if (n.unsupported)
          const NoteCard('This radio’s firmware does not report noise (needs version 8 or newer).',
              key: Key('noise-unsupported'), kind: NoteKind.caution, title: 'No noise readings')
        else if (samples.isEmpty)
          const NoteCard('Waiting for the first reading…', key: Key('noise-waiting'))
        else ...[
          _verdict(context, n),
          const SizedBox(height: Gap.m),
          if (stats == null)
            const NoteCard('The radio has not measured its noise floor yet. It reports 0 until it has.', key: Key('noise-unmeasured'))
          else ...[
            _tiles(context, stats),
            const SizedBox(height: Gap.l),
            _chart(context, n, stats),
          ],
          const SizedBox(height: Gap.m),
          _lastHeard(context, n),
        ],
        const ToolHeading('Radio counters'),
        _counters(context, n),
        const ToolHeading('MeshSonar’s own airtime'),
        _own(context, n.ownAirtime),
        const SizedBox(height: Gap.l),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('noise-clear'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(kToolTarget, kToolTarget)),
            onPressed: samples.isEmpty ? null : n.clear,
            icon: const Icon(Icons.delete_outline),
            label: const Text('Clear readings'),
          ),
        ),
      ],
    );
  }

  Widget _verdict(BuildContext context, NoiseMonitor n) {
    final v = n.verdict;
    if (v == null) return const SizedBox.shrink();
    final kind = switch (v) { NoiseVerdict.normal => NoteKind.good, NoiseVerdict.elevated => NoteKind.caution, NoiseVerdict.interference => NoteKind.problem };
    final t = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      NoteCard(n.interpretation!, key: const Key('noise-verdict'), kind: kind, title: n.verdictWord),
      const SizedBox(height: Gap.xs),
      Text('Same thresholds as the website’s RF analysis.', style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
    ]);
  }

  Widget _tile(BuildContext context, String label, String value) {
    final t = Theme.of(context);
    return Semantics(
      container: true,
      label: '$label $value',
      excludeSemantics: true,
      child: Container(
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.small)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: t.textTheme.labelMedium?.copyWith(color: t.colorScheme.onSurfaceVariant)),
          const SizedBox(height: Gap.xs),
          Text(value, style: numberStyle(context, size: 22)),
        ]),
      ),
    );
  }

  Widget _tiles(BuildContext context, NoiseStats s) {
    String d(double v) => '${v.round()} dBm';
    return Wrap(key: const Key('noise-tiles'), spacing: Gap.s, runSpacing: Gap.s, children: [
      for (final (l, v) in [('Lowest', d(s.min)), ('Average', d(s.avg)), ('Highest', d(s.max)), ('Readings', '${s.count}')])
        SizedBox(width: 150, child: _tile(context, l, v)),
    ]);
  }

  Widget _chart(BuildContext context, NoiseMonitor n, NoiseStats stats) {
    final m = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final pts = [for (final s in n.samples) if (s.noiseDbm != null) (s.at, s.noiseDbm!.toDouble())];
    final spikes = n.spikes();
    final span = pts.length < 2 ? Duration.zero : pts.last.$1.difference(pts.first.$1);
    final spanText = span.inSeconds < 90 ? '${span.inSeconds} seconds' : '${(span.inSeconds / 60).round()} minutes';
    final summary = 'Noise floor averaged ${stats.avg.round()} dBm over $spanText (lowest ${stats.min.round()}, highest ${stats.max.round()}). '
        '${n.verdictWord ?? ''}.${spikes.isEmpty ? '' : ' ${spikes.length} spike${spikes.length == 1 ? '' : 's'}.'}';
    return ChartFrame(
      id: 'noise',
      title: 'Noise floor',
      summary: summary,
      caption: 'dBm; lower is quieter. Dashed line: interference above ${noiseFloorInterferenceDbm.round()} dBm.'
          '${spikes.isEmpty ? '' : ' Ticks mark spikes.'}',
      table: ChartTable(
        head: const ['Time', 'Noise dBm', 'Last RSSI dBm'],
        rows: [
          for (final s in n.samples.reversed)
            [fmtClock(s.at), s.noiseDbm?.toString() ?? 'not measured', s.lastRssiDbm?.toString() ?? '–'],
        ],
      ),
      chart: pts.length < 2
          ? Center(child: Text('Needs two readings to draw a line.', style: t.textTheme.bodySmall))
          : TimeLineChart(
              series: [ChartSeries(name: 'Noise floor', points: pts, color: m.snrStrong)],
              yLabel: 'dBm',
              xFormat: fmtClock,
              gridValues: [-120, -110, noiseFloorInterferenceDbm, -90],
              includeLo: -120,
              includeHi: -90,
              refLine: noiseFloorInterferenceDbm,
              refLabel: 'Interference above ${noiseFloorInterferenceDbm.round()}',
              refColor: t.colorScheme.error,
              breakGap: n.interval * 3,
              fill: true,
              floorMarks: [for (final s in spikes) (s.at, t.colorScheme.error)],
            ),
    );
  }

  Widget _lastHeard(BuildContext context, NoiseMonitor n) {
    final t = Theme.of(context);
    final s = n.latest;
    final text = s == null || s.lastRssiDbm == null
        ? 'Last packet heard: nothing yet.'
        : 'Last packet heard: ${s.lastRssiDbm} dBm, SNR ${fmtSnr(s.lastSnrDb)}.';
    return Text(text, key: const Key('noise-last-heard'), style: t.textTheme.bodyMedium);
  }

  Widget _counters(BuildContext context, NoiseMonitor n) {
    final t = Theme.of(context);
    final c = n.core;
    final air = n.radioAirSinceFirst;
    final flags = noiseErrorWords(c.errFlags);
    String secs(int? v) => v == null ? 'not yet known' : '$v s';
    return Column(key: const Key('noise-counters'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(c.queueLen == null ? 'Send queue: not read yet.' : '${c.queueLen} packet${c.queueLen == 1 ? '' : 's'} waiting to send.', style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.xs),
      Text(c.recvErrors == null ? 'Receive errors: not read yet.' : 'Packets received with errors since boot: ${c.recvErrors}.', style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.xs),
      Text('The radio reports ${secs(air.txSecs)} transmitting and ${secs(air.rxSecs)} receiving since the first reading here.', style: t.textTheme.bodyMedium),
      const SizedBox(height: Gap.s),
      if (flags.isEmpty)
        const NoteCard('No radio error flags are set.', key: Key('noise-flags-none'), kind: NoteKind.good)
      else
        NoteCard(flags.join(' '), key: const Key('noise-flags'), kind: NoteKind.caution, title: 'Error flags (stay set until the radio restarts)'),
    ]);
  }

  Widget _own(BuildContext context, OwnAirtime o) {
    final t = Theme.of(context);
    final pct = (o.fractionOfCap * 100);
    final pctText = pct < 10 ? pct.toStringAsFixed(1) : pct.round().toString();
    return Column(key: const Key('noise-own'), crossAxisAlignment: CrossAxisAlignment.start, children: [
      Semantics(
        container: true,
        label: 'Transmitted ${fmtAir(o.lastHourMs)} in the last hour of ${fmtAir(o.capMs)} allowed, $pctText percent',
        excludeSemantics: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${fmtAir(o.lastHourMs)} of ${fmtAir(o.capMs)} used in the last hour ($pctText%)', style: t.textTheme.bodyMedium),
          const SizedBox(height: Gap.xs),
          LinearProgressIndicator(value: o.fractionOfCap.clamp(0.0, 1.0), minHeight: 8, borderRadius: BorderRadius.circular(4)),
        ]),
      ),
      const SizedBox(height: Gap.xs),
      Text('The limit is 1% of an hour: a cautious default for an unknown region, not legal advice.',
          style: t.textTheme.bodySmall?.copyWith(color: t.colorScheme.onSurfaceVariant)),
      const SizedBox(height: Gap.s),
      Text('Pings in the last 10 minutes: ${fmtAir(o.pingsLast10MinMs)} on air. ${o.pingsSent} ping${o.pingsSent == 1 ? '' : 's'} sent and ${o.userSends} message${o.userSends == 1 ? '' : 's'} sent this session.',
          style: t.textTheme.bodyMedium),
    ]);
  }
}
