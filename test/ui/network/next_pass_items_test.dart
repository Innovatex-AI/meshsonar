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
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/v1/network_api.dart';
import 'package:meshsonar/ui/network/network_header.dart';
import 'package:meshsonar/ui/region/analyze_panel.dart';
import 'package:meshsonar/ui/theme.dart';

Object fx(String n) => jsonDecode(File('test/fixtures/analyze/$n.json').readAsStringSync()) as Object;

final _now = DateTime.utc(2026, 11, 11, 9);

Map<String, dynamic> _v1(String n) => jsonDecode(File('test/fixtures/analyzer/$n.json').readAsStringSync()) as Map<String, dynamic>;

/// /v1/pulse and /v1/summary from the contract fixtures, changed by [pulse] / [summary]; null = not live (404).
void _useV1({List<Map<String, Object?>>? pulse, bool pulseLive = true, void Function(Map<String, dynamic> data, Map<String, dynamic> meta)? summary}) {
  resetV1NotLive();
  networkApiFactory = (b) => NetworkApi(b, client: MockClient((r) async {
        switch (r.url.path) {
          case '/v1/pulse':
            if (!pulseLive) return http.Response('', 404);
            final j = _v1('pulse');
            if (pulse != null) j['data'] = pulse;
            return http.Response(jsonEncode(j), 200);
          case '/v1/summary':
            final j = _v1('summary');
            summary?.call(j['data'] as Map<String, dynamic>, j['meta'] as Map<String, dynamic>);
            return http.Response(jsonEncode(j), 200);
        }
        return http.Response('', 404);
      }));
  addTearDown(() {
    networkApiFactory = (b) => NetworkApi(b);
    resetV1NotLive();
  });
}

Map<String, Object?> _event(String id, String severity, String state, String startedAt, String title, {String? web}) => {
      'id': id,
      'kind': 'traffic_spike',
      'severity': severity,
      'state': state,
      'startedAt': startedAt,
      'endedAt': state == 'closed' ? startedAt : null,
      'title': title,
      'detail': 'Detail of $title.',
      'evidence': <String, Object?>{},
      'subjects': <Object?>[],
      'links': {'web': ?web},
    };

