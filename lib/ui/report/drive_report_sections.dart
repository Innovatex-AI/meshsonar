// Drive report v2 sections, each a ChartFrame (chart or table, numbers in the semantics): SNR over the drive (the old
// _SnrPainter drawing, now on the chart kit), noise floor, reply RSSI, TX power, direct-link SNR by distance, heard by
// speed, GPS accuracy. Data: lib/core/drive_report.dart + drive_report_rf.dart. Units: every distance, speed and
// length goes through Units (the Settings choice); dB/dBm/% are unit-free. Times follow Settings > Map & display >
// Time zone (lib/core/time_format.dart) and each caption names the zone (Round 5 D-18). Colours keep one meaning each
// (D-14): the noise line is neutral and turns to the warning colour only when the noise is high; bars by distance take
// the colour of their own signal.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/drive_report.dart';
import '../../core/drive_stats.dart' show signalWord, signalWords;
import '../../core/rf_thresholds.dart';
import '../../core/time_format.dart' as tf;
import '../../core/units.dart';
import '../app.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../sessions_screen.dart' show HeardStrip;

/// The caption that names the zone the times are in: "Times are EST." / "Times are UTC.".
String timesCaption() => 'Times are ${tf.zoneLabel()}.';
String _hm(DateTime t) => tf.timeOfDay(t, showZone: false);
String _clock(DateTime t) => tf.timeOfDay(t, seconds: true, showZone: false);
String _db(double v) => v.toStringAsFixed(1);

/// Readings needed before a line is worth drawing.
const minLinePoints = 3;

/// SNR (best reply per ping) over time; pings that heard nothing are No-reply ticks on the floor. Plus the heard strip.
class SnrSection extends StatelessWidget {
  final DriveReport report;
  const SnrSection({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final m = MeshSonarColors.of(context);
    final t = Theme.of(context);
    final pts = report.snrSeries;
    final measured = [for (final p in pts) if (p.snr != null) p.snr!]..sort();
    final silent = pts.where((p) => !p.heard).length;
    final heardNoSnr = pts.where((p) => p.heard && p.snr == null).length;
    final median = measured.isEmpty ? null : measured[measured.length ~/ 2];
    final summary = [
      '${pts.length} pings, ${pts.length - silent} heard, $silent heard nothing.',
      if (measured.isNotEmpty) 'Best ${_db(measured.last)} dB, median ${_db(median!)} dB, worst ${_db(measured.first)} dB.',
      if (heardNoSnr > 0) '$heardNoSnr heard without an SNR reading.',
    ].join(' ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ChartFrame(
        id: 'snr',
        title: 'Signal of the strongest reply (SNR)',
        summary: summary,
        caption: timesCaption(),
        table: ChartTable(head: const ['Time', 'Heard', 'SNR (dB)'], rows: [
          for (final p in pts) [_clock(p.ts), p.heard ? 'yes' : 'no', p.snr == null ? '—' : _db(p.snr!)],
        ]),
        chart: TimeLineChart(
          series: [
            ChartSeries(name: 'SNR', points: [for (final p in pts) if (p.snr != null) (p.ts, p.snr!)], color: t.colorScheme.primary),
          ],
          yLabel: 'SNR dB',
          gridValues: const [-10, 0, 10],
          dashedGrid: {0.0},
          signedTicks: true,
          includeLo: -15,
          includeHi: 12,
          roundRange: true,
          fill: true,
          dotColor: (v) => m.forPing(heard: true, snr: v),
          dotRadius: pts.length > 400 ? 1.6 : 3.0,
          floorMarks: [for (final p in pts) if (p.snr == null) (p.ts, p.heard ? m.heardUnknown : m.silent)],
          xFormat: _hm,
          footer: 'no-reply ticks = heard nothing',
        ),
      ),
      const SizedBox(height: 14),
      Text('Heard / not heard, ping by ping', style: t.textTheme.labelMedium),
      const SizedBox(height: 6),
      Semantics(
        container: true,
        label: 'Heard or not, ping by ping: ${pts.length - silent} of ${pts.length} heard.',
        excludeSemantics: true,
        child: HeardStrip(timeline: [for (final p in pts) p.heard], snr: [for (final p in pts) p.snr], height: 22),
      ),
    ]);
  }
}

