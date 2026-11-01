// The native Plan tools as screens: what the person sees, the offline behaviour, and that nothing leaves the phone that
// should not. Screens are pushed over the real app (so AppScope, units and the Plan tab are real) with an injected HTTP client.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/plan/airtime_calc.dart';
import 'package:meshsonar/core/plan/plan_store.dart';
import 'package:meshsonar/ui/plan/airtime_screen.dart';
import 'package:meshsonar/ui/plan/coverage_check_screen.dart';
import 'package:meshsonar/ui/plan/link_screen.dart';
import 'package:meshsonar/ui/plan/painter_screen.dart';
import 'package:meshsonar/ui/plan/plan_common.dart';
import 'package:meshsonar/ui/plan/presets_screen.dart';

import '../fakes.dart';
import '../shell_test.dart' show phone, drain;

http.Response _json(Object b, [int status = 200]) => http.Response(jsonEncode(b), status, headers: {'content-type': 'application/json'});

Future<void> open(WidgetTester tester, Harness h, Widget screen) async {
  await h.pumpApp(tester);
  await tapShellTab(tester, 'Plan');
  await tester.pumpAndSettle();
  final ctx = tester.element(find.byKey(const Key('plan-list')));
  Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => screen));
  await tester.pumpAndSettle();
}

Map<String, dynamic> _score({double hill = 215}) => {
      'km': 6.0,
      'bullingtonDb': 0,
      'terrainModel': {'odds': 0.2, 'tier': 'Likely'},
      'profile': {
        'distanceKm': [for (var i = 0; i <= 40; i++) i * 0.15],
        // flat valley with an optional ridge in the middle
        'groundM': [for (var i = 0; i <= 40; i++) (i > 17 && i < 23) ? hill : 200.0],
      },
      'source': 'AWS Terrain Tiles (test)',
    };

