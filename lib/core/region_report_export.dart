// Region report export: the `region-report` body turned into the website's own tables (same ids, same column heads,
// same cell values; meshcore-insights src/components/region/report-tables.ts reportTables), a plain-text summary, and
// the JSON file. CSV cells are the raw JSON values through report_csv.dart (byte-compatible with the site's toCsv);
// times stay UTC ISO like the site (`hour_utc`). File names follow the site: `<slug>-<tableId>.csv`,
// `<slug>-region-report.json`. Pure Dart: no Flutter imports.
import 'dart:convert';

import 'region_dataset_fetch.dart';
import 'report_csv.dart';

/// MeshCore payload type names (website src/lib/region/packet-types.ts PACKET_TYPE_NAMES).
const Map<int, String> packetTypeNames = {
  0: 'Request', 1: 'Response', 2: 'Direct message', 3: 'Ack', 4: 'Advert', 5: 'Group text', 6: 'Group data', //
  7: 'Anonymous request', 8: 'Path', 9: 'Trace', 10: 'Multipart', 11: 'Control', 15: 'Raw custom',
};
String packetTypeName(int t) => packetTypeNames[t] ?? 'Type $t';

/// A JSON leaf as a CSV cell: strings, numbers and booleans as they are, anything else (null, missing) empty.
Object? _leaf(Object? v) => v is String || v is num || v is bool ? v : null;

class RegionReportExport {
  final Map<String, dynamic> json;
  const RegionReportExport(this.json);

  Map<String, dynamic> _s(String k) => jMap(json[k]);
  String get slug => jStr(jMap(json['region'])['slug']) ?? 'region';
  String get name => jStr(jMap(json['region'])['name']) ?? slug.toUpperCase();
  String get code => jStr(jMap(json['region'])['code']) ?? slug.toUpperCase();
  DateTime? get generatedAt => jTime(json['generatedAt']);
  bool get grouped => jMaps(json['members']).isNotEmpty;

  String csvName(String tableId) => '$slug-$tableId.csv';
  String get jsonName => '$slug-region-report.json';
  String get textName => '$slug-region-report.txt';
  String get allTablesName => '$slug-region-report-all-tables.csv';

  /// The JSON file, pretty-printed with two spaces exactly like the website's download (JSON.stringify(r, null, 2)).
  String toJsonFile() => const JsonEncoder.withIndent('  ').convert(json);

  static String? _regionCell(Object? regions) {
    final r = jMaps(regions);
    return r.isEmpty ? null : r.map((x) => jStr(x['code']) ?? '').join('; ');
  }

