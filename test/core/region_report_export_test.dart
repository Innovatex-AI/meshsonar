// Region report export: the website's table ids and column heads (report-tables.ts), raw values (km: null -> empty),
// activity type columns, collisions, grouped-host region column, text summary, JSON file. Optional byte-for-byte check
// against CSVs the website code generated from a real region-report body: set MESHSONAR_REGION_REPORT_JSON (the body)
// and MESHSONAR_WEB_CSV_DIR (the site's CSVs for it); skipped when absent (the body is ~200 KB, not committed).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_report_export.dart';

const _ok = {'state': 'ready', 'reason': null, 'computedAt': '2026-10-24T21:39:09.315Z', 'source': 'x'};

Map<String, dynamic> body({List<Map<String, Object?>>? members}) => {
      'generatedAt': '2026-10-24T21:39:12.062Z',
      'region': {'slug': 'cmh', 'name': 'Columbus, US', 'code': 'CMH'},
      'members': ?members,
      'overview': {
        'status': _ok,
        'packets24h': 1487,
        'observersOnline': 1,
        'observersTotal': 2,
        'repeaters': 350,
        'repeatersHeard24h': 56,
        'lastPacketAt': '2026-10-24T21:38:00.000Z',
        'packetsPerHour': [
          {'at': '2026-10-24T20:00:00.000Z', 'n': 52},
        ],
        'recentEvents': [
          {'type': 'repeater_new', 'key': 'ab', 'detail': 'BARKS-WEST, 1W "Repeater" appeared', 'at': '2026-10-23T00:01:21.620Z'},
        ],
      },
      'repeaters': {
        'status': _ok,
        'counts': {'active': 56, 'quiet': 205, 'new': 87, 'stale': 2},
        'rows': [
          {
            'key': 'd403', 'hashPrefix': 'd4', 'name': '=EVIL', 'role': 'repeater', 'lat': 40.1, 'lon': -82.9, //
            'firstSeenAt': null, 'lastHeardAt': '2026-10-24T21:00:00.000Z', 'relays24h': 12, 'adverts24h': 2, 'neighbours': 3,
            'observers24h': 1, 'heardHoursPct': 50.5, 'snrMeanDb': -3.25, 'signalGrade': 'B', 'hashSizeBytes': 1, 'ambiguous': false,
            'status': 'active', 'regions': [{'slug': 'cmh', 'code': 'CMH', 'name': 'Columbus, US'}],
          },
        ],
      },
      'observers': {
        'status': {'state': 'partial', 'reason': 'One observer is offline.'},
        'rows': [
          {'key': 'df01', 'name': 'INNO-OB-2', 'online': false, 'lastPacketAt': null, 'lastStatusAt': null, 'packetsPerHour': 0, //
            'noiseFloorDbm': -97, 'radio': '910.525024,62.5,7,5', 'firmware': 'v1', 'model': 'Heltec', 'nodesHeard24h': 0, 'trusted': true,
            'source': 'meshsonar'},
        ],
      },
      'activity': {
        'status': _ok,
        'bucket': 'day',
        'rows': [
          {'at': '2026-10-23T00:00:00.000Z', 'byType': {'4': 10, '11': 2}, 'total': 12},
          {'at': '2026-10-24T00:00:00.000Z', 'byType': {'5': 3}, 'total': 3},
        ],
      },
      'rf': {
        'status': _ok,
        'observers': [{'key': 'df01', 'name': 'INNO-OB-2', 'series': [], 'meanDbm': -97.1, 'maxDbm': -88.1}],
        'noiseByHour': [{'hour': 0, 'meanDbm': -85.7}],
        'snrHistogram': [{'n': 20, 'fromDb': -12, 'toDb': -10}],
      },
      'hash': {
        'status': _ok,
        'sizes': [{'bytes': 1, 'nodes': 23}],
        'collisions': [
          {'prefix': '33', 'nodes': [{'key': '3306', 'name': 'pi-zero'}, {'key': '3388', 'name': null}]},
        ],
      },
      'paths': {
        'status': _ok,
        'hopHistogram': [{'hops': 0, 'n': 10}, {'hops': 2, 'n': 30}],
        'floodShare': 0.82,
        'carryShare': [{'key': 'd403', 'name': 'OH.DEL.POLARIS East', 'share': 0.3913}],
      },
      'coverage': {'cells': 685, 'drives': 34, 'km': null, 'heardPct': 50},
    };

