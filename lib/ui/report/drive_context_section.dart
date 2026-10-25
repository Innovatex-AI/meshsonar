// Drive report: the phone and radio context recorded with the drive (stream 7): phone barometer, GPS altitude, phone
// battery, radio battery, plus the radio's uptime, airtime, packet counters, storage and error flags, and the phone /
// radio details. Loaded from the context stored beside the drive (lib/core/drive_context.dart), summarised by
// lib/core/drive_context_report.dart. Pressure and heights go through Units; volts, %, dB are unit-free.
import 'package:flutter/material.dart';

import '../../app/drive_context_hook.dart' show contextLedgerOf;
import '../../core/drive_context.dart';
import '../../core/drive_context_report.dart';
import '../../core/drive_stats.dart' show formatDuration;
import '../../core/model.dart';
import '../app.dart';
import '../charts/bar_chart.dart';
import '../charts/chart_frame.dart';
import '../charts/time_line_chart.dart';
import '../widgets.dart';

const _localTime = 'Times are your phone\'s local time.';
String _hm(DateTime t) => formatTime(t).substring(0, 5);
const _minLine = 3;

/// Loads [sessionId]'s context; null when the drive store keeps none.
Future<DriveContextReport?> loadDriveContextReport(AppStateLike s, String sessionId, List<DrivePing> pings) async {
  final ledger = s.ledger;
  if (ledger == null) return null;
  return DriveContextReport.compute(
    samples: await ledger.samples(sessionId),
    pingContexts: await ledger.pingContexts(sessionId),
    session: await ledger.sessionContext(sessionId),
    pings: pings,
  );
}

/// The part of AppState this section needs (keeps the loader testable).
class AppStateLike {
  final DriveContextLedger? ledger;
  const AppStateLike(this.ledger);
}

class DriveContextSection extends StatefulWidget {
  final String sessionId;
  final List<DrivePing> pings;
  const DriveContextSection({super.key, required this.sessionId, required this.pings});

  @override
  State<DriveContextSection> createState() => _DriveContextSectionState();
}

class _DriveContextSectionState extends State<DriveContextSection> {
  Future<DriveContextReport?>? _load;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load ??= loadDriveContextReport(
        AppStateLike(contextLedgerOf(AppScope.read(context).services)), widget.sessionId, widget.pings);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return FutureBuilder<DriveContextReport?>(
      future: _load,
      builder: (context, snap) {
        Widget body;
        if (snap.hasError) {
          body = Text('Couldn\'t read the phone and radio context of this drive.',
              key: const Key('report-context-error'), style: t.textTheme.bodyMedium);
        } else if (snap.connectionState != ConnectionState.done) {
          body = const Padding(
              padding: EdgeInsets.all(8), child: Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))));
        } else if (snap.data == null || snap.data!.isEmpty) {
          body = Text(
              'No phone or radio context was recorded with this drive. It is recorded during a drive while its '
              'categories are on in Settings > Privacy & data sharing.',
              key: const Key('report-context-none'),
              style: t.textTheme.bodyMedium);
        } else {
          body = _ContextBody(report: snap.data!);
        }
        return Column(key: const Key('report-context'), crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 22, 6, 8),
            child: Row(children: [
              Icon(Icons.sensors, size: 18, color: t.colorScheme.primary),
              const SizedBox(width: 8),
              Text('PHONE AND RADIO CONTEXT',
                  style: t.textTheme.labelLarge
                      ?.copyWith(color: t.colorScheme.primary, fontWeight: FontWeight.w800, letterSpacing: 0.8)),
            ]),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: t.colorScheme.surface,
              borderRadius: BorderRadius.circular(Corners.card),
              border: Border.all(color: t.colorScheme.outlineVariant),
            ),
            child: body,
          ),
        ]);
      },
    );
  }
}

class _ContextBody extends StatelessWidget {
  final DriveContextReport report;
  const _ContextBody({required this.report});