/// Noise floor the radio reported during the drive, with the -100 dBm interference line.
class NoiseSection extends StatelessWidget {
  final DriveReport report;
  const NoiseSection({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final rf = report.rf;
    final t = Theme.of(context);
    final pts = rf.noiseSeries;
    if (pts.isEmpty) {
      return Text('Your radio did not report a noise floor for this drive.', key: const Key('report-noise-none'), style: t.textTheme.bodyMedium);
    }
    final loud = pts.where((p) => p.$2 > noiseFloorInterferenceDbm).length;
    final verdict = noiseVerdict(rf.noiseMedian);
    final summary = 'Median ${_db(rf.noiseMedian!)} dBm, from ${_db(rf.noiseMin!)} to ${_db(rf.noiseMax!)} dBm, ${pts.length} readings. '
        '${loud == 0 ? 'None above' : '$loud above'} ${noiseFloorInterferenceDbm.round()} dBm, where interference is likely.';
    if (pts.length < minLinePoints) {
      return Text('Only ${pts.length} noise floor reading${pts.length == 1 ? '' : 's'}: $summary',
          key: const Key('report-noise-few'), style: t.textTheme.bodyMedium);
    }
    return ChartFrame(
      id: 'noise',
      title: 'Noise floor (dBm), lower is quieter',
      summary: summary,
      caption: '${verdict == null ? '' : '${noiseVerdictText(verdict)} '}Dashed line: ${noiseFloorInterferenceDbm.round()} dBm. ${timesCaption()}',
      table: ChartTable(head: const ['Time', 'Noise floor (dBm)'], rows: [for (final p in pts) [_clock(p.$1), _db(p.$2)]]),
      chart: TimeLineChart(
        series: [ChartSeries(name: 'Noise floor', points: pts, color: noiseLineColor(context, rf.noiseMedian))],
        yLabel: 'dBm',
        refLine: noiseFloorInterferenceDbm,
        refLabel: '${noiseFloorInterferenceDbm.round()} dBm',
        breakGap: const Duration(minutes: 5),
        xFormat: _hm,
      ),
    );
  }
}

/// Strongest reply RSSI per ping.
class RssiSection extends StatelessWidget {
  final DriveReport report;
  const RssiSection({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final rf = report.rf;
    final pts = rf.rssiSeries;
    final summary = 'Median ${_db(rf.rssiMedian!)} dBm, strongest ${_db(rf.rssiBest!)} dBm, '
        'weakest ${_db(pts.map((p) => p.$2).reduce(math.min))} dBm, ${pts.length} pings.';
    if (pts.length < minLinePoints) return Text('Reply strength: $summary', key: const Key('report-rssi-few'));
    return ChartFrame(
      id: 'rssi',
      title: 'Reply strength (RSSI, dBm), higher is stronger',
      summary: summary,
      caption: timesCaption(),
      table: ChartTable(head: const ['Time', 'RSSI (dBm)'], rows: [for (final p in pts) [_clock(p.$1), _db(p.$2)]]),
      chart: TimeLineChart(
        series: [ChartSeries(name: 'RSSI', points: pts, color: Theme.of(context).colorScheme.primary)],
        yLabel: 'dBm',
        breakGap: const Duration(minutes: 5),
        xFormat: _hm,
      ),
    );
  }
}

/// TX power: one line when it never changed, else the change points.
class TxPowerSection extends StatelessWidget {
  final DriveReport report;
  const TxPowerSection({super.key, required this.report});
  @override
  Widget build(BuildContext context) {
    final c = report.rf.txPowerChanges;
    final text = report.rf.txPowerConstant
        ? 'Transmit power: ${txPowerText(c.first.$2)}, unchanged.'
        : 'Transmit power changed ${c.length - 1} time${c.length == 2 ? '' : 's'}: '
            '${[for (final x in c) '${txPowerText(x.$2)} from ${_hm(x.$1)}'].join(', ')} (times ${tf.zoneLabel()}).';
    return Text(text, key: const Key('report-txpower'), style: Theme.of(context).textTheme.bodyMedium);
  }
}

/// Mean direct-link SNR per distance band (the website's repeater-reach bands).
class DistanceSection extends StatelessWidget {
  final DriveReport report;
  const DistanceSection({super.key, required this.report});

