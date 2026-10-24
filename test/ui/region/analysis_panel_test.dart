import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/region_analysis_api.dart';
import 'package:meshsonar/ui/region/analysis_panel.dart';

const _ok = {'state': 'ready', 'reason': null, 'computedAt': 'x', 'source': 's'};

Map<String, Object?> _bodies({Object? hashStatus = _ok, List sizes = const [{'bytes': 1, 'nodes': 22}, {'bytes': 2, 'nodes': 30}]}) => {
      'region-activity': {
        'status': _ok,
        'bucket': 'hour',
        'rows': [
          {'at': '2026-10-22T02:00:00.000Z', 'byType': {'0': 3}, 'total': 12},
          {'at': '2026-10-22T03:00:00.000Z', 'byType': {'0': 3}, 'total': 163},
          {'at': 'bad', 'total': 5},
        ]
      },
      'region-hash-stats': {'status': hashStatus, 'sizes': sizes, 'collisions': [{'prefix': '33', 'nodes': []}]},
      'region-path-stats': {
        'status': _ok,
        'hopHistogram': [{'hops': 0, 'n': 10}, {'hops': 2, 'n': 30}],
        'floodShare': 0.82,
        'carryShare': [{'key': 'abcdef012345', 'name': 'OH.DEL.POLARIS', 'share': 0.41}]
      },
      'region-repeaters': {
        'status': _ok,
        'rows': [{'role': 'repeater'}, {'role': 'repeater'}, {'role': 'room'}],
        'counts': {'active': 2, 'quiet': 1}
      },
    };

RegionAnalysisApi _api(Map<String, Object?> b, {Set<String> fail = const {}, int code = 200}) => RegionAnalysisApi(
      'https://day.meshsonar.com',
      client: MockClient((req) async {
        final name = req.url.pathSegments.last;
        if (fail.contains(name)) return http.Response('no', 500);
        return http.Response(jsonEncode(b[name]), code);
      }),
    );

Future<void> _pump(WidgetTester t, RegionAnalysisApi api) async {
  t.view.physicalSize = const Size(800, 4000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
      home: Scaffold(body: AnalysisPanel(baseUrl: 'https://day.meshsonar.com', regionSlug: 'day', api: api))));
  await t.pumpAndSettle();
}

void main() {
  group('parsing', () {
    test('activity heatmap sums into weekday/hour cells and skips bad rows', () {
      final a = RegionActivity.parse(_bodies()['region-activity']);
      expect(a.rows.length, 2);
      expect(a.total, 175);
      final g = a.heatmap(toZone: (t) => t); // UTC: 2026-10-22 is a Thursday
      expect(g[4][2], 12);
      expect(g[4][3], 163);
    });
    test('path stats mean hops and sorted carriers', () {
      final p = PathStats.parse(_bodies()['region-path-stats']);
      expect(p.meanHops, closeTo(1.5, 1e-9));
      expect(p.floodShare, 0.82);
      expect(p.carriers.single.name, 'OH.DEL.POLARIS');
    });
    test('roles and hash sizes; garbage tolerated', () {
      final r = RoleMix.parse(_bodies()['region-repeaters']);
      expect(r.roles, {'repeater': 2, 'room': 1});
      expect(r.states['active'], 2);
      final h = HashStats.parse(_bodies()['region-hash-stats']);
      expect(h.sizes.map((s) => s.bytes), [1, 2]);
      expect(h.collisionPrefixes, 1);
      expect(HashStats.parse('nope').status.state, 'unavailable');
      expect(RegionStatus.parse({'state': 'partial', 'reason': 'why'}).reason, 'why');
    });
    test('endpoint and activity window', () {
      final api = RegionAnalysisApi('https://day.meshsonar.com/', now: () => DateTime.utc(2026, 10, 23, 5, 30));
      expect(api.endpoint('region-rf').toString(), 'https://day.meshsonar.com/api/cmh/region-rf');
      final q = api.activityQuery();
      expect(q['until'], '2026-10-23T06:00:00.000Z');
      expect(q['since'], '2026-10-16T06:00:00.000Z');
    });
  });

  group('panel states', () {
    testWidgets('loading then data', (t) async {
      t.view.physicalSize = const Size(800, 4000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
          home: Scaffold(body: AnalysisPanel(baseUrl: 'https://day.meshsonar.com', regionSlug: 'day', api: _api(_bodies())))));
      expect(find.byKey(const Key('analysis-loading')), findsOneWidget);
      await t.pumpAndSettle();
      expect(find.text('DAY analysis'), findsOneWidget);
      expect(find.text('Role mix'), findsOneWidget);
      expect(find.text('Repeater'), findsOneWidget);
      expect(find.text('30 nodes'), findsOneWidget);
      expect(find.byKey(const Key('analysis-heatmap')), findsOneWidget);
      expect(find.text('OH.DEL.POLARIS'), findsOneWidget);
    });
    testWidgets('partial status quotes the server reason', (t) async {
      await _pump(
          t,
          _api(_bodies(hashStatus: {
            'state': 'partial',
            'reason': 'No MeshSonar observers in this region yet: only the CoreScope view is shown.',
            'computedAt': null,
            'source': 's'
          })));
      expect(find.textContaining('No MeshSonar observers in this region yet'), findsOneWidget);
    });
    testWidgets('empty section shows reason', (t) async {
      await _pump(
          t,
          _api(_bodies(hashStatus: {'state': 'pending', 'reason': 'Waiting for observers.', 'computedAt': null, 'source': 's'}, sizes: const [])));
      expect(find.text('No data yet. Waiting for observers.'), findsOneWidget);
    });
    testWidgets('one failed section keeps the rest', (t) async {
      await _pump(t, _api(_bodies(), fail: {'region-hash-stats'}));
      expect(find.byKey(const Key('analysis-partial')), findsOneWidget);
      expect(find.byKey(const Key('section-error-Hash sizes')), findsOneWidget);
      expect(find.text('Role mix'), findsOneWidget);
    });
    testWidgets('all failed shows error and retry recovers', (t) async {
      var fail = true;
      final api = RegionAnalysisApi('https://day.meshsonar.com', client: MockClient((req) async {
        if (fail) return http.Response('x', 503);
        return http.Response(jsonEncode(_bodies()[req.url.pathSegments.last]), 200);
      }));
      await _pump(t, api);
      expect(find.byKey(const Key('analysis-error')), findsOneWidget);
      expect(find.textContaining('503'), findsOneWidget);
      fail = false;
      await t.tap(find.text('Retry'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('analysis-list')), findsOneWidget);
    });
  });
}