  List<ReportTable> tables() {
    final o = _s('overview');
    final g = grouped;
    final reps = jMaps(_s('repeaters')['rows']);
    final obs = jMaps(_s('observers')['rows']);
    final act = _s('activity');
    final actRows = jMaps(act['rows']);
    final typeIds = <int>{
      for (final r in actRows)
        for (final k in jMap(r['byType']).keys)
          if (int.tryParse(k) != null) int.parse(k),
    }.toList()
      ..sort();
    final rf = _s('rf');
    final hash = _s('hash');
    final paths = _s('paths');
    final cov = _s('coverage');
    List<Object?> pick(Map<String, dynamic> m, List<String> keys) => [for (final k in keys) _leaf(m[k])];

    const repKeys = [
      'key', 'hashPrefix', 'name', 'role', 'lat', 'lon', 'firstSeenAt', 'lastHeardAt', 'relays24h', 'adverts24h', //
      'neighbours', 'observers24h', 'heardHoursPct', 'snrMeanDb', 'signalGrade', 'hashSizeBytes', 'ambiguous', 'status',
    ];
    const obsKeys = [
      'key', 'name', 'online', 'lastPacketAt', 'lastStatusAt', 'packetsPerHour', 'noiseFloorDbm', 'radio', 'firmware', //
      'model', 'nodesHeard24h', 'trusted', 'source',
    ];
    final members = jMaps(json['members']);
    return [
      ReportTable(id: 'overview', label: 'Overview figures', head: const ['metric', 'value'], rows: [
        ['packets_24h', _leaf(o['packets24h'])],
        ['observers_online', _leaf(o['observersOnline'])],
        ['observers_total', _leaf(o['observersTotal'])],
        ['repeaters', _leaf(o['repeaters'])],
        ['repeaters_heard_24h', _leaf(o['repeatersHeard24h'])],
        ['last_packet_at', _leaf(o['lastPacketAt'])],
      ]),
      ReportTable(
        id: 'overview-packets-per-hour',
        label: 'Packets per hour, last 24 h',
        head: const ['hour_utc', 'packets'],
        rows: [for (final p in jMaps(o['packetsPerHour'])) pick(p, const ['at', 'n'])],
      ),
      ReportTable(
        id: 'overview-events',
        label: 'Recent changes',
        head: const ['at', 'type', 'key', 'detail'],
        rows: [for (final e in jMaps(o['recentEvents'])) pick(e, const ['at', 'type', 'key', 'detail'])],
      ),
      if (g)
        ReportTable(id: 'overview-by-region', label: 'By region', head: const ['region_code', 'region', 'repeaters', 'observers'], rows: [
          for (final m in members)
            [
              _leaf(m['code']),
              _leaf(m['name']),
              reps.where((x) => jMaps(x['regions']).any((r) => r['slug'] == m['slug'])).length,
              obs.where((x) => jMaps(x['regions']).any((r) => r['slug'] == m['slug'])).length,
            ],
        ]),
      ReportTable(
        id: 'repeaters',
        label: 'Repeaters',
        head: [
          if (g) 'regions',
          'key', 'hash_prefix', 'name', 'role', 'lat', 'lon', 'first_seen_at', 'last_heard_at', 'relays_24h', 'adverts_24h', //
          'neighbours', 'observers_24h', 'heard_hours_pct', 'snr_mean_db', 'signal_grade', 'hash_size_bytes', 'ambiguous', 'status',
        ],
        rows: [for (final x in reps) [if (g) _regionCell(x['regions']), ...pick(x, repKeys)]],
      ),
      ReportTable(
        id: 'observers',
        label: 'Observers',
        head: [
          if (g) 'regions',
          'key', 'name', 'online', 'last_packet_at', 'last_status_at', 'packets_per_hour', 'noise_floor_dbm', 'radio', //
          'firmware', 'model', 'nodes_heard_24h', 'trusted', 'source',
        ],
        rows: [for (final x in obs) [if (g) _regionCell(x['regions']), ...pick(x, obsKeys)]],
      ),
      ReportTable(
        id: 'activity',
        label: 'Packets by type per ${jStr(act['bucket']) ?? 'day'}',
        head: ['at', 'total', for (final t in typeIds) 'type_${t}_${packetTypeName(t).toLowerCase().replaceAll(RegExp(r'\s+'), '_')}'],
        rows: [
          for (final r in actRows)
            [_leaf(r['at']), _leaf(r['total']), for (final t in typeIds) _leaf(jMap(r['byType'])['$t']) ?? 0],
        ],
      ),
      ReportTable(
        id: 'rf-observers',
        label: 'Noise floor by observer',
        head: const ['key', 'name', 'mean_dbm', 'max_dbm'],
        rows: [for (final x in jMaps(rf['observers'])) pick(x, const ['key', 'name', 'meanDbm', 'maxDbm'])],
      ),
      ReportTable(
        id: 'rf-noise-by-hour',
        label: 'Noise floor by hour (UTC)',
        head: const ['hour_utc', 'mean_dbm'],
        rows: [for (final x in jMaps(rf['noiseByHour'])) pick(x, const ['hour', 'meanDbm'])],
      ),
      ReportTable(
        id: 'rf-snr',
        label: 'SNR histogram',
        head: const ['from_db', 'to_db', 'packets'],
        rows: [for (final x in jMaps(rf['snrHistogram'])) pick(x, const ['fromDb', 'toDb', 'n'])],
      ),
      ReportTable(
        id: 'hash-sizes',
        label: 'Hash sizes',
        head: const ['bytes', 'nodes'],
        rows: [for (final x in jMaps(hash['sizes'])) pick(x, const ['bytes', 'nodes'])],
      ),
      ReportTable(
        id: 'hash-collisions',
        label: 'Hash collisions',
        head: const ['prefix', 'nodes', 'node_keys'],
        rows: [
          for (final x in jMaps(hash['collisions']))
            [
              _leaf(x['prefix']),
              jMaps(x['nodes']).length,
              jMaps(x['nodes']).map((n) => jStr(n['name']) ?? (n['key'] is String ? n['key'] as String : '')).join('; '),
            ],
        ],
      ),
      ReportTable(
        id: 'paths-hops',
        label: 'Hops per packet',
        head: const ['hops', 'packets'],
        rows: [for (final x in jMaps(paths['hopHistogram'])) pick(x, const ['hops', 'n'])],
      ),
      ReportTable(
        id: 'paths-carriers',
        label: 'Top carriers',
        head: const ['key', 'name', 'share'],
        rows: [for (final x in jMaps(paths['carryShare'])) pick(x, const ['key', 'name', 'share'])],
      ),
      ReportTable(id: 'coverage', label: 'Coverage figures', head: const ['metric', 'value'], rows: [
        ['cells', _leaf(cov['cells'])],
        ['drives', _leaf(cov['drives'])],
        ['km', _leaf(cov['km'])],
        ['heard_pct', _leaf(cov['heardPct'])],
      ]),
    ];
  }

