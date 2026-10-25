// The drive report as a PDF document (report_pdf.dart model): the report screen's numbers, its charts drawn as vector
// graphics with their numbers in words, the repeaters and the grid cells as tables. Distances and speeds in the
// person's Units (said in the header), times in the phone's local time with the zone named. The grid-cell table holds
// where the drive went (cell centres, about 220 m by 210 m), so the export menu says so. Pure Dart: no Flutter imports.
import 'api.dart' show WeatherSnapshot, openMeteoCredit;
import 'drive_report.dart';
import 'drive_weather_export.dart';
import 'report_pdf.dart';
import 'rf_thresholds.dart';
import 'units.dart';

String _two(int n) => n.toString().padLeft(2, '0');
String _db(double v) => v.toStringAsFixed(1);
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// [wall]: UTC to the phone's wall clock (default `toLocal()`); [zone]: its name for the header ("EDT").
ReportDoc driveReportPdf(
  DriveReport r, {
  required String title,
  required Units units,
  DateTime Function(DateTime utc)? wall,
  String? zone,
  String Function(Duration? d)? duration,
  List<WeatherSnapshot> weather = const [],
}) {
  final local = wall ?? (DateTime t) => t.toLocal();
  final z = zone ?? DateTime.now().timeZoneName;
  String hm(DateTime t) {
    final l = local(t);
    return '${_two(l.hour)}:${_two(l.minute)}';
  }

  String when(DateTime t) {
    final l = local(t);
    return '${_days[l.weekday - 1]} ${l.day} ${_months[l.month - 1]} ${l.year}, ${_two(l.hour)}:${_two(l.minute)}';
  }

  String dur(Duration? d) {
    if (duration != null) return duration(d);
    if (d == null) return '—';
    if (d.inMinutes < 1) return '${d.inSeconds} s';
    if (d.inHours < 1) return '${d.inMinutes} min';
    return '${d.inHours} h ${_two(d.inMinutes % 60)} min';
  }

  final u = units;
  final rf = r.rf;
  final blocks = <PdfBlock>[
    const PdfHeading('Summary'),
    PdfFacts([
      ('Distance', u.distance(r.distanceM)),
      ('Duration', dur(r.duration)),
      if (r.avgSpeedMps != null) ('Average speed', u.speed(r.avgSpeedMps!)),
      if (r.maxSpeedMps != null) ('Top speed', u.speed(r.maxSpeedMps!)),
      ('Pings sent', '${r.txPings}'),
      ('Heard', r.heardPercent == null ? '—' : '${r.heardPercent}% (${r.heardPings} of ${r.txPings})'),
      ('Grid cells', '${r.gridsMapped} (${r.gridsWithCoverage} with coverage, ${r.newGrids} new)'),
      ('Repeaters heard', '${r.repeaters.length} (${r.newRepeaters.length} new)'),
      if (r.bestSnr != null) ('Best SNR', '${_db(r.bestSnr!)} dB'),
      if (r.farthest != null) ('Farthest repeater', '${r.farthest!.label} at ${u.distance(r.farthest!.farthestM!)}'),
      if (r.bestCell != null)
        ('Best spot', 'cell at ${r.bestCell!.centerLat.toStringAsFixed(4)}, ${r.bestCell!.centerLon.toStringAsFixed(4)}'
            '${r.bestCell!.bestSnr == null ? '' : ', ${_db(r.bestCell!.bestSnr!)} dB'}, ${r.bestCell!.heardPercent}% heard'),
      if (r.worstCell != null)
        ('Quietest spot', 'cell at ${r.worstCell!.centerLat.toStringAsFixed(4)}, ${r.worstCell!.centerLon.toStringAsFixed(4)}, '
            '${r.worstCell!.pings - r.worstCell!.heard} of ${r.worstCell!.pings} pings unanswered'),
    ]),
  ];

  // SNR over the drive.
  final pts = r.snrSeries;
  if (pts.isNotEmpty) {
    final measured = [for (final p in pts) if (p.snr != null) p.snr!]..sort();
    final silent = pts.where((p) => !p.heard).length;
    blocks.add(PdfLine(
      title: 'SNR of the strongest reply',
      summary: '${pts.length} pings, ${pts.length - silent} heard, $silent heard nothing.'
          '${measured.isEmpty ? '' : ' Best ${_db(measured.last)} dB, median ${_db(measured[measured.length ~/ 2])} dB, worst ${_db(measured.first)} dB.'}',
      points: [for (final p in pts) if (p.snr != null) (p.ts, p.snr!)],
      marks: [for (final p in pts) if (!p.heard) p.ts],
      yLabel: 'SNR (dB)',
      breakGap: const Duration(minutes: 5),
      startLabel: hm(pts.first.ts),
      endLabel: hm(pts.last.ts),
      caption: 'Red ticks on the axis: pings that heard nothing. Times $z.',
    ));
  }

  // The radio side.
  if (rf.noiseSeries.length >= 3) {
    final loud = rf.noiseSeries.where((p) => p.$2 > noiseFloorInterferenceDbm).length;
    blocks.add(PdfLine(
      title: 'Noise floor (dBm), lower is quieter',
      summary: 'Median ${_db(rf.noiseMedian!)} dBm, from ${_db(rf.noiseMin!)} to ${_db(rf.noiseMax!)} dBm, ${rf.noiseSeries.length} readings. '
          '${loud == 0 ? 'None' : '$loud'} above ${noiseFloorInterferenceDbm.round()} dBm.',
      points: rf.noiseSeries,
      yLabel: 'dBm',
      refLine: noiseFloorInterferenceDbm,
      breakGap: const Duration(minutes: 5),
      startLabel: hm(rf.noiseSeries.first.$1),
      endLabel: hm(rf.noiseSeries.last.$1),
      caption: 'Dashed red line: ${noiseFloorInterferenceDbm.round()} dBm, where interference is likely.',
    ));
  } else if (rf.noiseSeries.isNotEmpty) {
    blocks.add(PdfText('Noise floor: ${rf.noiseSeries.length} reading${rf.noiseSeries.length == 1 ? '' : 's'}, median ${_db(rf.noiseMedian!)} dBm.'));
  } else {
    blocks.add(const PdfText('Your radio did not report a noise floor for this drive.', muted: true));
  }
  if (rf.rssiSeries.isNotEmpty) {
    blocks.add(PdfText('Reply RSSI: median ${_db(rf.rssiMedian!)} dBm, strongest ${_db(rf.rssiBest!)} dBm, ${rf.rssiSeries.length} pings.'));
  }
  if (rf.txPowerChanges.isNotEmpty) {
    blocks.add(PdfText(rf.txPowerConstant
        ? 'TX power ${_db(rf.txPowerChanges.first.$2)} dBm throughout.'
        : 'TX power changed ${rf.txPowerChanges.length - 1} times: '
            '${[for (final c in rf.txPowerChanges) '${_db(c.$2)} dBm from ${hm(c.$1)}'].join(', ')}.'));
  }
  if (rf.hasDistanceData) {
    final bands = rf.snrByDistance.where((b) => b.n > 0).toList();
    final means = [for (final b in bands) b.meanSnr!];
    final base = means.reduce((a, b) => a < b ? a : b).floorToDouble() - 5;
    blocks.add(PdfBars(
      title: 'Signal by distance to the repeater (mean SNR, dB)',
      summary: [for (final b in bands) '${distanceBandLabel(b, u)}: mean ${_db(b.meanSnr!)} dB from ${b.n}.'].join(' '),
      labels: [for (final b in bands) distanceBandLabel(b, u)],
      values: [for (final b in bands) b.meanSnr],
      base: base < -20 ? base : -20,
      yLabel: 'dB',
      caption: 'Direct replies only, from repeaters with a known position.',
    ));
  }
  if (rf.hasSpeedData) {
    final bands = rf.heardBySpeed.where((b) => b.pings > 0).toList();
    blocks.add(PdfBars(
      title: 'Heard % by speed',
      summary: [for (final b in bands) '${speedBandLabel(b, u)}: ${b.heardPercent}% of ${b.pings} pings.'].join(' '),
      labels: [for (final b in bands) speedBandLabel(b, u)],
      values: [for (final b in bands) b.heardPercent?.toDouble()],
      yLabel: '%',
    ));
  }
  final g = rf.gps;
  if (g != null) {
    blocks.add(PdfText('GPS accuracy: median ${u.shortLength(g.medianM)}, 90% within ${u.shortLength(g.p90M)}'
        '${g.poor > 0 ? ', ${g.poor} of ${g.n} worse than ${u.shortLength(poorGpsAccuracyM)}' : ''}.'));
  }

  blocks.addAll(weatherPdfBlocks(weather, u, hour: (t) {
    final l = local(t);
    return '${_two(l.day)} ${_months[l.month - 1]} ${hm(t)}';
  }, zone: z));

  blocks
    ..add(PdfTable(
      title: 'Repeaters heard (${r.repeaters.length})',
      head: const ['Repeater', 'Id', 'Times heard', 'Best SNR (dB)', 'Farthest', 'First heard', 'New'],
      numeric: const {2, 3, 4},
      rows: [
        for (final x in r.repeaters)
          [
            x.label,
            x.id.toUpperCase(),
            '${x.timesHeard}',
            x.bestSnr == null ? '—' : _db(x.bestSnr!),
            x.farthestM == null ? '—' : u.distance(x.farthestM!),
            x.firstHeardAt == null ? '—' : hm(x.firstHeardAt!),
            x.isNew ? 'new' : '',
          ],
      ],
      note: r.earlierDrives == 0 ? 'First drive on this phone: nothing is marked new.' : 'New = not heard on the ${r.earlierDrives} earlier drives on this phone.',
    ))
    ..add(PdfTable(
      title: 'Grid cells (${r.cells.length})',
      head: const ['Cell centre', 'Pings', 'Heard %', 'Best SNR (dB)', 'New'],
      numeric: const {1, 2, 3},
      rows: [
        for (final c in r.cells)
          [
            '${c.centerLat.toStringAsFixed(4)}, ${c.centerLon.toStringAsFixed(4)}',
            '${c.pings}',
            '${c.heardPercent}%',
            c.bestSnr == null ? '—' : _db(c.bestSnr!),
            c.isNew ? 'new' : '',
          ],
      ],
      note: 'Cells are the website\'s coverage grid (0.002° by 0.0025°, about ${u.shortLength(220)} by ${u.shortLength(210)}).',
    ));

  return ReportDoc(
    title: 'MeshSonar drive report: $title',
    subtitle: [
      'Started ${when(r.session.startedAt)} ($z). Times are your phone\'s local time.',
      'Units: ${u.description}. Contains where you drove (grid cells).',
      if (weather.isNotEmpty) openMeteoCredit,
    ],
    blocks: blocks,
    footer: 'Recorded with MeshSonar (meshsonar.com). The CSV export has every ping.',
  );
}
