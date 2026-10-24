// The region report as a PDF document (report_pdf.dart model), from the same `region-report` body the website's
// /reports page prints: overview, repeater status, observers, RF (noise by hour, SNR histogram, noise by observer),
// hash sizes and collisions, paths, coverage. Every row of every table is printed; very wide tables keep their key
// columns and the PDF says the CSV has every column. Times are UTC like the website's report and the region CSVs
// (said in the header); the one distance (coverage km) is in the person's Units. A section whose server status is not
// "ready" says so with the server's reason. Only public data the endpoint already publishes.
// Pure Dart: no Flutter imports.
import 'region_dataset_fetch.dart';
import 'region_report_export.dart';
import 'report_pdf.dart';
import 'rf_thresholds.dart';
import 'units.dart';

String _utc(DateTime? t) => t == null ? '—' : '${t.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';
String _n(Object? v) {
  final x = jNum(v);
  if (x == null) return '—';
  return x == x.roundToDouble() ? '${x.round()}' : x.toStringAsFixed(1);
}

String _s(Object? v) => jStr(v) ?? '—';

ReportDoc regionReportPdf(RegionReportExport e, {required Units units}) {
  final j = e.json;
  Map<String, dynamic> sec(String k) => jMap(j[k]);
  String? state(String section) {
    final s = jMap(sec(section)['status']);
    final st = jStr(s['state']);
    if (st == null || st == 'ready') return null;
    final reason = jStr(s['reason']);
    return 'Server status for this section: $st${reason == null ? '' : '. $reason'}';
  }

  final blocks = <PdfBlock>[];
  void head(String title, String section) {
    blocks.add(PdfHeading(title));
    final s = state(section);
    if (s != null) blocks.add(PdfText(s, muted: true));
  }

  // Overview.
  final o = sec('overview');
  head('Overview, last 24 h', 'overview');
  blocks.add(PdfFacts([
    ('Packets', _n(o['packets24h'])),
    ('Observers online', '${_n(o['observersOnline'])} of ${_n(o['observersTotal'])}'),
    ('Repeaters', _n(o['repeaters'])),
    ('Repeaters heard in 24 h', _n(o['repeatersHeard24h'])),
    ('Last packet', _utc(jTime(o['lastPacketAt']))),
  ]));
  final pph = jMaps(o['packetsPerHour']);
  if (pph.isNotEmpty) {
    final vals = [for (final p in pph) jDbl(p['n'])];
    final known = vals.whereType<double>();
    final total = known.fold<double>(0, (a, b) => a + b);
    final peakI = vals.indexWhere((v) => v != null && v == known.reduce((a, b) => a > b ? a : b));
    blocks.add(PdfBars(
      title: 'Packets per hour',
      summary: '${_n(total)} packets in ${pph.length} hours; peak ${_n(vals[peakI])} at ${_utc(jTime(pph[peakI]['at']))}.',
      labels: [for (final p in pph) jTime(p['at']) == null ? '' : jTime(p['at'])!.hour.toString().padLeft(2, '0')],
      values: vals,
      yLabel: 'packets per hour (hour of day, UTC)',
      labelEvery: 3,
    ));
  }

  // Repeaters.
  final reps = jMaps(sec('repeaters')['rows']);
  final counts = jMap(sec('repeaters')['counts']);
  head('Repeaters (${reps.length})', 'repeaters');
  blocks
    ..add(PdfText('${_n(counts['active'])} active, ${_n(counts['quiet'])} quiet, ${_n(counts['new'])} new, ${_n(counts['stale'])} stale.'))
    ..add(PdfTable(
      title: 'Every repeater',
      head: const ['Name', 'Hash', 'Role', 'Status', 'Last heard (UTC)', 'Relays 24 h', 'Observers 24 h', 'Mean SNR (dB)'],
      numeric: const {5, 6, 7},
      rows: [
        for (final r in reps)
          [
            jStr(r['name']) ?? (jStr(r['key'])?.substring(0, 8) ?? '—'),
            _s(r['hashPrefix']),
            _s(r['role']),
            _s(r['status']),
            jTime(r['lastHeardAt']) == null ? '—' : _utc(jTime(r['lastHeardAt'])).replaceFirst(' UTC', ''),
            _n(r['relays24h']),
            _n(r['observers24h']),
            _n(r['snrMeanDb']),
          ],
      ],
      note: 'Keys, positions and the other columns are in the CSV export (${e.csvName('repeaters')}).',
    ));

  // Observers.
  final obs = jMaps(sec('observers')['rows']);
  head('Observers (${obs.length})', 'observers');
  blocks.add(PdfTable(
    title: 'Every observer',
    head: const ['Name', 'Online', 'Last packet (UTC)', 'Packets / h', 'Noise floor (dBm)', 'Nodes heard 24 h'],
    numeric: const {3, 4, 5},
    rows: [
      for (final x in obs)
        [
          jStr(x['name']) ?? (jStr(x['key'])?.substring(0, 8) ?? '—'),
          x['online'] == true ? 'yes' : 'no',
          jTime(x['lastPacketAt']) == null ? '—' : _utc(jTime(x['lastPacketAt'])).replaceFirst(' UTC', ''),
          _n(x['packetsPerHour']),
          _n(x['noiseFloorDbm']),
          _n(x['nodesHeard24h']),
        ],
    ],
  ));

  // RF.
  final rf = sec('rf');
  head('RF and noise floor', 'rf');
  final byHour = {for (final h in jMaps(rf['noiseByHour'])) if (jInt(h['hour']) != null) jInt(h['hour'])!: jDbl(h['meanDbm'])};
  if (byHour.values.any((v) => v != null)) {
    final known = [for (final e in byHour.entries) if (e.value != null) e];
    final loud = known.reduce((a, b) => b.value! > a.value! ? b : a);
    final calm = known.reduce((a, b) => b.value! < a.value! ? b : a);
    blocks.add(PdfBars(
      title: 'Noise floor by hour of day (mean dBm, UTC)',
      summary: 'Noisiest ${loud.key.toString().padLeft(2, '0')}:00 UTC at ${_n(loud.value)} dBm; quietest '
          '${calm.key.toString().padLeft(2, '0')}:00 UTC at ${_n(calm.value)} dBm.',
      labels: [for (var h = 0; h < 24; h++) '$h'],
      values: [for (var h = 0; h < 24; h++) byHour[h]],
      base: noiseBaseDbm,
      refLine: noiseFloorInterferenceDbm,
      yLabel: 'dBm (bars start at ${noiseBaseDbm.round()}; taller is noisier)',
      labelEvery: 3,
      caption: 'Dashed red line: ${noiseFloorInterferenceDbm.round()} dBm, where interference is likely.',
    ));
  } else {
    blocks.add(const PdfText('No noise floor readings.', muted: true));
  }
  final hist = jMaps(rf['snrHistogram']);
  if (hist.isNotEmpty) {
    final total = hist.fold<num>(0, (a, h) => a + (jNum(h['n']) ?? 0));
    final top = hist.reduce((a, b) => (jNum(b['n']) ?? 0) > (jNum(a['n']) ?? 0) ? b : a);
    blocks.add(PdfBars(
      title: 'SNR of received packets',
      summary: '${_n(total)} packets; most between ${_n(top['fromDb'])} and ${_n(top['toDb'])} dB (${_n(top['n'])}).',
      labels: [for (final h in hist) _n(h['fromDb'])],
      values: [for (final h in hist) jDbl(h['n'])],
      yLabel: 'packets per SNR bin (dB, bin start)',
    ));
  }
  final rfObs = jMaps(rf['observers']);
  if (rfObs.isNotEmpty) {
    blocks.add(PdfTable(
      title: 'Noise floor by observer',
      head: const ['Observer', 'Mean (dBm)', 'Max (dBm)', 'Last reading (UTC)'],
      numeric: const {1, 2},
      rows: [
        for (final x in rfObs)
          [
            jStr(x['name']) ?? (jStr(x['key'])?.substring(0, 8) ?? '—'),
            _n(x['meanDbm']),
            _n(x['maxDbm']),
            () {
              final s = jMaps(x['series']);
              return s.isEmpty ? '—' : _utc(jTime(s.last['at'])).replaceFirst(' UTC', '');
            }(),
          ],
      ],
    ));
  }

  // Hash sizes.
  final hash = sec('hash');
  head('Hash sizes', 'hash');
  blocks
    ..add(PdfTable(
      title: 'Nodes by hash size',
      head: const ['Bytes', 'Nodes'],
      numeric: const {0, 1},
      rows: [for (final x in jMaps(hash['sizes'])) [_n(x['bytes']), _n(x['nodes'])]],
    ))
    ..add(PdfTable(
      title: 'Shared hash prefixes',
      head: const ['Prefix', 'Nodes', 'Who'],
      numeric: const {1},
      rows: [
        for (final x in jMaps(hash['collisions']))
          [
            _s(x['prefix']),
            '${jMaps(x['nodes']).length}',
            jMaps(x['nodes']).map((n) => jStr(n['name']) ?? (jStr(n['key'])?.substring(0, 8) ?? '?')).join('; '),
          ],
      ],
    ));

  // Paths.
  final paths = sec('paths');
  head('Paths', 'paths');
  final hops = jMaps(paths['hopHistogram']);
  final flood = jDbl(paths['floodShare']);
  if (hops.isNotEmpty) {
    final total = hops.fold<num>(0, (a, h) => a + (jNum(h['n']) ?? 0));
    final mean = total == 0 ? null : hops.fold<num>(0, (a, h) => a + (jNum(h['hops']) ?? 0) * (jNum(h['n']) ?? 0)) / total;
    blocks.add(PdfBars(
      title: 'Hops per packet',
      summary: '${_n(total)} packets${mean == null ? '' : ', average ${mean.toStringAsFixed(1)} hops'}'
          '${flood == null ? '' : ', ${(flood * 100).round()}% flooded'}.',
      labels: [for (final h in hops) _n(h['hops'])],
      values: [for (final h in hops) jDbl(h['n'])],
      yLabel: 'packets',
      labelEvery: hops.length > 24 ? (hops.length / 12).ceil() : 1,
    ));
  }
  blocks.add(PdfTable(
    title: 'Top carriers',
    head: const ['Repeater', 'Share of relayed packets'],
    numeric: const {1},
    rows: [
      for (final x in jMaps(paths['carryShare']))
        [jStr(x['name']) ?? (jStr(x['key'])?.substring(0, 8) ?? '—'), jDbl(x['share']) == null ? '—' : '${(jDbl(x['share'])! * 100).toStringAsFixed(1)}%'],
    ],
  ));

  // Coverage.
  final cov = sec('coverage');
  head('Coverage by MeshSonar drives', 'coverage');
  blocks.add(PdfFacts([
    ('Grid cells', _n(cov['cells'])),
    ('Drives', _n(cov['drives'])),
    ('Distance', jDbl(cov['km']) == null ? '—' : units.distance(jDbl(cov['km'])! * 1000)),
    ('Heard', jNum(cov['heardPct']) == null ? '—' : '${_n(cov['heardPct'])}%'),
  ]));

  final events = jMaps(o['recentEvents']);
  if (events.isNotEmpty) {
    blocks.add(PdfTable(
      title: 'Recent changes',
      head: const ['When (UTC)', 'What'],
      rows: [for (final ev in events) [_utc(jTime(ev['at'])).replaceFirst(' UTC', ''), _s(ev['detail'])]],
    ));
  }

  return ReportDoc(
    title: 'MeshSonar region report: ${e.name} (${e.code})',
    subtitle: [
      'Generated ${_utc(e.generatedAt)}. Times are UTC, like the website\'s report.',
      'Units: ${units.isImperial ? 'imperial' : 'metric'}. Public region data from the MeshSonar server.',
    ],
    blocks: blocks,
    footer: 'From MeshSonar (meshsonar.com). Every column is in the CSV export; the full data is in the JSON export.',
  );
}
