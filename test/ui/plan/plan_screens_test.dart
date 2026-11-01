// The native planning screens (lib/ui/plan): what a person sees and does, against the real answers the website's plan-native endpoint
// gives (fixtures from its own tests). The map is replaced (tiles never load in tests).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/plan/plan_native_api.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/core/plan/plan_overview.dart';
import 'package:meshsonar/core/plan/planner_query.dart';
import 'package:meshsonar/ui/plan/planner_screen.dart';
import 'package:meshsonar/ui/plan/plan_engine_common.dart';
import 'package:meshsonar/ui/plan/recommended_screen.dart';
import 'package:meshsonar/ui/plan/scenarios_screen.dart';
import 'package:meshsonar/ui/plan/site_detail_screen.dart';
import 'package:meshsonar/ui/plan/sites_screen.dart';
import 'package:meshsonar/ui/plan/tracker_screen.dart';
import 'package:meshsonar/ui/plan/site_link_screen.dart';
import 'package:meshsonar/ui/theme.dart';

String fxText(String n) => File('test/fixtures/plan_native/$n.json').readAsStringSync();
Map<String, dynamic> fx(String n) => jsonDecode(fxText(n)) as Map<String, dynamic>;

http.Response ok(String body) => http.Response(body, 200, headers: {'content-type': 'application/json'});
http.Response jerr(String msg, int code) => http.Response(jsonEncode({'error': msg}), code, headers: {'content-type': 'application/json'});

/// Answers every view from the fixtures; [override] can replace one.
class Server {
  final List<Uri> seen = [];
  http.Response? Function(Uri u)? override;
  late final PlanNativeApi api = PlanNativeApi('https://cmh.example', client: MockClient((req) async {
    seen.add(req.url);
    final o = override?.call(req.url);
    if (o != null) return o;
    if (req.url.path.endsWith('/candidates')) {
      return ok(jsonEncode({
        'items': [
          {
            'id': 'w1', 'kind': 'park', 'sub': 'Park', 'name': 'Cand w1', 'lat': 40.11, 'lon': -83.0, 'elevM': 300, 'promM': 5, 'pop3': 5000, 'gap3': 4000, 'score': 50, 'rank': 1, 'city': 'Delaware',
            'osm': 'way/1', 'links': [{'key': fx('overview')['repeaters'][0]['key'], 'km': 5, 'o33': 0.3, 't33': 'Likely', 'piece': 'core'}], 'siteLinks': [],
          }
        ]
      }));
    }
    final v = req.url.queryParameters['view'];
    return ok(fxText(const {'sites': 'sites', 'link': 'link', 'scenario': 'scenario', 'tracker': 'tracker', 'planner': 'planner'}[v] ?? 'overview'));
  }));
}

Widget wrap(Widget c) => MaterialApp(theme: meshSonarTheme(Brightness.dark), home: c);

void tall(WidgetTester t) {
  t.view.physicalSize = const Size(900, 3200);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
}

