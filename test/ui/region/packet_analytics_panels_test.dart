// Region tabs Hops, Silent and Wardrive (website vertical W): states (loading, ready, empty window, pending with the server's reason,
// error + Retry, 404), the sample line with data age on every tab, window change re-asks, the group-text switch, the silent search and
// checklist, "Yours" marking, and the wardrive note that pings cannot be told from group text.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/airtime_share.dart';
import 'package:meshsonar/ui/region/packet_analytics_panels.dart';
import 'package:meshsonar/ui/theme.dart';

final _now = DateTime.utc(2026, 11, 1, 12);
Widget _app(Widget child) => MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: child));
const _status = {'state': 'ready', 'reason': null, 'computedAt': '2026-11-01T11:59:00Z', 'source': 'ext_packet'};
final _sample = {'windowHours': 24, 'observations': 130, 'packets': 90, 'observers': 4, 'oldest': '2026-11-01T00:00:00Z', 'newest': '2026-11-01T11:58:00Z'};

Map<String, dynamic> _hop() => {
      'status': _status,
      ..._sample,
      'all': [
        {'hops': 0, 'flood': 10, 'direct': 4, 'other': 0},
        {'hops': 3, 'flood': 50, 'direct': 0, 'other': 0},
        {'hops': 4, 'flood': 0, 'direct': 20, 'other': 0},
      ],
      'group': [
        {'hops': 3, 'flood': 8, 'direct': 0, 'other': 0},
      ],
    };

Map<String, dynamic> _silent({List<Map<String, dynamic>>? rows, Map<String, dynamic>? status}) => {
      'status': status ?? _status,
      ..._sample,
      'packets': null,
      'observers': null,
      'relayEvidence': 4200,
      'counts': {'repeaters': 12, 'advertising': 9, 'relaying': 7, 'silent': 2},
      'silent': rows ??
          [
            {
              'key': 'ab' * 32,
              'name': 'North Hill',
              'hashPrefix': 'ab12',
              'hashSizeBytes': 2,
              'lastHeardAt': '2026-11-01T11:50:00Z',
              'signalGrade': 'A',
              'snrMeanDb': 7,
              'hint': {'code': 'strong_link', 'text': 'Its adverts arrive strong but it never shows up as a relay.'},
              'checks': ['Repeat mode: confirm it forwards.', 'Flood hop limit.'],
            },
            {
              'key': 'cd' * 32,
              'name': null,
              'hashPrefix': 'cd34',
              'hint': {'code': 'unknown_link', 'text': 'We only know it advertises.'},
              'checks': ['Power.'],
            },
          ],
      'caveats': ['Only paths that reach an observer are seen.'],
    };

Map<String, dynamic> _air() => {
      'status': _status,
      ..._sample,
      'transmissions': 107,
      'rows': [
        {'t': 5, 'transport': false, 'hops': 0, 'ps': 1, 'n': 30},
        {'t': 5, 'transport': false, 'hops': 3, 'ps': 2, 'n': 20},
        {'t': 4, 'transport': false, 'hops': 2, 'ps': 1, 'n': 40},
        {'t': 0, 'transport': true, 'hops': 1, 'ps': 3, 'n': 10},
        {'t': 3, 'transport': false, 'hops': 5, 'ps': 1, 'n': 7},
      ],
      'note': 'Packets heard by outside live feeds carry no text, so a wardrive ping cannot be told from other group text.',
    };

MockClient _c(Object Function(Uri) body, {List<Uri>? log, int code = 200}) => MockClient((r) async {
      log?.add(r.url);
      return http.Response(jsonEncode(body(r.url)), code);
    });

