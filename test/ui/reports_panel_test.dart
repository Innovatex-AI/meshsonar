import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_reports_api.dart';
import 'package:meshsonar/ui/region/reports_panel.dart';

String fixture(String n) => File('test/fixtures/$n').readAsStringSync();
final now = DateTime.utc(2026, 10, 24, 2);

Widget host(RegionReportsApi api, {String slug = 'cmh'}) => MaterialApp(
      home: Scaffold(body: ReportsPanel(baseUrl: 'https://x.test', regionSlug: slug, api: api, clock: () => now)),
    );

RegionReportsApi api(Future<http.Response> Function(http.Request) h) => RegionReportsApi('https://x.test', client: MockClient(h));

http.Response ok(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});

void main() {
  testWidgets('loading then full report with sources', (t) async {
    final c = Completer<http.Response>();
    await t.pumpWidget(host(api((r) => r.url.path.endsWith('region-report') ? c.future : Future.value(ok(fixture('region_sources_cmh.json'))))));
    expect(find.byKey(const Key('reports-loading')), findsOneWidget);
    c.complete(ok(fixture('region_report_cmh.json')));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('reports-loading')), findsNothing);
    expect(find.text('Columbus, US'), findsOneWidget);
    expect(find.text('612'), findsOneWidget);
    expect(find.byKey(const Key('bars-trend')), findsOneWidget);
    expect(find.text('Notable events'), findsOneWidget);
    // Sources
    await t.scrollUntilVisible(find.byKey(const ValueKey('source-MeshCore Map')), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('Nodes 113'), findsOneWidget);
    expect(find.text('CoreScope'), findsOneWidget);
    expect(find.textContaining('No successful pull yet'), findsOneWidget);
  });

  testWidgets('report 404 and sources ok: honest note, sources still shown', (t) async {
    await t.pumpWidget(host(api((r) async => r.url.path.endsWith('region-report') ? http.Response('<html/>', 404) : ok(fixture('region_sources_cmh.json'))), slug: 'day'));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('reports-error')), findsOneWidget);
    expect(find.textContaining('has not published the report'), findsOneWidget);
    expect(find.byKey(const Key('sources-list')), findsOneWidget);
  });

  testWidgets('network error shows Retry and recovers', (t) async {
    var fail = true;
    await t.pumpWidget(host(api((r) async {
      if (fail) throw const SocketException('down');
      return r.url.path.endsWith('region-report') ? ok(fixture('region_report_cmh.json')) : ok(fixture('region_sources_cmh.json'));
    })));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('reports-error')), findsOneWidget);
    expect(find.byKey(const Key('sources-error')), findsOneWidget);
    fail = false;
    await t.tap(find.text('Retry').first);
    await t.pumpAndSettle();
    expect(find.byKey(const Key('reports-error')), findsNothing);
    expect(find.text('Columbus, US'), findsOneWidget);
  });

  testWidgets('empty report says nothing measured; empty sources says so', (t) async {
    await t.pumpWidget(host(api((r) async => ok(r.url.path.endsWith('region-report') ? '{"region":{"slug":"day","name":"Dayton, US","code":"DAY"}}' : '{"status":{"state":"ready"},"sources":[]}'))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('reports-empty')), findsOneWidget);
    await t.scrollUntilVisible(find.byKey(const Key('sources-empty')), 200, scrollable: find.byType(Scrollable).first);
    expect(find.byKey(const Key('sources-empty')), findsOneWidget);
  });

  testWidgets('partial dataset is labelled with its reason', (t) async {
    final d = jsonDecode(fixture('region_report_cmh.json')) as Map<String, dynamic>;
    d['overview']['status'] = {'state': 'partial', 'reason': 'one observer offline', 'computedAt': null, 'source': 'x'};
    await t.pumpWidget(host(api((r) async => ok(r.url.path.endsWith('region-report') ? jsonEncode(d) : fixture('region_sources_cmh.json')))));
    await t.pumpAndSettle();
    expect(find.byKey(const Key('status-partial')), findsWidgets);
    expect(find.text('one observer offline'), findsWidgets);
  });

  testWidgets('switching region reloads and ignores the stale response', (t) async {
    final slow = Completer<http.Response>();
    final calls = <String>[];
    final a = api((r) {
      calls.add(r.url.path);
      if (r.url.path == '/api/cmh/region-report') return slow.future;
      if (r.url.path.endsWith('region-report')) return Future.value(ok('{"region":{"slug":"day","name":"Dayton, US","code":"DAY"},"overview":{"packets24h":5}}'));
      return Future.value(ok('{"sources":[]}'));
    });
    await t.pumpWidget(host(a, slug: 'cmh'));
    await t.pumpWidget(host(a, slug: 'day'));
    await t.pumpAndSettle();
    expect(find.text('Dayton, US'), findsOneWidget);
    slow.complete(ok(fixture('region_report_cmh.json')));
    await t.pumpAndSettle();
    expect(find.text('Dayton, US'), findsOneWidget);
    expect(find.text('Columbus, US'), findsNothing);
    expect(calls, contains('/api/day/region-report'));
  });
}
