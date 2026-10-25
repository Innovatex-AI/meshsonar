import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_reports_api.dart';

String fixture(String n) => File('test/fixtures/$n').readAsStringSync();

void main() {
  test('endpoint is <region host>/api/cmh/<name> for every region (the host picks the region), tolerating a trailing slash', () {
    final a = RegionReportsApi('https://cmh.meshsonar.com/');
    expect(a.endpoint('region-report').toString(), 'https://cmh.meshsonar.com/api/cmh/region-report');
    // Live: day.meshsonar.com/api/day/region-report is 404; /api/cmh/region-report on the DAY host answers DAY.
    expect(RegionReportsApi('https://day.meshsonar.com').endpoint('region-report').toString(),
        'https://day.meshsonar.com/api/cmh/region-report');
  });

  test('fetchReport/fetchSources for DAY and CVG request /api/cmh/ on the region host, never /api/<slug>/', () async {
    final seen = <String>[];
    for (final (host, slug) in [('https://day.meshsonar.com', 'day'), ('https://cvg.meshsonar.com', 'cvg')]) {
      final a = RegionReportsApi(host, client: MockClient((r) async {
        seen.add(r.url.toString());
        return http.Response(r.url.path.endsWith('region-report') ? '{"region":{"slug":"$slug","name":"X","code":"${slug.toUpperCase()}"}}' : '{"sources":[]}', 200);
      }));
      expect((await a.fetchReport(slug)).ok, isTrue);
      expect((await a.fetchSources(slug)).ok, isTrue);
    }
    expect(seen, [
      'https://day.meshsonar.com/api/cmh/region-report',
      'https://day.meshsonar.com/api/cmh/region-sources',
      'https://cvg.meshsonar.com/api/cmh/region-report',
      'https://cvg.meshsonar.com/api/cmh/region-sources',
    ]);
  });

  test('parses the real CMH region-report', () {
    final d = RegionReportData.parse(jsonDecode(fixture('region_report_cmh.json')) as Map<String, dynamic>);
    expect(d.slug, 'cmh');
    expect(d.name, 'Columbus, US');
    expect(d.packets24h, 612);
    expect(d.observersOnline, 1);
    expect(d.observersTotal, 9);
    expect(d.repeaters, 326);
    expect(d.repeaterCounts.active, 62);
    expect(d.repeaterCounts.fresh, 123);
    expect(d.packetsPerHour, isNotEmpty);
    expect(d.events, isNotEmpty);
    expect(d.activity, isNotEmpty);
    expect(d.coverageCells, 685);
    expect(d.coverageKm, isNull); // null stays null, never 0
    expect(d.coverageHeardPct, 49.5);
    expect(d.overviewStatus.state, DataState.ready);
    expect(d.floodShare, closeTo(0.8198, 1e-9));
    expect(d.isEmpty, isFalse);
  });

  test('parses the real CMH region-sources (counts per source, ledger flags)', () {
    final d = RegionSourcesData.parse(jsonDecode(fixture('region_sources_cmh.json')) as Map<String, dynamic>);
    expect(d.sources.map((s) => s.kindLabel), ['CoreScope', 'MeshCore Map']);
    final map = d.sources[1];
    expect(map.nodes, 113);
    expect(map.neverSucceeded, isFalse);
    expect(map.prototypeOnly, isTrue);
    expect(d.sources[0].neverSucceeded, isTrue);
    expect(d.sources[0].stale, isTrue);
  });

  test('garbage fields become null/empty, not zeros', () {
    final d = RegionReportData.parse({'overview': {'packets24h': 'many'}, 'activity': {'rows': 5}});
    expect(d.packets24h, isNull);
    expect(d.activity, isEmpty);
    expect(d.isEmpty, isTrue);
    expect(d.overviewStatus.state, DataState.unknown);
  });

  group('fetch', () {
    RegionReportsApi apiWith(http.Response Function(http.Request) h) =>
        RegionReportsApi('https://x.test', client: MockClient((r) async => h(r)));

    test('200 ok', () async {
      final r = await apiWith((_) => http.Response(fixture('region_report_cmh.json'), 200)).fetchReport('cmh');
      expect(r.ok, isTrue);
    });
    test('404 html is notFound', () async {
      final r = await apiWith((_) => http.Response('<html></html>', 404)).fetchReport('day');
      expect(r.error!.kind, FetchErrorKind.notFound);
    });
    test('500 is server', () async {
      final r = await apiWith((_) => http.Response('x', 500)).fetchSources('cmh');
      expect(r.error!.kind, FetchErrorKind.server);
    });
    test('200 with html is badResponse', () async {
      final r = await apiWith((_) => http.Response('<html></html>', 200)).fetchReport('cmh');
      expect(r.error!.kind, FetchErrorKind.badResponse);
    });
    test('socket failure is network', () async {
      final a = RegionReportsApi('https://x.test', client: MockClient((_) async => throw const SocketException('down')));
      expect((await a.fetchReport('cmh')).error!.kind, FetchErrorKind.network);
    });
  });
}