  @override
  Widget build(BuildContext context) {
    final r = report;
    final u = AppScope.unitsOf(context);
    final t = Theme.of(context);
    final pal = chartPalette(context);
    final parts = <Widget>[
      Text('Recorded on this phone with the drive. Not uploaded: the server does not accept it yet.',
          style: t.textTheme.bodySmall),
    ];
    void add(Widget w) => parts.addAll([const SizedBox(height: 16), w]);

    if (r.pressureHpa.isNotEmpty) {
      add(_series(
        id: 'ctx-pressure',
        title: 'Air pressure (${u.pressureUnit}), phone barometer',
        points: r.pressureHpa,
        value: u.pressureValue,
        text: u.pressure,
        yLabel: u.pressureUnit,
        color: pal[0],
        caption: 'Measured inside the car by the phone (cabin pressure, close to outside pressure); not a weather '
            'station. $_localTime',
      ));
    }
    if (r.altitudeM.isNotEmpty) {
      add(_series(
        id: 'ctx-altitude',
        title: 'GPS altitude (${u.heightUnit})',
        points: r.altitudeM,
        value: u.heightValue,
        text: u.height,
        yLabel: u.heightUnit,
        color: pal[2],
        caption: '${r.medianAltitudeAccuracyM == null ? '' : 'Median vertical accuracy ${u.shortLength(r.medianAltitudeAccuracyM!)}. '}'
            'One value per ping. $_localTime',
      ));
    }
    if (r.phoneBatteryPct.isNotEmpty) {
      add(_series(
        id: 'ctx-phone-battery',
        title: 'Phone battery (%)',
        points: r.phoneBatteryPct,
        value: (v) => v,
        text: (v) => '${v.round()}%',
        yLabel: '%',
        color: pal[3],
        caption: [
          if (r.phoneBatteryStates.isNotEmpty) 'Seen: ${r.phoneBatteryStates.map((s) => s.name).join(', ')}.',
          if (r.lowPowerSeen) 'Low Power Mode was on.',
          _localTime,
        ].join(' '),
      ));
    }
    if (r.radioBatteryMv.isNotEmpty) {
      add(_series(
        id: 'ctx-radio-battery',
        title: 'Radio battery (V)',
        points: r.radioBatteryMv,
        value: (mv) => mv / 1000,
        text: (mv) => '${(mv / 1000).toStringAsFixed(2)} V',
        yLabel: 'V',
        color: pal[1],
        caption: 'From the radio\'s own battery reading, once a minute. $_localTime',
      ));
    }
    if (r.radioTempC.isNotEmpty) {
      add(_series(
        id: 'ctx-radio-temp',
        title: 'Radio chip temperature (${u.temperatureUnit})',
        points: r.radioTempC,
        value: u.temperatureValue,
        text: (c) => u.temperature(c),
        yLabel: u.temperatureUnit,
        color: pal[4],
        caption: 'The radio\'s processor temperature from its own telemetry, not air temperature. $_localTime',
      ));
    }
    if (r.tempBands.isNotEmpty) {
      String band(TempBand b) => '${u.temperature(b.fromC)} to ${u.temperature(b.fromC + bandWidthC)}';
      String db(double? v) => v == null ? '—' : v.toStringAsFixed(1);
      final summary = [
        for (final b in r.tempBands)
          '${band(b)}: ${b.pings} ping${b.pings == 1 ? '' : 's'}, noise floor ${db(b.meanNoiseDbm)} dBm, best SNR '
              '${db(b.meanBestSnrDb)} dB',
      ].join('. ');
      add(ChartFrame(
        id: 'ctx-temp-bands',
        title: 'Noise floor and SNR by radio temperature',
        summary: '$summary.',
        caption: 'Mean per ${bandWidthC.round()}-degree band (°C) of the radio chip temperature; bars show the mean noise '
            'floor above -130 dBm. SNR is the best reply per ping. Few pings in a band = a weak signal.',
        startWithTable: r.tempBands.length < 2,
        table: ChartTable(head: const ['Radio temperature', 'Pings', 'Noise floor (dBm)', 'Best SNR (dB)'], rows: [
          for (final b in r.tempBands) [band(b), '${b.pings}', db(b.meanNoiseDbm), db(b.meanBestSnrDb)],
        ]),
        chart: BarChart(
          labels: [for (final b in r.tempBands) u.temperature(b.fromC)],
          series: [BarSeries(name: 'Noise floor', values: [for (final b in r.tempBands) b.meanNoiseDbm], color: pal[2])],
          base: -130,
          yLabel: 'dBm',
        ),
      ));
    }

    final tiles = <(String, String, String)>[
      if (r.lastUptimeS != null) ('Radio uptime', formatDuration(Duration(seconds: r.lastUptimeS!)), 'ctx-uptime'),
      if (r.airtimePct != null) ('Radio airtime (TX + RX)', '${r.airtimePct!.toStringAsFixed(1)}%', 'ctx-airtime'),
      if (r.packetsSent != null) ('Radio sent / heard', '${r.packetsSent} / ${r.packetsReceived}', 'ctx-packets'),
      if (r.storageTotalKb != null) ('Radio storage used', '${r.storageUsedKb} of ${r.storageTotalKb} KB', 'ctx-storage'),
      if (r.errFlags != null)
        ('Radio error flags', r.errFlags == 0 ? 'none seen' : describeErrFlags(r.errFlags!).join('; '), 'ctx-err-flags'),
      if (r.device != null)
        ('Phone', [r.device!.model, if (r.device!.os != null) '${r.device!.os} ${r.device!.osVersion ?? ''}'.trim()]
            .whereType<String>()
            .join(', '), 'ctx-device'),
      if (r.companion != null)
        ('Radio', [
          r.companion!.model,
          if (r.companion!.fwBuild != null) 'firmware ${r.companion!.fwBuild}',
          if (r.companion!.maxTxDbm != null) 'max ${r.companion!.maxTxDbm} dBm',
        ].whereType<String>().join(', '), 'ctx-radio'),
    ];
    if (tiles.isNotEmpty) {
      add(Wrap(spacing: 8, runSpacing: 8, children: [
        for (final (label, value, key) in tiles)
          Container(
            constraints: const BoxConstraints(minWidth: 140),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration:
                BoxDecoration(color: t.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(Corners.chip)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label, style: t.textTheme.labelMedium),
              const SizedBox(height: 2),
              Text(value, key: Key(key), style: t.textTheme.titleMedium),
            ]),
          ),
      ]));
      if (r.airtimePct != null) {
        parts.add(Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text('Airtime is the time your own radio spent sending and receiving packets, from its counters. It is '
              'not how busy the channel was: the radio does not report that.', style: t.textTheme.bodySmall),
        ));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: parts);
  }

  Widget _series({
    required String id,
    required String title,
    required List<TimeValue> points,
    required double Function(double) value,
    required String Function(double) text,
    required String yLabel,
    required Color color,
    required String caption,
  }) {
    final vs = [for (final p in points) p.$2];
    final lo = vs.reduce((a, b) => a < b ? a : b), hi = vs.reduce((a, b) => a > b ? a : b);
    final summary = '${points.length} reading${points.length == 1 ? '' : 's'}, from ${text(lo)} to ${text(hi)}; '
        'first ${text(points.first.$2)}, last ${text(points.last.$2)}.';
    return ChartFrame(
      id: id,
      title: title,
      summary: summary,
      caption: caption,
      startWithTable: points.length < _minLine,
      table: ChartTable(head: ['Time', yLabel], rows: [for (final p in points) [formatTime(p.$1), text(p.$2)]]),
      chart: TimeLineChart(
        series: [ChartSeries(name: title, points: [for (final p in points) (p.$1, value(p.$2))], color: color)],
        yLabel: yLabel,
        breakGap: const Duration(minutes: 5),
        xFormat: _hm,
      ),
    );
  }
}
