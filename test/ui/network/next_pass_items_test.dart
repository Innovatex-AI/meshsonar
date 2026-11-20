// AZ-3.6: the items of meshsonar-infra docs/planning/app-next-pass-list.md, each as written there.
//   3. finding code `traffic_spike` (section traffic, info or warn): the server's title and detail as sent, with an icon.
//   4. `repeaters_lost` / `repeaters_new` can arrive as info: nothing assumes warn; the badge says what was sent.
//   6. Network pulse surfaces (network-pulse-plan section 4): header chip states and the "What changed" card.
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

Map<String, dynamic> _insightsWith(List<Map<String, Object?>> rows) {
  final j = Map<String, dynamic>.from(fx('insights') as Map);
  j['rows'] = rows;
  return j;
}

AnalyzeApi _api(Map<String, Object?> over) {
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
      final v = table[req.url.pathSegments.last];
      if (v == null) return http.Response('no', 404);
      return http.Response(jsonEncode(v), 200);
    }),
  );
}

Future<void> _pump(WidgetTester t, AnalyzeApi a) async {
  t.view.physicalSize = const Size(900, 6000);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: ThemeData.dark(),
    home: Scaffold(
      body: AnalyzePanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', regionName: 'Columbus, US', timezone: 'America/New_York', api: a, now: () => _now),
    ),
  ));
  await t.pumpAndSettle();
}

Map<String, Object?> _row(String code, String severity, String section, String title, String detail) =>
    {'code': code, 'severity': severity, 'section': section, 'title': title, 'detail': detail, 'refs': <String>[]};

String _badgeOf(WidgetTester t, String code) {
  final row = find.byKey(Key('finding:$code'));
  final words = t.widgetList<Text>(find.descendant(of: row, matching: find.byType(Text))).map((e) => e.data).whereType<String>();
  return words.firstWhere((w) => severityWord.values.contains(w));
}

void main() {
  group('item 3: traffic_spike', () {
    testWidgets('shows the server title and detail as sent, with its own icon', (t) async {
      await _pump(
          t,
          _api({
            'region-insights': _insightsWith([
              _row('traffic_spike', 'info', 'traffic', 'Traffic 2.4x the usual for a Thursday morning', 'Packets per hour are well above the same hour last week.'),
            ])
          }));
      expect(find.byKey(const Key('finding:traffic_spike')), findsOneWidget);
      expect(find.textContaining('Traffic 2.4x the usual for a Thursday morning'), findsOneWidget);
      expect(find.textContaining('Packets per hour are well above the same hour last week.'), findsOneWidget);
      final icon = t.widget<Icon>(find.byKey(const Key('finding-icon:traffic_spike')));
      expect(icon.icon, Icons.trending_up);
      expect(_badgeOf(t, 'traffic_spike'), 'Note');
    });

    testWidgets('a warn traffic_spike says Watch', (t) async {
      await _pump(t, _api({'region-insights': _insightsWith([_row('traffic_spike', 'warn', 'traffic', 'Traffic 7x normal', 'Detail.')])}));
      expect(_badgeOf(t, 'traffic_spike'), 'Watch');
    });

    test('every finding has an icon: by code, by section, then a default', () {
      Finding f(String code, String section) => Finding(code: code, severity: 'info', section: section, title: 't', detail: 'd');
      expect(findingIcon(f('traffic_spike', 'traffic')), Icons.trending_up);
      expect(findingIcon(f('repeaters_lost', 'network')), Icons.remove_circle_outline);
      expect(findingIcon(f('something_new', 'links')), Icons.link);
      expect(findingIcon(f('something_new', 'elsewhere')), Icons.info_outline);
    });
  });

  group('item 4: repeaters_lost and repeaters_new do not assume warn', () {
    testWidgets('an info repeaters_lost is a Note, sorted with the infos', (t) async {
      await _pump(
          t,
          _api({
            'region-insights': _insightsWith([
              _row('repeaters_new', 'info', 'network', '1 new repeater this week', 'Hilltop RPT.'),
              _row('repeaters_lost', 'info', 'network', '1 repeater went quiet this week', 'Old Mill RPT.'),
              _row('silent_repeaters', 'warn', 'network', '2 repeaters heard but never relaying', 'Check them.'),
            ])
          }));
      expect(_badgeOf(t, 'repeaters_lost'), 'Note');
      expect(_badgeOf(t, 'repeaters_new'), 'Note');
      expect(_badgeOf(t, 'silent_repeaters'), 'Watch');
      expect(find.text('Watch'), findsOneWidget);
      // the warn comes first; the two infos keep the engine's own order
      final y = {for (final c in ['silent_repeaters', 'repeaters_new', 'repeaters_lost']) c: t.getTopLeft(find.byKey(Key('finding:$c'))).dy};
      expect(y['silent_repeaters']! < y['repeaters_new']!, isTrue);
      expect(y['repeaters_new']! < y['repeaters_lost']!, isTrue);
    });

    testWidgets('a warn repeaters_lost is still a Watch', (t) async {
      await _pump(t, _api({'region-insights': _insightsWith([_row('repeaters_lost', 'warn', 'network', '3 repeaters went quiet', 'x')])}));
      expect(_badgeOf(t, 'repeaters_lost'), 'Watch');
    });

    test('sorting follows the severity sent, never the code', () {
      Finding f(String code, String sev) => Finding(code: code, severity: sev, section: 'network', title: code, detail: '');
      final out = sortFindings([f('repeaters_lost', 'info'), f('critical_nodes', 'alert'), f('repeaters_new', 'warn')]);
      expect(out.map((e) => e.code), ['critical_nodes', 'repeaters_new', 'repeaters_lost']);
    });
  });
}