  /// Every table in one CSV file (first column `table`).
  String allTablesCsv() => combinedCsv(tables());

  /// A short plain-text summary for the share sheet. Times are UTC (as in the CSVs) and say so; distances are not
  /// shown (the only one, coverage km, is in the CSV in SI).
  String toText() {
    String n(Object? v) => v is num ? jsNumber(v) : '—';
    String st(String section) {
      final s = jMap(_s(section)['status']);
      final state = jStr(s['state']) ?? 'unknown';
      final reason = jStr(s['reason']);
      return state == 'ready' ? '' : ' ($state${reason == null ? '' : ': $reason'})';
    }

    final o = _s('overview');
    final counts = jMap(_s('repeaters')['counts']);
    final obs = jMaps(_s('observers')['rows']);
    final rfObs = jMaps(_s('rf')['observers']);
    final means = [for (final x in rfObs) if (jDbl(x['meanDbm']) != null) jDbl(x['meanDbm'])!];
    final hops = jMaps(_s('paths')['hopHistogram']);
    final totalHops = hops.fold<num>(0, (a, h) => a + (jNum(h['n']) ?? 0));
    final meanHops = totalHops == 0 ? null : hops.fold<num>(0, (a, h) => a + (jNum(h['hops']) ?? 0) * (jNum(h['n']) ?? 0)) / totalHops;
    final flood = jDbl(_s('paths')['floodShare']);
    final cov = _s('coverage');
    final sizes = jMaps(_s('hash')['sizes']);
    final collisions = jMaps(_s('hash')['collisions']).length;
    final g = generatedAt;
    final b = StringBuffer()
      ..writeln('MeshSonar region report: $name ($code)')
      ..writeln('Generated ${g == null ? 'at an unknown time' : '${g.toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC'}')
      ..writeln()
      ..writeln('Overview, last 24 h${st('overview')}')
      ..writeln('  Packets: ${n(o['packets24h'])}')
      ..writeln('  Observers online: ${n(o['observersOnline'])} of ${n(o['observersTotal'])}')
      ..writeln('  Repeaters: ${n(o['repeaters'])}, heard in 24 h: ${n(o['repeatersHeard24h'])}')
      ..writeln()
      ..writeln('Repeaters${st('repeaters')}')
      ..writeln('  ${n(counts['active'])} active, ${n(counts['quiet'])} quiet, ${n(counts['new'])} new, ${n(counts['stale'])} stale')
      ..writeln()
      ..writeln('Observers${st('observers')}: ${obs.length}, ${obs.where((x) => x['online'] == true).length} online')
      ..writeln()
      ..writeln('RF and noise floor${st('rf')}');
    if (means.isEmpty) {
      b.writeln('  No noise floor readings.');
    } else {
      means.sort();
      b.writeln('  ${means.length} observers reporting; quietest ${means.first.toStringAsFixed(1)} dBm, '
          'noisiest ${means.last.toStringAsFixed(1)} dBm');
    }
    b
      ..writeln()
      ..writeln('Hash sizes${st('hash')}: '
          '${sizes.isEmpty ? 'none' : sizes.map((s) => '${n(s['bytes'])}-byte ${n(s['nodes'])}').join(', ')}; $collisions shared prefixes')
      ..writeln('Paths${st('paths')}: '
          '${meanHops == null ? 'no packets' : 'average ${meanHops.toStringAsFixed(1)} hops'}'
          '${flood == null ? '' : ', ${(flood * 100).round()}% flooded'}')
      ..writeln('Coverage: ${n(cov['cells'])} cells, ${n(cov['drives'])} drives, ${n(cov['heardPct'])}% heard')
      ..writeln()
      ..writeln('Every table is in the CSV export; the full data is in the JSON export.')
      ..writeln('From MeshSonar (meshsonar.com)');
    return b.toString();
  }
}