void main() {
  group('Hops', () {
    testWidgets('ready: finding, figures, sample line with data age, query carries the window', (tester) async {
      final log = <Uri>[];
      await tester.pumpWidget(_app(HopsPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _c((_) => _hop(), log: log), now: () => _now)));
      await tester.pumpAndSettle();
      expect(log.single.path, '/api/cmh/region-hop-route');
      expect(log.single.queryParameters, {'hours': '24'});
      expect(find.textContaining('of packets heard here were flood-routed'), findsOneWidget);
      expect(find.textContaining('Most arrive after 3 hops'), findsOneWidget);
      final line = tester.widget<Text>(find.byKey(const Key('sample-line'))).data!;
      expect(line, contains('Last 24 h'));
      expect(line, contains('130 observations'));
      expect(line, contains('90 distinct packets'));
      expect(line, contains('4 observers'));
      expect(line, contains('newest packet 2 min ago'));
    });

    testWidgets('changing the window asks again; Group text narrows the figures', (tester) async {
      final log = <Uri>[];
      await tester.pumpWidget(_app(HopsPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _c((_) => _hop(), log: log), now: () => _now)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('48 h'));
      await tester.pumpAndSettle();
      expect(log.last.queryParameters, {'hours': '48'});
      await tester.tap(find.text('Group text'));
      await tester.pumpAndSettle();
      expect(find.textContaining('of group texts heard here were flood-routed'), findsOneWidget);
    });

    testWidgets('no observations: honest empty text, no chart', (tester) async {
      await tester.pumpWidget(_app(HopsPanel(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          client: _c((_) => {'status': _status, 'windowHours': 24, 'observations': 0, 'packets': 0, 'observers': 0, 'newest': null, 'all': [], 'group': []}),
          now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hops-empty')), findsOneWidget);
      expect(find.byKey(const Key('chart-hops-hist')), findsNothing);
    });

    testWidgets('error then Retry recovers; 404 says not published', (tester) async {
      var fail = true;
      final c = MockClient((_) async => fail ? http.Response('down', 503) : http.Response(jsonEncode(_hop()), 200));
      await tester.pumpWidget(_app(HopsPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: c, now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hops-error')), findsOneWidget);
      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hops-finding')), findsOneWidget);
      await tester.pumpWidget(_app(HopsPanel(baseUrl: 'https://old.meshsonar.com', regionSlug: 'old', client: _c((_) => {}, code: 404), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hops-notfound')), findsOneWidget);
    });
  });

  group('Silent repeaters', () {
    testWidgets('lists them with the hint and checklist; Yours is marked; the caveats and evidence show', (tester) async {
      await tester.pumpWidget(_app(SilentRepeatersPanel(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', ownKeys: {'ab' * 32}, client: _c((_) => _silent()), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('silent-finding')), findsOneWidget);
      expect(find.textContaining('2 of 9 repeaters heard advertising never appeared'), findsOneWidget);
      expect(find.textContaining('North Hill  (yours)'), findsOneWidget);
      expect(find.textContaining('Code ab12 - last heard 10 min ago - Grade A'), findsOneWidget);
      expect(find.textContaining('cdcdcdcd...'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('sample-line'))).data, contains('4,200 relay hops'));
      await tester.tap(find.textContaining('North Hill'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Repeat mode: confirm it forwards.'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('silent-caveats')), 300, scrollable: find.byType(Scrollable).first);
      expect(find.textContaining('Only paths that reach an observer are seen.'), findsOneWidget);
    });

    testWidgets('search narrows by name or code, and says when nothing matches', (tester) async {
      await tester.pumpWidget(_app(SilentRepeatersPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _c((_) => _silent()), now: () => _now)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('silent-find')), 'cd34');
      await tester.pumpAndSettle();
      expect(find.textContaining('North Hill'), findsNothing);
      await tester.enterText(find.byKey(const Key('silent-find')), 'zzz');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('silent-nomatch')), findsOneWidget);
    });

    testWidgets('too little traffic: pending reason shown, no list and no verdict', (tester) async {
      await tester.pumpWidget(_app(SilentRepeatersPanel(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          client: _c((_) => _silent(rows: [], status: {'state': 'pending', 'reason': 'Only 20 relay hops were seen in the last 24 h; at least 300 are needed.'})),
          now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.textContaining('at least 300 are needed'), findsOneWidget);
      expect(find.byKey(const Key('silent-empty')), findsOneWidget);
      expect(find.byKey(const Key('silent-finding')), findsNothing);
    });

    testWidgets('none silent is stated plainly', (tester) async {
      final b = _silent(rows: []);
      (b['counts'] as Map)['silent'] = 0;
      await tester.pumpWidget(_app(SilentRepeatersPanel(baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', client: _c((_) => b), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.textContaining('All 9 repeaters heard advertising also appeared'), findsOneWidget);
      expect(find.text('No silent repeater found.'), findsOneWidget);
    });
  });

  group('Wardrive share', () {
    testWidgets('shows the model at the preset, the exact count share, the note and the sample', (tester) async {
      await tester.pumpWidget(_app(AirtimeSharePanel(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          radio: LoraRadio.meshcoreUs,
          radioLabel: 'US preset',
          client: _c((_) => _air()),
          now: () => _now)));
      await tester.pumpAndSettle();
      // GOLDEN: the website shows 46.7% of transmissions and 33.6% of modelled airtime for this mix at this preset
      expect(find.text('46.7%'), findsOneWidget);
      expect(find.text('33.6%'), findsOneWidget);
      expect(find.byKey(const Key('airtime-note')), findsOneWidget);
      expect(find.textContaining('cannot be told from other group text'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('sample-line'))).data, contains('130 observations'));
      expect(find.textContaining('Group text is 47% of the unique transmissions'), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('chart-airtime-type')), 300);
      expect(find.textContaining('Modelled at US preset (SF7, 62.5 kHz, 4/5)'), findsOneWidget);
    });

    testWidgets('no preset on file: says it uses the US default, not this region\'s', (tester) async {
      await tester.pumpWidget(_app(AirtimeSharePanel(baseUrl: 'https://x.meshsonar.com', regionSlug: 'x', client: _c((_) => _air()), now: () => _now)));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.byKey(const Key('chart-airtime-type')), 300);
      expect(find.textContaining('no preset on file'), findsOneWidget);
    });

    testWidgets('a slower preset changes the airtime share, not the count share', (tester) async {
      await tester.pumpWidget(_app(AirtimeSharePanel(
          baseUrl: 'https://cmh.meshsonar.com', regionSlug: 'cmh', radio: const LoraRadio(10, 250, 5), radioLabel: 'Slow', client: _c((_) => _air()), now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.text('46.7%'), findsOneWidget);
      expect(find.text('32.7%'), findsOneWidget);
    });

    testWidgets('empty window and unavailable (group host) show the reason, no chart', (tester) async {
      await tester.pumpWidget(_app(AirtimeSharePanel(
          baseUrl: 'https://cmh.meshsonar.com',
          regionSlug: 'cmh',
          client: _c((_) => {'status': {'state': 'unavailable', 'reason': 'Packet analytics are shown per region.'}, 'transmissions': null, 'rows': []}),
          now: () => _now)));
      await tester.pumpAndSettle();
      expect(find.text('Packet analytics are shown per region.'), findsOneWidget);
      expect(find.byKey(const Key('airtime-empty')), findsOneWidget);
    });
  });
}
