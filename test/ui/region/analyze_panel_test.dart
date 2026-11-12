// AN-1 (app): every state of every Analyze section, and the rendered numbers equal the fixture (= website contract example) numbers.
// Fixtures: test/fixtures/analyze/*.json (copied from meshcore-insights docs/analyze-contract.md / analyze-fixtures.ts).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/analyze_api.dart';
import 'package:meshsonar/core/analyze_model.dart';
import 'package:meshsonar/ui/region/analyze_panel.dart';

Object fx(String n) => jsonDecode(File('test/fixtures/analyze/$n.json').readAsStringSync()) as Object;

final _now = DateTime.utc(2026, 11, 11, 9);

/// Serves the fixtures; [over] replaces a read's body (an Exception = a 500, a Future-less value = JSON).
AnalyzeApi api(Map<String, Object?> over, {Map<String, int>? calls}) {
  final table = <String, Object?>{
    'region-insights': fx('insights'),
    'region-traffic': fx('traffic'),
    'region-node-gate': fx('node_gate'),
    'region-repeater-health': fx('repeater_health'),
    'region-overview': fx('overview'),
    'region-status': fx('region_status_ready'),
    ...over,
  };
  return AnalyzeApi(
    'https://cmh.meshsonar.com',
    client: MockClient((req) async {
      final fn = req.url.pathSegments.last;
      if (calls != null) calls[fn] = (calls[fn] ?? 0) + 1;
      final v = table[fn];
      if (v == null || v is Exception) return http.Response('no', 500);
      return http.Response(jsonEncode(v), 200);
    }),
  );
}