Future<void> _pumpChip(WidgetTester t) async {
  await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: const Scaffold(body: Center(child: PulseChip(baseUrl: 'https://cmh.meshsonar.com')))));
  await t.pumpAndSettle();
}

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
    theme: meshSonarTheme(Brightness.dark),
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

  group('item 6: network pulse surfaces', () {
    NetworkRead<List<PulseEvent>> pulseRead(List<PulseEvent> e, {DateTime? offline}) => NetworkRead(e, offlineAsOf: offline);
    NetworkRead<NetworkSummary> summaryRead({int? last24h, DateTime? lastAt, DateTime? generatedAt}) => NetworkRead(
        NetworkSummary(packets24h: last24h, lastPacketAt: lastAt),
        meta: generatedAt == null ? null : V1Meta.fromJson({'apiVersion': '1.0', 'generatedAt': generatedAt.toIso8601String(), 'status': {'state': 'ready'}}));
    final open = PulseEvent(id: 'a', kind: 'traffic_spike', severity: 'warn', state: 'open', title: 'Traffic 7x normal', detail: '');
    final closed = PulseEvent(id: 'b', kind: 'traffic_spike', severity: 'info', state: 'closed', title: 'Old spike', detail: '');
    final t0 = DateTime.utc(2026, 11, 20, 14);

    test('chip state rule: hidden / no feed / unusual / normal', () {
      expect(pulseChipStateOf(null, null), PulseChipState.hidden, reason: 'no /v1/pulse yet');
      expect(pulseChipStateOf(pulseRead([open], offline: t0), null), PulseChipState.hidden, reason: 'a stored copy never says "now"');
      expect(pulseChipStateOf(pulseRead([]), null), PulseChipState.normal);
      expect(pulseChipStateOf(pulseRead([closed]), null), PulseChipState.normal, reason: 'only open events are unusual');
      expect(pulseChipStateOf(pulseRead([open]), null), PulseChipState.unusual);
      expect(pulseChipStateOf(pulseRead([open]), summaryRead(last24h: 0)), PulseChipState.noFeed);
      expect(pulseChipStateOf(pulseRead([]), summaryRead(last24h: 50, lastAt: t0.subtract(const Duration(hours: 3)), generatedAt: t0)), PulseChipState.noFeed);
      expect(pulseChipStateOf(pulseRead([]), summaryRead(last24h: 50, lastAt: t0.subtract(const Duration(minutes: 90)), generatedAt: t0)), PulseChipState.normal);
      expect(noPacketFeedAfter, const Duration(hours: 2));
    });

    testWidgets('green Normal when the pulse read is live and nothing is open', (t) async {
      _useV1(pulse: []);
      await _pumpChip(t);
      expect(find.byKey(const Key('pulse-chip-normal')), findsOneWidget);
      expect(find.text('Normal'), findsOneWidget);
      await t.tap(find.byKey(const Key('pulse-chip')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('pulse-sheet-normal')), findsOneWidget);
    });

    testWidgets('amber Unusual with the most serious open event first', (t) async {
      _useV1();
      await _pumpChip(t);
      expect(find.byKey(const Key('pulse-chip-unusual')), findsOneWidget);
      expect(find.text('Unusual: Riverside RPT went quiet +1'), findsOneWidget);
    });

    testWidgets('grey No packet feed when the summary shows no packets in 24 h', (t) async {
      _useV1(summary: (d, m) => (d['packets'] as Map)['last24h'] = 0);
      await _pumpChip(t);
      expect(find.byKey(const Key('pulse-chip-noFeed')), findsOneWidget);
      expect(find.text('No packet feed'), findsOneWidget);
      await t.tap(find.byKey(const Key('pulse-chip')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('pulse-sheet-no-feed')), findsOneWidget);
    });

    testWidgets('hidden while the server has no /v1/pulse', (t) async {
      _useV1(pulseLive: false);
      await _pumpChip(t);
      expect(find.byKey(const Key('pulse-chip')), findsNothing);
      expect(find.byKey(const Key('pulse-chip-hidden')), findsOneWidget);
    });

    testWidgets('the chip label does not clip at large text', (t) async {
      _useV1();
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: const MediaQuery(
          data: MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(2.5)),
          child: Scaffold(body: Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: PulseChip(baseUrl: 'https://cmh.meshsonar.com')))),
        ),
      ));
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      expect(find.byKey(const Key('pulse-chip')), findsOneWidget);
    });

    testWidgets('What changed: the newest 3 pulse items, open or closed, at the top of Analyze; a Network link opens in the app', (t) async {
      _useV1(pulse: [
        _event('p1', 'info', 'closed', '2026-11-19T08:00:00.000Z', 'Oldest item'),
        _event('p2', 'warn', 'open', '2026-11-20T12:00:00.000Z', 'Newest item', web: 'https://cmh.meshsonar.com/nodes/${'a7'.padRight(64, '0')}'),
        _event('p3', 'info', 'closed', '2026-11-20T09:00:00.000Z', 'Second item', web: 'https://example.org/elsewhere'),
        _event('p4', 'info', 'open', '2026-11-20T10:00:00.000Z', 'Third item'),
      ]);
      await _pump(t, _api({}));
      expect(find.byKey(const Key('what-changed')), findsOneWidget);
      expect(find.text('What changed'), findsOneWidget);
      final ys = [for (final id in ['p2', 'p4', 'p3']) t.getTopLeft(find.byKey(ValueKey('pulse-item-$id'))).dy];
      expect(ys, [...ys]..sort(), reason: 'newest first');
      expect(find.byKey(const ValueKey('pulse-item-p1')), findsNothing, reason: 'only the newest 3');
      // above the findings
      expect(t.getTopLeft(find.byKey(const Key('what-changed'))).dy, lessThan(t.getTopLeft(find.text('What needs attention')).dy));
      // links: a Network link is a tappable row; a foreign link is not
      final p2 = t.widget<ListTile>(find.byKey(const ValueKey('pulse-item-p2')));
      final p3 = t.widget<ListTile>(find.byKey(const ValueKey('pulse-item-p3')));
      expect(p2.onTap, isNotNull);
      expect(p3.onTap, isNull);
      expect(pulseLinkOf(PulseEvent(id: 'x', kind: 'k', severity: 'info', state: 'open', title: 't', detail: '', webLink: Uri.parse('https://cmh.meshsonar.com/nodes/${'a7'.padRight(64, '0')}'))),
          NetworkRequest.node('a7'.padRight(64, '0'), region: 'cmh'));
    });

    testWidgets('What changed hides while the server has no pulse read', (t) async {
      _useV1(pulseLive: false);
      await _pump(t, _api({}));
      expect(find.byType(WhatChangedCard, skipOffstage: false), findsOneWidget, reason: 'a zero-height row counts as offstage');
      expect(find.byKey(const Key('what-changed')), findsNothing);
      expect(find.byKey(const Key('what-changed-hidden'), skipOffstage: false), findsOneWidget);
    });
  });
}