void main() {
  group('Airtime and load', () {
    testWidgets('calculator runs on the phone, matches the formula, and reacts to the packet kind', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      await open(tester, h, AirtimeScreen(store: PlanStore(), client: () => MockClient((r) async => _json({'error': 'down'}, 503))));
      final want = fmtMs(timeOnAir(packetBytes(const PacketSpec(PayloadKind.group, chars: 40, hops: 2)).total, meshcoreUs).totalMs);
      expect(tester.widget<Text>(find.byKey(const Key('airtime-toa'))).data, want);
      await tester.tap(find.byKey(const Key('airtime-kind-ack')));
      await tester.pump();
      final ack = fmtMs(timeOnAir(packetBytes(const PacketSpec(PayloadKind.ack, hops: 2)).total, meshcoreUs).totalMs);
      expect(tester.widget<Text>(find.byKey(const Key('airtime-toa'))).data, ack);
      expect(ack, isNot(want));
      await drain(tester);
    });

    testWidgets('live load is shown from the server; offline it is the stored copy labelled with its age', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      final store = PlanStore(clock: () => DateTime.utc(2026, 11, 1, 6));
      var online = true;
      final body = {
        'hours': 24, 'flagPct': 10, 'radio': {'sf': 7, 'bwKHz': 62.5, 'cr': 5}, 'counts': {'packets': 1, 'observations': 2, 'transmissions': 2},
        'observers': [
          {'id': 'o1', 'name': 'INNO-OB-1', 'observations': 2, 'airtimeS': 5.0, 'meanPct': 0.01, 'peakPct': 12.0, 'hoursOver': 1, 'mix': {'fixedS': 1.0, 'floodByHopS': [1.0], 'advertByHopS': []}}
        ],
        'byType': [{'type': 'ADVERT', 'transmissions': 2, 'airtimeS': 5.0}], 'talkers': [], 'floodHops': [], 'lastHourTransmissions': 1, 'region': 'CMH', 'fetch': {},
      };
      MockClient mk() => MockClient((r) async {
            if (!online) throw http.ClientException('offline');
            return _json(body);
          });
      await open(tester, h, AirtimeScreen(store: store, client: mk));
      expect(find.textContaining('INNO-OB-1'), findsWidgets);
      expect(find.byKey(const Key('airtime-summary')), findsOneWidget);
      expect(find.textContaining('crossed 10 %'), findsOneWidget);
      expect(find.textContaining('Offline'), findsNothing);
      await drain(tester);
      // second visit, no network
      online = false;
      await tester.pageBack();
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const Key('plan-list')));
      Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => AirtimeScreen(store: store, client: mk)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Offline'), findsOneWidget);
      expect(find.textContaining('INNO-OB-1'), findsWidgets);
      await drain(tester);
    });

    testWidgets('a region without the feed shows the server sentence, the calculator still works', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      await open(tester, h, AirtimeScreen(store: PlanStore(), client: () => MockClient((r) async => _json({'error': 'Live channel load is not available in this region yet'}, 404))));
      expect(find.byKey(const Key('plan-error')), findsOneWidget);
      expect(find.textContaining('not available in this region'), findsOneWidget);
      expect(find.byKey(const Key('airtime-toa')), findsOneWidget);
      await drain(tester);
    });
  });

  group('Radio presets', () {
    testWidgets('24 rows against the base preset, the base marked, CR switch changes airtime; US default when no region preset', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      await open(tester, h, const PresetsScreen());
      expect(find.byKey(const Key('presets-table')), findsOneWidget);
      expect(find.textContaining(RegExp(r'^SF\d+ / ')), findsNWidgets(24));
      expect(find.textContaining('(now)'), findsOneWidget);
      List<String?> table() => tester.widgetList<Text>(find.descendant(of: find.byKey(const Key('presets-table')), matching: find.byType(Text))).map((t) => t.data).toList();
      final before = table();
      await tester.tap(find.descendant(of: find.byKey(const Key('presets-cr')), matching: find.text('4/8')));
      await tester.pump();
      final after = table();
      expect(after, isNot(before));
      await drain(tester);
    });
  });

  group('Point-to-point link', () {
    testWidgets('one profile request carries only the two points; heights re-score with no second request; offline reuses the profile', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      final sent = <Map>[];
      var online = true;
      final store = PlanStore();
      MockClient mk() => MockClient((r) async {
            if (!online) throw http.ClientException('offline');
            sent.add(jsonDecode(r.body) as Map);
            return _json(_score());
          });
      await open(tester, h, LinkScreen(store: store, client: mk, initialA: const LatLng(39.96, -82.99), initialB: const LatLng(40.0, -82.93)));
      await tester.ensureVisible(find.byKey(const Key('link-run')));
      await tester.tap(find.byKey(const Key('link-run')));
      await tester.pumpAndSettle();
      expect(sent.length, 1);
      expect(sent.single.keys.toSet(), {'a', 'b', 'haM', 'hbM'});
      expect(find.byKey(const Key('link-result')), findsOneWidget);
      expect(find.byKey(const Key('link-los')), findsOneWidget);
      final los1 = tester.widget<PlanNote>(find.byKey(const Key('link-los'))).text;
      expect(los1, startsWith('No line of sight'), reason: 'the ridge is 100 m above the valley at 20/26 ft');
      // raise both antennas far above the ridge: still one request, now clear
      await tester.ensureVisible(find.byKey(const Key('link-ha')));
      final ha = tester.widget<Slider>(find.byKey(const Key('link-ha')));
      ha.onChanged!(200);
      final hb = tester.widget<Slider>(find.byKey(const Key('link-hb')));
      hb.onChanged!(200);
      await tester.pumpAndSettle();
      expect(sent.length, 1);
      expect(tester.widget<PlanNote>(find.byKey(const Key('link-los'))).text, isNot(los1));
      await drain(tester);

      // a new visit while offline: the stored profile for the same pair scores at once
      online = false;
      await tester.pageBack();
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const Key('plan-list')));
      Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => LinkScreen(store: store, client: mk, initialA: const LatLng(39.96, -82.99), initialB: const LatLng(40.0, -82.93))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('link-result')), findsOneWidget);
      expect(find.textContaining('Offline'), findsOneWidget);
      await drain(tester);
    });

    testWidgets('points more than 40 km apart are refused before any request', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      var calls = 0;
      await open(tester, h, LinkScreen(store: PlanStore(), client: () => MockClient((r) async { calls++; return _json(_score()); }), initialA: const LatLng(39.0, -82.0), initialB: const LatLng(40.0, -82.0)));
      expect(find.byKey(const Key('link-toofar')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('link-run')));
      expect(tester.widget<FilledButton>(find.byKey(const Key('link-run'))).onPressed, isNull);
      expect(calls, 0);
      await drain(tester);
    });

    testWidgets('typed coordinates set a point; nonsense gets a sentence', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      await open(tester, h, LinkScreen(store: PlanStore(), client: () => MockClient((r) async => _json(_score()))));
      await tester.ensureVisible(find.byKey(const Key('link-a-field')));
      await tester.enterText(find.byKey(const Key('link-a-field')), 'banana');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('Type latitude, longitude'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('link-a-field')), '39.96, -82.99');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.textContaining('Type latitude'), findsNothing);
      expect(parseLatLon('39.96, -82.99'), const LatLng(39.96, -82.99));
      expect(parseLatLon('91, 0'), isNull);
      await drain(tester);
    });
  });

  group('Coverage painter', () {
    Map<String, dynamic> paint() => {
          'mode': 'coverage',
          'params': {'lat': 40.1, 'lon': -82.9, 'antennaFt': 33, 'txDbm': 22, 'gainDbi': 3, 'receiver': 'handheld', 'radiusKm': 10},
          'model': {'note': 'Estimate'}, 'terrain': {'source': 'AWS Terrain Tiles'}, 'sweep': {'groundM': 250},
          'bands': [
            {'id': 'below', 'label': 'Below', 'areaKm2': 200.0}, {'id': 'fringe', 'label': 'f', 'areaKm2': 10.0},
            {'id': 'usable', 'label': 'u', 'areaKm2': 5.0}, {'id': 'solid', 'label': 's', 'areaKm2': 2.5}
          ],
          'coveredKm2': 17.5,
          'population': {'inRadius': 1000, 'covered': 400, 'newlyCovered': 100, 'liveRepeaters': 2},
          'links': [],
          'footprint': {'type': 'FeatureCollection', 'features': [
            {'type': 'Feature', 'properties': {'band': 'solid'}, 'geometry': {'type': 'MultiPolygon', 'coordinates': [[[[-82.9, 40.1], [-82.89, 40.11], [-82.88, 40.1], [-82.9, 40.1]]]]}}
          ]},
          'cached': false, 'computedAt': '2026-11-01T00:00:00Z',
        };

    testWidgets('paints from the server, shows area and people; a server refusal is shown in its own words; offline reuses the last paint', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      final store = PlanStore();
      var mode = 'ok';
      MockClient mk() => MockClient((r) async {
            if (mode == 'down') throw http.ClientException('x');
            if (mode == 'bad') return _json({'error': 'point must be in or near this region'}, 400);
            return _json(paint());
          });
      await open(tester, h, PainterScreen(store: store, client: mk, initialPoint: const LatLng(40.1, -82.9)));
      await tester.ensureVisible(find.byKey(const Key('painter-run')));
      await tester.tap(find.byKey(const Key('painter-run')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('painter-result')), findsOneWidget);
      expect(find.textContaining('17.5'), findsWidgets);
      expect(find.text('Solid (over 12 dB)'), findsOneWidget);
      expect(find.byKey(const Key('painter-nolinks')), findsOneWidget);
      mode = 'bad';
      await tester.tap(find.byKey(const Key('painter-run')));
      await tester.pumpAndSettle();
      expect(find.text('point must be in or near this region'), findsOneWidget);
      mode = 'down';
      await tester.pageBack();
      await tester.pumpAndSettle();
      final ctx = tester.element(find.byKey(const Key('plan-list')));
      Navigator.of(ctx).push(MaterialPageRoute<void>(builder: (_) => PainterScreen(store: store, client: mk, initialPoint: const LatLng(40.1, -82.9))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('painter-result')), findsOneWidget);
      expect(find.textContaining('Offline'), findsOneWidget);
      await drain(tester);
    });
  });

  group('Coverage check', () {
    CoverageCell c(double lat, double lon, int pings, int heard) => CoverageCell(lat: lat, lon: lon, pings: pings, heard: heard, bestSnr: 6, medianSnr: 3, repeaters: 2, lastAt: '2026-10-30T12:00:00Z');

    testWidgets('answers from cached measured cells: covered, dead and unmeasured, with no network call of its own', (tester) async {
      phone(tester, h: 4500);
      final h = Harness();
      h.client.publicCoverageResult = PublicCoverage(
        asOf: '2026-10-31T00:00:00Z',
        grid: const CoverageGrid.h3(res: 9, cellDeg: 0.002),
        cells: [c(40.126, -82.93, 10, 9), c(40.2, -82.93, 6, 0)],
      );
      await open(tester, h, const CoverageCheckScreen(initialPoint: LatLng(40.126, -82.93)));
      expect(tester.widget<Text>(find.byKey(const Key('check-verdict'))).data, 'Covered');
      await tester.enterText(find.byKey(const Key('check-point-field')), '40.2, -82.93');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('check-verdict'))).data, 'Driven, nothing heard');
      await tester.enterText(find.byKey(const Key('check-point-field')), '41.5, -80.1');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('check-verdict'))).data, 'Not measured');
      await drain(tester);
    });
  });

  group('small screens and big text', () {
    final screens = <String, Widget Function()>{
      'airtime': () => AirtimeScreen(store: PlanStore(), client: () => MockClient((r) async => _json({'error': 'x'}, 503))),
      'baseline': () => const Scaffold(body: SizedBox()),
      'presets': () => const PresetsScreen(),
      'link': () => LinkScreen(store: PlanStore(), client: () => MockClient((r) async => _json(_score())), initialA: const LatLng(39.96, -82.99), initialB: const LatLng(40.0, -82.93)),
      'painter': () => PainterScreen(store: PlanStore(), client: () => MockClient((r) async => _json({'error': 'x'}, 400)), initialPoint: const LatLng(40.1, -82.9)),
      'check': () => const CoverageCheckScreen(initialPoint: LatLng(40.1, -82.9)),
    };
    for (final e in screens.entries) {
      testWidgets('${e.key}: 320 dp wide at 2x text draws without overflow', (tester) async {
        phone(tester, w: 320, h: 4500, scale: 2.0);
        final h = Harness();
        await open(tester, h, e.value());
        final ex = tester.takeException();
        expect(ex == null ? null : ex.toString() + (ex is FlutterError ? ex.diagnostics.map((d) => d.toString()).join('\n') : ''), isNull);
        await drain(tester);
      });
    }
  });
}