  static String shortLabel(DistanceBand b, Units u) => b.toM == null ? '> ${u.distance(b.fromM)}' : '≤ ${u.distance(b.toM!)}';

  @override
  Widget build(BuildContext context) {
    final u = AppScope.unitsOf(context);
    final bands = report.rf.snrByDistance;
    final withData = bands.where((b) => b.n > 0).toList();
    final means = [for (final b in withData) b.meanSnr!];
    final base = math.min(-20.0, means.isEmpty ? -20.0 : (means.reduce(math.min) / 5).floor() * 5.0 - 5);
    final summary = [
      for (final b in withData)
        '${distanceBandLabel(b, u)}: mean ${_db(b.meanSnr!)} dB from ${b.n} reading${b.n == 1 ? '' : 's'}.',
    ].join(' ');
    return ChartFrame(
      id: 'distance',
      title: 'Signal by distance to the repeater',
      summary: summary,
      caption: 'Direct replies only (1 hop, or a neighbour reply) from repeaters with a known position. Bars start at '
          '${base.round()} dB; taller is a stronger signal, and each bar has the colour of its signal. Same distance bands '
          'as the website\'s repeater reach.',
      table: ChartTable(head: const ['Distance', 'Readings', 'Repeaters', 'Mean SNR (dB)', 'Best SNR (dB)'], rows: [
        for (final b in bands)
          [
            distanceBandLabel(b, u),
            '${b.n}',
            '${b.repeaters}',
            b.meanSnr == null ? '—' : _db(b.meanSnr!),
            b.bestSnr == null ? '—' : _db(b.bestSnr!),
          ],
      ]),
      chart: BarChart(
        labels: [for (final b in bands) shortLabel(b, u)],
        series: [BarSeries(name: 'Mean SNR', values: [for (final b in bands) b.meanSnr], color: MeshSonarColors.of(context).snrMid)],
        colorOf: (_, v) => MeshSonarColors.of(context).forPing(heard: true, snr: v),
        base: base,
        yLabel: 'SNR dB',
      ),
    );
  }
}

/// Heard % per speed band.
class SpeedSection extends StatelessWidget {
  final DriveReport report;
  const SpeedSection({super.key, required this.report});

  static String shortLabel(SpeedBand b, Units u) => b.toMps == null ? '> ${u.speed(b.fromMps)}' : '≤ ${u.speed(b.toMps!)}';

  @override
  Widget build(BuildContext context) {
    final u = AppScope.unitsOf(context);
    final bands = report.rf.heardBySpeed;
    final summary = [
      for (final b in bands)
        if (b.pings > 0) '${speedBandLabel(b, u)}: ${b.heardPercent}% of ${b.pings} pings heard.',
    ].join(' ');
    return ChartFrame(
      id: 'speed',
      title: 'Heard by speed',
      summary: summary,
      caption: 'Pings that recorded a speed. Faster driving spreads pings further apart and can hear less.',
      table: ChartTable(head: const ['Speed', 'Pings', 'Heard', 'Heard %'], rows: [
        for (final b in bands) [speedBandLabel(b, u), '${b.pings}', '${b.heard}', b.heardPercent == null ? '—' : '${b.heardPercent}%'],
      ]),
      chart: BarChart(
        labels: [for (final b in bands) shortLabel(b, u)],
        series: [BarSeries(name: 'Heard %', values: [for (final b in bands) b.heardPercent?.toDouble()], color: Theme.of(context).colorScheme.primary)],
        yLabel: '% heard',
      ),
    );
  }
}

/// GPS accuracy tiles.
class GpsSection extends StatelessWidget {
  final GpsQuality gps;
  const GpsSection({super.key, required this.gps});
  @override
  Widget build(BuildContext context) {
    final u = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final tiles = [
      ('Median accuracy', u.shortLength(gps.medianM), 'report-gps-median'),
      ('90% of fixes within', u.shortLength(gps.p90M), 'report-gps-p90'),
      ('Worse than ${u.shortLength(poorGpsAccuracyM)}', '${gps.poor} of ${gps.n}', 'report-gps-poor'),
    ];
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final (label, value, key) in tiles)
        Container(
          constraints: const BoxConstraints(minWidth: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.textTheme.labelMedium),
            const SizedBox(height: 2),
            Text(value, key: Key(key), style: numberStyle(context, size: 22)),
          ]),
        ),
    ]);
  }
}