Future<void> pump(WidgetTester t, AnalyzeApi a, {String? tz = 'America/New_York'}) async {
  t.view.physicalSize = const Size(900, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: AnalyzePanel(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          regionName: 'Columbus, US',
          timezone: tz,
          api: a,
          now: () => _now,
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

String statText(WidgetTester t, String label) => t.widget<Text>(find.byKey(Key('stat-value:$label'))).data!;
bool has(String key) => find.byKey(Key(key)).evaluate().isNotEmpty;

Map<String, dynamic> withStatus(String file, Map<String, Object?> status, {Object? builtAt = 'KEEP'}) {
  final j = Map<String, dynamic>.from(fx(file) as Map);
  j['status'] = {...(j['status'] as Map), ...status};
  if (builtAt != 'KEEP') j['builtAt'] = builtAt;
  return j;
}

void main() {
  group('ready: the screen numbers are the endpoint numbers', () {
    testWidgets('findings, health, traffic and gate', (t) async {
      final calls = <String, int>{};
      await pump(t, api({}, calls: calls));
      for (final id in ['an-findings', 'an-health', 'an-traffic', 'an-gate']) {
        expect(has('$id-ready'), isTrue, reason: id);
      }
      // findings: severity order, the engine's own words
      final order = ['finding:critical_nodes', 'finding:low_uptime', 'finding:repeaters_new'];
      final ys = [for (final k in order) t.getTopLeft(find.byKey(Key(k))).dy];
      expect(ys, [...ys]..sort());
      expect(find.textContaining('6 repeaters are single points of failure'), findsOneWidget);
      expect(find.text('Problem'), findsOneWidget);
      expect(find.text('Note'), findsOneWidget);
      // traffic: the model's figures from the same fixture, and the chip
      final traffic = TrafficRead.parse(fx('traffic') as Map<String, dynamic>);
      final f = trafficFigures(traffic);
      expect(statText(t, 'Packets'), f.packets);
      expect(statText(t, 'Packets'), '61,234');
      expect(statText(t, 'Observations'), '640,000');
      expect(statText(t, 'Observers'), '41');
      expect(statText(t, 'Mean SNR'), '4.2 dB');
      expect(statText(t, 'Flooded'), '75%');
      expect(t.widget<Text>(find.byKey(const Key('source-chip'))).data, 'Heard by ours 38% · outside 60% · phones 2%');
      // health: the endpoint's counts, not a recount
      expect(statText(t, 'Repeaters and rooms'), '40');
      expect(statText(t, 'Heard in 24 h'), '31');
      expect(statText(t, 'Silent for 24 h'), '9');
      expect(statText(t, 'Relaying in 24 h'), '22');
      expect(find.byKey(Key('busy:${'k1'.padRight(64, '0')}')), findsOneWidget);
      expect(find.textContaining('5,000 relayed · 89% up'), findsOneWidget);
      expect(find.text('New repeater'), findsNothing); // events are Text.rich spans
      expect(find.textContaining('New repeater'), findsOneWidget);
      // gate: the server sentence and its numbers
      expect(find.textContaining('812 of 1,000'), findsWidgets);
      expect(statText(t, 'Hop codes known'), '812 of 1,000');
      expect(statText(t, 'Match rate'), '81%');
      // "Updated" in the region zone (America/New_York in November = EST, not UTC)
      expect(find.text('Updated Nov 10, 2026, 10:50 PM EST'), findsNWidgets(4));
    });

    testWidgets('each engine read is called once; region-status once', (t) async {
      final calls = <String, int>{};
      await pump(t, api({}, calls: calls));
      for (final fn in [
        'region-insights',
        'region-traffic',
        'region-node-gate',
        'region-repeater-health',
        'region-overview',
        'region-status',
      ]) {
        expect(calls[fn], 1, reason: fn);
      }
    });

    testWidgets('an empty findings list says nothing needs attention', (t) async {
      await pump(
        t,
        api({
          'region-insights': withStatus('insights', {'reason': 'No findings for this region.'})..['rows'] = [],
        }),
      );
      expect(find.text('Nothing needs attention'), findsOneWidget);
      expect(find.text('No findings for this region.'), findsOneWidget);
    });

    testWidgets('no time zone says UTC (not the phone zone)', (t) async {
      await pump(t, api({}), tz: null);
      expect(find.text('Updated Nov 11, 2026, 3:50 AM UTC'), findsWidgets);
    });
  });

  group('stale: older than 36 h is never shown as current', () {
    testWidgets('the engine says stale: banner, figures dimmed below', (t) async {
      await pump(
        t,
        api({
          'region-insights': withStatus('insights', {
            'state': 'stale',
            'reason': 'Findings were last rebuilt.',
          }, builtAt: '2026-11-09T03:50:00Z'),
        }),
      );
      expect(has('an-findings-stale'), isTrue);
      expect(has('an-findings-ready'), isFalse);
      expect(find.text('Out of date: not shown as current'), findsOneWidget);
      expect(
        find.textContaining('6 repeaters are single points of failure'),
        findsOneWidget,
      ); // older figures still there
    });
    testWidgets('a cached "ready" 53 h old is re-judged by age, time in the region zone', (t) async {
      final j = Map<String, dynamic>.from(fx('traffic') as Map)..['builtAt'] = '2026-11-09T03:50:00Z';
      await pump(t, api({'region-traffic': j}));
      expect(has('an-traffic-stale'), isTrue);
      expect(find.textContaining('Last built Nov 8, 2026, 10:50 PM EST, more than 36 hours ago.'), findsOneWidget);
    });
    testWidgets('region-status stale on an otherwise ready read', (t) async {
      final st = (fx('region_status_ready') as List)
          .map((e) => (e as Map)['key'] == 'network.snapshots' ? {...e, 'state': 'stale'} : e)
          .toList();
      await pump(t, api({'region-status': st}));
      expect(has('an-health-stale'), isTrue);
      expect(has('an-traffic-ready'), isTrue);
    });
  });

  group('none: nothing built or no source', () {
    testWidgets('region-status none names its reason; other sections stay ready', (t) async {
      final st = (fx('region_status_ready') as List)
          .map(
            (e) => (e as Map)['key'] == 'network.findings'
                ? {...e, 'state': 'none', 'reason': 'No source covers Columbus yet.'}
                : e,
          )
          .toList();
      await pump(t, api({'region-status': st}));
      expect(has('an-findings-none'), isTrue);
      expect(find.text('Not available in Columbus, US yet'), findsOneWidget);
      expect(find.text('No source covers Columbus yet.'), findsOneWidget);
      expect(has('an-traffic-ready'), isTrue);
    });
    testWidgets('a read that answers pending is none, with the engine reason', (t) async {
      final j = {
        'status': {
          'state': 'pending',
          'reason': 'No repeater health has been built for this region yet.',
          'computedAt': null,
          'source': 'e6',
        },
        'builtAt': null,
        'rows': [],
      };
      await pump(t, api({'region-repeater-health': j}));
      expect(has('an-health-none'), isTrue);
      expect(find.text('No repeater health has been built for this region yet.'), findsOneWidget);
    });
    testWidgets('a gate with nothing stored is none', (t) async {
      await pump(
        t,
        api({
          'region-node-gate': {'gate': null, 'history': [], 'hopsFrom': 'e3'},
        }),
      );
      expect(has('an-gate-none'), isTrue);
      expect(find.text('The node-list check has not run for this region yet.'), findsOneWidget);
    });
  });

  group('error: a distinct, retryable state', () {
    testWidgets('a failed read; Try again reloads just that section', (t) async {
      final calls = <String, int>{};
      var fail = true;
      final a = AnalyzeApi(
        'https://cmh.meshsonar.com',
        client: MockClient((req) async {
          final fn = req.url.pathSegments.last;
          calls[fn] = (calls[fn] ?? 0) + 1;
          if (fn == 'region-traffic' && fail) return http.Response('boom', 500);
          final body = {
            'region-insights': fx('insights'),
            'region-traffic': fx('traffic'),
            'region-node-gate': fx('node_gate'),
            'region-repeater-health': fx('repeater_health'),
            'region-overview': fx('overview'),
            'region-status': fx('region_status_ready'),
          }[fn];
          return http.Response(jsonEncode(body), 200);
        }),
      );
      await pump(t, a);
      expect(has('an-traffic-error'), isTrue);
      expect(find.text('This did not load'), findsOneWidget);
      expect(has('an-findings-ready'), isTrue); // others unaffected
      fail = false;
      await t.tap(find.byKey(const Key('an-traffic-retry')));
      await t.pumpAndSettle();
      expect(has('an-traffic-ready'), isTrue);
      expect(calls['region-traffic'], 2);
      expect(calls['region-insights'], 1);
    });
    testWidgets('region-status error on a ready read', (t) async {
      final st = (fx('region_status_ready') as List)
          .map(
            (e) => (e as Map)['key'] == 'network.packets'
                ? {...e, 'state': 'error', 'reason': 'The packet unit failed.'}
                : e,
          )
          .toList();
      await pump(t, api({'region-status': st}));
      expect(has('an-traffic-error'), isTrue);
      expect(find.text('The packet unit failed.'), findsOneWidget);
    });
    testWidgets('region-status itself unreachable: sections still judged on their own reads', (t) async {
      await pump(t, api({'region-status': Exception('down')}));
      expect(has('an-findings-ready'), isTrue);
    });
  });

  testWidgets('gate: a trusted list shows the server sentence as Complete', (t) async {
    final j = Map<String, dynamic>.from(fx('node_gate') as Map);
    final g = Map<String, dynamic>.from(j['gate'] as Map)
      ..['state'] = 'complete'
      ..['trusted'] = true
      ..['reason'] = '950 of 1,000 hop codes heard in the last 24 h match a known node (95%).';
    j['gate'] = g;
    await pump(t, api({'region-node-gate': j}));
    expect(find.textContaining('Complete. 950 of 1,000'), findsOneWidget);
  });
}