/// The website's table ids and heads for a region host (report-tables.ts, Oct 24 2026).
const websiteHeads = {
  'overview': ['metric', 'value'],
  'overview-packets-per-hour': ['hour_utc', 'packets'],
  'overview-events': ['at', 'type', 'key', 'detail'],
  'repeaters': ['key', 'hash_prefix', 'name', 'role', 'lat', 'lon', 'first_seen_at', 'last_heard_at', 'relays_24h', 'adverts_24h', 'neighbours', 'observers_24h', 'heard_hours_pct', 'snr_mean_db', 'signal_grade', 'hash_size_bytes', 'ambiguous', 'status'],
  'observers': ['key', 'name', 'online', 'last_packet_at', 'last_status_at', 'packets_per_hour', 'noise_floor_dbm', 'radio', 'firmware', 'model', 'nodes_heard_24h', 'trusted', 'source'],
  'activity': ['at', 'total', 'type_4_advert', 'type_5_group_text', 'type_11_control'],
  'rf-observers': ['key', 'name', 'mean_dbm', 'max_dbm'],
  'rf-noise-by-hour': ['hour_utc', 'mean_dbm'],
  'rf-snr': ['from_db', 'to_db', 'packets'],
  'hash-sizes': ['bytes', 'nodes'],
  'hash-collisions': ['prefix', 'nodes', 'node_keys'],
  'paths-hops': ['hops', 'packets'],
  'paths-carriers': ['key', 'name', 'share'],
  'coverage': ['metric', 'value'],
};

void main() {
  test('table ids, order and column heads equal the website', () {
    final t = RegionReportExport(body()).tables();
    expect([for (final x in t) x.id], websiteHeads.keys.toList());
    for (final x in t) {
      expect(x.head, websiteHeads[x.id], reason: x.id);
    }
  });

  test('cells: raw values, null km empty, formula-looking names neutralised, quotes doubled', () {
    final e = RegionReportExport(body());
    final t = {for (final x in e.tables()) x.id: x};
    expect(t['coverage']!.toCsv(), 'metric,value\r\ncells,685\r\ndrives,34\r\nkm,\r\nheard_pct,50\r\n');
    expect(t['repeaters']!.toCsv().split('\r\n')[1],
        "d403,d4,'=EVIL,repeater,40.1,-82.9,,2026-10-24T21:00:00.000Z,12,2,3,1,50.5,-3.25,B,1,false,active");
    expect(t['overview-events']!.toCsv(), contains('"BARKS-WEST, 1W ""Repeater"" appeared"'));
    expect(t['activity']!.rows, [
      ['2026-10-23T00:00:00.000Z', 12, 10, 0, 2],
      ['2026-10-24T00:00:00.000Z', 3, 0, 3, 0],
    ]);
    expect(t['hash-collisions']!.rows.single, ['33', 2, 'pi-zero; 3388']);
    expect(e.csvName('rf-snr'), 'cmh-rf-snr.csv');
    expect(e.jsonName, 'cmh-region-report.json');
  });

  test('a group host adds the regions column and the by-region table', () {
    final e = RegionReportExport(body(members: [
      {'slug': 'cmh', 'code': 'CMH', 'name': 'Columbus, US'},
      {'slug': 'day', 'code': 'DAY', 'name': 'Dayton, US'},
    ]));
    final t = {for (final x in e.tables()) x.id: x};
    expect(t['overview-by-region']!.rows, [
      ['CMH', 'Columbus, US', 1, 0],
      ['DAY', 'Dayton, US', 0, 0],
    ]);
    expect(t['repeaters']!.head.first, 'regions');
    expect(t['repeaters']!.rows.single.first, 'CMH');
  });

  test('text summary and JSON file', () {
    final e = RegionReportExport(body());
    final txt = e.toText();
    expect(txt, startsWith('MeshSonar region report: Columbus, US (CMH)'));
    expect(txt, contains('Generated 2026-10-24 21:39 UTC'));
    expect(txt, contains('Packets: 1487'));
    expect(txt, contains('56 active, 205 quiet, 87 new, 2 stale'));
    expect(txt, contains('Observers (partial: One observer is offline.): 1, 0 online'));
    expect(txt, contains('1 observers reporting; quietest -97.1 dBm'));
    expect(txt, contains('average 1.5 hops, 82% flooded'));
    expect(txt, contains('685 cells, 34 drives, 50% heard'));
    expect(jsonDecode(e.toJsonFile()), body());
    expect(e.toJsonFile(), contains('\n  "generatedAt"'));
    expect(e.allTablesCsv().split('\r\n').first, startsWith('table,metric,value,hour_utc,packets,at,type,key,detail'));
  });

  final bodyPath = Platform.environment['MESHSONAR_REGION_REPORT_JSON'];
  final webDir = Platform.environment['MESHSONAR_WEB_CSV_DIR'];
  test('byte-for-byte equal to the website CSVs for a real body', () {
    final e = RegionReportExport(jsonDecode(File(bodyPath!).readAsStringSync()) as Map<String, dynamic>);
    var compared = 0;
    for (final t in e.tables()) {
      final f = File('$webDir/${e.csvName(t.id)}');
      expect(f.existsSync(), isTrue, reason: f.path);
      expect(t.toCsv(), f.readAsStringSync(), reason: t.id);
      compared++;
    }
    expect(compared, greaterThan(10));
  }, skip: bodyPath == null || webDir == null ? 'set MESHSONAR_REGION_REPORT_JSON and MESHSONAR_WEB_CSV_DIR' : false);
}