void main() {
  setUp(() => PlanMap.testMap = (c, m, l) => Text('map ${m.length} markers ${l.length} lines'));
  tearDown(() => PlanMap.testMap = null);

  group('Recommended build', () {
    testWidgets('shows the phases, the engine against the original plan, the budget and the risks', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(RecommendedScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rec-phase-1')), findsOneWidget);
      expect(find.textContaining('Connect'), findsWidgets);
      expect(find.byKey(const Key('rec-vs')), findsOneWidget);
      expect(find.byKey(const Key('rec-budget')), findsOneWidget);
      expect(find.byKey(const Key('rec-risks')), findsOneWidget);
      expect(find.textContaining('One failure still cuts a piece off'), findsOneWidget);
      expect(find.byKey(const Key('plan-map')), findsOneWidget);
    });

    testWidgets('editing a unit cost updates the totals; reset puts the defaults back', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(RecommendedScreen(api: s.api)));
      await t.pumpAndSettle();
      final before = (t.widget(find.byKey(const Key('rec-total-0-expected'))) as Text).data;
      expect(before, 'Expected: \$150'); // 1 site x (100 hardware + 50 mounting)
      final field = find.byKey(const Key('rec-cost-hardware-expected'));
      await t.ensureVisible(field);
      await t.enterText(field, '200');
      await t.pump();
      expect((t.widget(find.byKey(const Key('rec-total-0-expected'))) as Text).data, 'Expected: \$250');
      await t.ensureVisible(find.byKey(const Key('rec-budget-reset')));
      await t.tap(find.byKey(const Key('rec-budget-reset')));
      await t.pump();
      expect((t.widget(find.byKey(const Key('rec-total-0-expected'))) as Text).data, 'Expected: \$150');
    });

    testWidgets('a region with no plan says so; a failure offers Retry', (t) async {
      final s = Server()..override = (u) => ok(jsonEncode({'available': false, 'reason': 'No planning data for this region yet'}));
      await t.pumpWidget(wrap(RecommendedScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rec-unavailable')), findsOneWidget);
      expect(find.text('No planning data for this region yet'), findsOneWidget);

      var fail = true;
      final s2 = Server()..override = (u) => fail ? jerr('boom', 500) : null;
      await t.pumpWidget(wrap(RecommendedScreen(api: s2.api, key: UniqueKey())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rec-error')), findsOneWidget);
      fail = false;
      await t.tap(find.byKey(const Key('rec-retry')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('rec-list')), findsOneWidget);
    });
  });

  group('Planner', () {
    testWidgets('mount height and link tier are plain segments, no check mark that squeezes the label (it broke "Likely+" mid-word on a phone)', (t) async {
      t.view.physicalSize = const Size(360, 3200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final s = Server();
      await t.pumpWidget(wrap(PlannerScreen(api: s.api)));
      await t.pumpAndSettle();
      for (final k in ['planner-height', 'planner-tier']) {
        expect(find.descendant(of: find.byKey(Key(k)), matching: find.byIcon(Icons.check)), findsNothing, reason: k);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('asks the engine with the chosen settings and lists the steps', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(PlannerScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('planner-step-1')), findsNothing);
      await t.tap(find.text(mountName(20)));
      await t.pump();
      await t.ensureVisible(find.byKey(const Key('planner-run')));
      await t.tap(find.byKey(const Key('planner-run')));
      await t.pumpAndSettle();
      final q = s.seen.last.queryParameters;
      expect(q['view'], 'planner');
      expect(q['pq'], 's:today;n:6;h:20');
      expect(find.byKey(const Key('planner-figures')), findsOneWidget);
      expect(find.byKey(const Key('planner-step-1')), findsOneWidget);
      expect(find.textContaining('Adds'), findsWidgets);
      expect(find.byKey(const Key('plan-map')), findsOneWidget);
    });

    testWidgets('a busy or too-heavy query shows the server\'s sentence and a retry', (t) async {
      tall(t);
      final s = Server()..override = (u) => u.queryParameters['view'] == 'planner' ? jerr('The planner is busy; try again in a moment', 503) : null;
      await t.pumpWidget(wrap(PlannerScreen(api: s.api)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('planner-run')));
      await t.tap(find.byKey(const Key('planner-run')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('planner-error')), findsOneWidget);
      expect(find.text('The planner is busy; try again in a moment'), findsOneWidget);
    });

    testWidgets('a starting question (from the scenario lab) runs at once with the built sites', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(PlannerScreen(api: s.api, initial: const PlannerQuery(start: 'scenario', prebuiltSites: ['D2', 'P2']))));
      await t.pumpAndSettle();
      final q = s.seen.last.queryParameters;
      expect(q['pq'], startsWith('s:scenario'));
      expect(q['sites'], 'D2,P2');
      expect(find.byKey(const Key('planner-step-1')), findsOneWidget);
      expect(find.textContaining('Already built in your scenario: D2, P2'), findsOneWidget);
    });

    testWidgets('an empty answer says no site helps', (t) async {
      tall(t);
      final j = fx('planner')..['steps'] = <dynamic>[];
      final s = Server()..override = (u) => u.queryParameters['view'] == 'planner' ? ok(jsonEncode(j)) : null;
      await t.pumpWidget(wrap(PlannerScreen(api: s.api)));
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('planner-run')));
      await t.tap(find.byKey(const Key('planner-run')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('planner-empty')), findsOneWidget);
    });
  });

  group('Site explorer', () {
    testWidgets('lists sites in engine order, filters by search and kind, and says when nothing matches', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(SitesScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('sites-count')), findsOneWidget);
      expect(find.text('23 of 23 sites'), findsOneWidget);
      expect(find.byKey(const Key('site-w1')), findsOneWidget);
      await t.enterText(find.byKey(const Key('sites-search')), 'cand w2');
      await t.pump();
      expect(find.text('1 of 23 sites'), findsOneWidget);
      expect(find.byKey(const Key('site-w2')), findsOneWidget);
      await t.enterText(find.byKey(const Key('sites-search')), 'zzzz');
      await t.pump();
      expect(find.byKey(const Key('sites-empty')), findsOneWidget);
      await t.enterText(find.byKey(const Key('sites-search')), '');
      await t.pump();
      await t.tap(find.byKey(const Key('sites-kind-plan')));
      await t.pump();
      expect(find.text('20 of 23 sites'), findsOneWidget);
    });

    testWidgets('selecting two sites opens the comparison with a best value marked', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(SitesScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('sites-selbar')), findsNothing);
      await t.tap(find.byKey(const Key('site-sel-w1')));
      await t.pump();
      expect(tester0(t, const Key('sites-compare')).onPressed, isNull); // one site is not a comparison
      await t.tap(find.byKey(const Key('site-sel-w2')));
      await t.pump();
      await t.tap(find.byKey(const Key('sites-compare')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('compare-table')), findsOneWidget);
      expect(find.textContaining('Regional build step'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp(r'best in row')), findsWidgets);
      await t.tap(find.byKey(const Key('compare-remove-w2')));
      await t.pump();
      expect(find.byKey(const Key('compare-few')), findsOneWidget);
    });

    testWidgets('a site opens its dossier: sequence, links, nearby sites; a plan site\'s link opens the terrain profile', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(SiteDetailScreen(api: s.api, ref: 'c:w1')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('site-facts')), findsOneWidget);
      expect(find.textContaining('Likely+: step 1'), findsOneWidget);
      expect(find.byKey(const Key('site-links')), findsOneWidget);
      expect(find.byKey(const Key('site-alts')), findsOneWidget);
      expect(find.byKey(const Key('site-ask-planner')), findsOneWidget);
      expect(find.byKey(const Key('site-scenario')), findsNothing); // only an original plan site can be ticked in a scenario

      final ov = PlanOverview.parse(fx('overview'));
      final first = ov.sites.firstWhere((x) => x.links.isNotEmpty);
      await t.pumpWidget(wrap(SiteDetailScreen(api: s.api, ref: first.id, key: UniqueKey())));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('site-height')), findsOneWidget);
      expect(find.byKey(const Key('site-scenario')), findsOneWidget);
      await t.tap(find.text(mountName(20)));
      await t.pump();
      final firstLink = first.links.first;
      await t.ensureVisible(find.byKey(Key('link-${firstLink.to}')).first);
      await t.tap(find.byKey(Key('link-${firstLink.to}')).first);
      await t.pumpAndSettle();
      expect(find.byKey(const Key('link-body')), findsOneWidget);
    });

    testWidgets('unknown reference says so', (t) async {
      final s = Server();
      await t.pumpWidget(wrap(SiteDetailScreen(api: s.api, ref: 'ZZ9')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('site-unavailable')), findsOneWidget);
    });
  });

  group('Link profile', () {
    testWidgets('moving an antenna changes the figures; the stored heights are one tap away', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(LinkScreen(api: s.api, a: 'A', b: 'B')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('link-chart')), findsOneWidget);
      expect(find.text('Line blocked'), findsOneWidget);
      final stored33 = (fx('link')['stored'] as List)[1]['blockedM'];
      expect(find.text(Units.metric.distance(stored33.toDouble())), findsWidgets);
      await t.drag(find.byKey(const Key('link-ha')), const Offset(-400, 0));
      await t.pump();
      expect(find.byKey(const Key('link-figures')), findsOneWidget);
      await t.tap(find.byKey(const Key('link-33')));
      await t.pump();
      expect(find.text(Units.metric.distance(stored33.toDouble())), findsWidgets);
    });

    testWidgets('no stored profile for the pair says so', (t) async {
      final s = Server()..override = (u) => ok(jsonEncode({'found': false, 'a': 'A', 'b': 'B', 'profileCount': 127}));
      await t.pumpWidget(wrap(LinkScreen(api: s.api, a: 'A', b: 'B')));
      await t.pumpAndSettle();
      expect(find.textContaining('No stored terrain profile'), findsOneWidget);
      expect(find.textContaining('127'), findsOneWidget);
    });
  });

  group('Scenarios', () {
    testWidgets('ticking a site asks the server again; presets set the selection; pinning compares', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(ScenariosScreen(api: s.api, initialSites: const ['D2', 'P2'])));
      await t.pumpAndSettle();
      expect(s.seen.last.queryParameters['sites'], 'D2,P2');
      expect(find.byKey(const Key('scn-figures')), findsOneWidget);
      await t.tap(find.byKey(const Key('scn-pin')));
      await t.pump();
      expect(find.byKey(const Key('scn-pinned')), findsOneWidget);
      await t.ensureVisible(find.byKey(const Key('scn-preset-today')));
      await t.tap(find.byKey(const Key('scn-preset-today')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.seen.last.queryParameters['sites'], 'none');
      await t.tap(find.text(mountName(20)));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      expect(s.seen.last.queryParameters['h'], '20');
    });

    testWidgets('the live network is off until the region has a living plan', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(ScenariosScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.textContaining('needs a stored living plan'), findsOneWidget);
      expect(s.seen.last.queryParameters.containsKey('net'), isFalse);
    });

    testWidgets('a refresh that fails keeps the last figures and says so', (t) async {
      tall(t);
      var fail = false;
      final s = Server()..override = (u) => fail && u.queryParameters['view'] == 'scenario' ? jerr('nope', 500) : null;
      await t.pumpWidget(wrap(ScenariosScreen(api: s.api)));
      await t.pumpAndSettle();
      fail = true;
      await t.ensureVisible(find.byKey(const Key('scn-preset-today')));
      await t.tap(find.byKey(const Key('scn-preset-today')));
      await t.pump(const Duration(milliseconds: 400));
      await t.pumpAndSettle();
      await t.drag(find.byKey(const Key('scn-list')), const Offset(0, 4000));
      await t.pump();
      expect(find.byKey(const Key('scn-stale')), findsOneWidget);
      expect(find.byKey(const Key('scn-figures')), findsOneWidget);
    });
  });

  group('Build tracker', () {
    testWidgets('lists the sites with their next action and filters by status; no contact details', (t) async {
      tall(t);
      final s = Server();
      await t.pumpWidget(wrap(TrackerScreen(api: s.api)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('trk-site-w1')), findsOneWidget);
      expect(find.textContaining('Next: Confirm the mount spot'), findsWidgets);
      await t.tap(find.byKey(const Key('trk-status-Installed')));
      await t.pump();
      expect(find.byKey(const Key('trk-empty')), findsOneWidget);
      await t.tap(find.byKey(const Key('trk-all')));
      await t.pump();
      expect(find.byKey(const Key('trk-site-w3')), findsOneWidget);
      expect(find.textContaining('read-only'), findsOneWidget);
    });
  });
}

FilledButton tester0(WidgetTester t, Key k) => t.widget<FilledButton>(find.byKey(k));