/// The noise floor line: neutral, and the warning colour only when the noise is high (above the interference line).
Color noiseLineColor(BuildContext context, double? medianDbm) => noiseVerdict(medianDbm) == NoiseVerdict.interference
    ? MeshSonarColors.of(context).warning
    : Theme.of(context).colorScheme.onSurfaceVariant;

// ---------------------------------------------------------------- one-line readings (Radio details, Round 5 D-11)

/// "Noise floor: healthy, -111 dBm".
String noiseReading(DriveRf rf) {
  final v = noiseVerdict(rf.noiseMedian);
  if (v == null) return 'Noise floor: not reported';
  final word = switch (v) { NoiseVerdict.normal => 'healthy', NoiseVerdict.elevated => 'raised', NoiseVerdict.interference => 'likely interference' };
  return 'Noise floor: $word, ${rf.noiseMedian!.round()} dBm';
}

/// "Reply strength: median -95 dBm, strongest -80 dBm".
String rssiReading(DriveRf rf) => 'Reply strength: median ${rf.rssiMedian!.round()} dBm, strongest ${rf.rssiBest!.round()} dBm';

/// "Transmit power: 22 dBm, unchanged" / "Transmit power: changed 2 times".
String txPowerReading(DriveRf rf) {
  final c = rf.txPowerChanges;
  return rf.txPowerConstant
      ? 'Transmit power: ${txPowerText(c.first.$2)}, unchanged'
      : 'Transmit power: changed ${c.length - 1} time${c.length == 2 ? '' : 's'}';
}

/// "Echoes: 80% direct".
String hopsReading(Map<int, int> hops) {
  final total = hops.values.fold<int>(0, (a, b) => a + b);
  if (total == 0) return 'Echoes: none';
  return 'Echoes: ${(100 * (hops[1] ?? 0) / total).round()}% direct';
}

/// "Signal by distance: Strong under 1.0 km, Weak at 10 km and more" (the nearest and the farthest band with replies).
String distanceReading(DriveRf rf, Units u) {
  final b = rf.snrByDistance.where((x) => x.n > 0).toList();
  if (b.isEmpty) return 'Signal by distance: no direct replies';
  String one(DistanceBand x) => '${signalWord(x.meanSnr!)} ${x.fromM == 0 ? '' : 'at '}${distanceBandLabel(x, u)}';
  return b.length == 1 ? 'Signal by distance: ${one(b.first)}' : 'Signal by distance: ${one(b.first)}, ${one(b.last).toLowerCase()}';
}

/// "Heard by speed: 90% under 18 km/h, 60% at 90 km/h and faster".
String speedReading(DriveRf rf, Units u) {
  final b = rf.heardBySpeed.where((x) => x.pings > 0).toList();
  if (b.isEmpty) return 'Heard by speed: no speed recorded';
  String one(SpeedBand x) => '${x.heardPercent}% ${x.fromMps == 0 ? '' : 'at '}${speedBandLabel(x, u)}';
  return b.length == 1 ? 'Heard by speed: ${one(b.first)}' : 'Heard by speed: ${one(b.first)}, ${one(b.last)}';
}

/// "GPS: good, within 19 ft" (the median fix; good within 10 m, fair up to the poor-fix line, poor beyond).
String gpsReading(GpsQuality g, Units u) {
  final word = g.medianM <= 10 ? 'good' : (g.medianM <= poorGpsAccuracyM ? 'fair' : 'poor');
  return 'GPS: $word, within ${u.shortLength(g.medianM)}';
}

/// "Best signal: Strong (10.5 dB)".
String bestSignalReading(double? snr) => 'Best signal: ${signalWords(snr)}';
