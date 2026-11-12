// M3-2 on screen and in the model (plan unified-map-system §8b): Estimated positions, Redundancy and Links by SNR, from the Map Definition
// and the two region answers; the basemap picker and cycler gated by the definition's capabilities; the legend entries; and a definition
// from before M3 that offers none of it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/m3_data.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/layers_sheet.dart';
import 'package:meshsonar/ui/map/layers/m3_layers.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart' show RepeaterFreshness;
import 'package:meshsonar/ui/map/legend_card.dart';

import '../../support/huge_screen.dart';
import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
String k(String c) => c * 64;

final _body = File('assets/map/map-definition.json').readAsStringSync();

/// The definition an app had before M3: no capabilities, no new layers, no Topo / Satellite.
MapDefinition oldDefinition() {
  final j = jsonDecode(_body) as Map<String, dynamic>;
  j
    ..remove('schemaMinor')
    ..remove('capabilities');
  j['basemaps'] = [for (final b in j['basemaps'] as List) if (const {'road', 'relief', 'plain'}.contains((b as Map)['id'])) b];
  j['layers'] = [for (final l in j['layers'] as List) if (!const {'redundancy', 'snrlinks', 'estimated'}.contains((l as Map)['id'])) l];
  j['version'] = 'old-1';
  return MapDefinition.parse(jsonEncode(j));
}

final _nodes = [
  [k('a'), 'Alpha', 'repeater', 39.96, -83.0],
  [k('b'), 'Bravo', 'repeater', 40.0, -83.1],
  [k('c'), 'Charlie', 'room', 40.1, -82.9],
  [k('d'), 'Delta', 'repeater', null, null],
];

LinkGraph graph() => LinkGraph.fromJson({
  'nodes': _nodes,
  'links': [
    [0, 1, 'measured', null, 6.0, null, null, 40, null, null, null, 8.0],
    [1, 2, 'observed', null, null, null, null, 300, null, null, null, null],
  ],
  'drive': [
    [0, '8a2a1072b59ffff'.substring(0, 15), 3, 1.0],
    [1, '8a2a1072b59ffff'.substring(0, 15), 3, 1.0],
    [2, '8a2a1072b5affff'.substring(0, 15), 3, 1.0],
  ],
  'driveUnresolved': 2,
})!;

final estimates = EstimatesAnswer.fromJson({
  'builtAt': '2026-11-12T10:00:00Z',
  'estimates': [
    {'key': k('d'), 'name': 'Delta', 'role': 'repeater', 'lat': 40.01, 'lon': -83.02, 'confidence': 'high', 'anchors': 3, 'spreadKm': 4.0},
    {'key': k('e'), 'name': 'Echo', 'role': 'room', 'lat': 40.2, 'lon': -83.2, 'confidence': 'low', 'anchors': 1, 'spreadKm': null},
    {'key': k('f'), 'name': 'Foxtrot', 'role': 'repeater', 'lat': 40.3, 'lon': -83.3, 'confidence': 'medium', 'anchors': 2, 'spreadKm': 12},
  ],
})!;

String? _file;
MapPrefs _openPrefs() => MapPrefs(read: () async => _file, write: (s) async => _file = s);

RegionRepeaters roster(List<RegionRepeater> rows) =>
    RegionRepeaters(regionSlug: 'cmh', status: const RosterStatus(state: 'ready'), rows: rows, counts: const {});

void main() {
  setUp(() {
    _file = null;
    ActiveMapDefinition.debugSet();
  });
  tearDown(() => ActiveMapDefinition.debugSet());

  group('the model asks for the M3 data only when it needs it', () {
    Future<(Harness, DriveMapModel, List<String>)> make({List<RegionRepeater> rows = const [], bool clear = true}) async {
      final h = Harness();
      h.client.regionsIndexResult = const [cmh];
      await h.state.init();
      await h.state.updateSettings(h.state.settings.copyWith(regionManual: 'CMH'));
      expect(h.state.viewingRegion?.slug, 'cmh');
      final calls = <String>[];
      final m = DriveMapModel(
        h.state,
        prefs: _openPrefs(),
        estimates: (u, s) async {
          calls.add('estimates $s');
          return estimates;
        },
        linkGraph: (u, s, {required allSources, required drive}) async {
          calls.add('graph all=$allSources drive=$drive');
          return graph();
        },
        roster: (u, s) async {
          calls.add('roster $s');
          return roster(rows);
        },
      );
      // The model asks for what its default-on layers need as soon as it is built (the region is known): let that land.
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      if (clear) calls.clear();
      return (h, m, calls);
    }

    test('Estimated positions are on by default: asked once for the viewed region as soon as it is known; Redundancy and Links by SNR (off) are not asked', () async {
      final (_, m, calls) = await make(clear: false);
      addTearDown(m.dispose);
      expect(m.layerState.isOn('estimated'), isTrue);
      expect(m.layerState.isOn('redundancy'), isFalse);
      expect(m.layerState.isOn('snrlinks'), isFalse);
      expect(calls, containsAll(['estimates cmh', 'roster cmh']));
      expect(calls.where((c) => c.startsWith('graph')), isEmpty);
      m.loadM3Data();
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((c) => c == 'estimates cmh'), hasLength(1), reason: 'not again while it is ready');
      expect(m.estimatesToShow.map((e) => e.key), [k('d'), k('e'), k('f')]);
      expect(m.statusOf('estimated').availability, LayerAvailability.ready);
      expect(m.statusOf('estimated').detail, '3 repeaters with no GPS, placed from neighbours');
    });

    test('an estimate whose repeater has a position in the roster since is not drawn; freshness comes from the roster status', () async {
      final (_, m, _) = await make(rows: [
        RegionRepeater(key: k('d'), hashPrefix: 'dd', lat: 40.5, lon: -83.5, status: RepeaterActivity.active),
        RegionRepeater(key: k('e'), hashPrefix: 'ee', status: RepeaterActivity.quiet),
      ]);
      addTearDown(m.dispose);
      expect(m.estimatesToShow.map((e) => e.key), [k('e'), k('f')]);
      expect(m.freshnessOfEstimate(k('e')), RepeaterFreshness.recent);
      expect(m.freshnessOfEstimate(k('f')), RepeaterFreshness.stale, reason: 'not in the roster: stale, the faded symbol');
    });

    test('layer off: nothing is asked and nothing is shown', () async {
      final (_, m, calls) = await make();
      addTearDown(m.dispose);
      m.setLayer('estimated', false);
      m.loadM3Data(force: true);
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(m.estimatesToShow, isEmpty);
    });

    test('a definition from before M3 (no capability): the layers are not offered, no request is made', () async {
      final (_, m, calls) = await make();
      addTearDown(m.dispose);
      ActiveMapDefinition.debugSet(oldDefinition());
      expect(m.layerOffered('estimated'), isFalse);
      expect(m.layerOffered('redundancy'), isFalse);
      m.setLayer('estimated', true);
      m.setLayer('snrlinks', true);
      m.loadM3Data();
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(m.estimatesToShow, isEmpty);
      expect(m.snrLinesToShow, isEmpty);
      expect([for (final (_, rs) in sheetRows()) for (final r in rs) r.id], isNot(anyOf(contains('estimated'), contains('redundancy'), contains('snrlinks'))));
    });

    test('Links by SNR reads every source; Redundancy alone reads only the measured links plus the drive rows; both on = ONE request', () async {
      final (_, m, calls) = await make();
      addTearDown(m.dispose);
      m.setLayer('estimated', false);
      m.setLayer('redundancy', true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['graph all=false drive=true']);
      expect(m.redundancy!.cells.map((c) => c.n), [2, 1]);
      expect(m.redundancy!.unresolved, 2);
      expect(m.redundancy, same(m.redundancy), reason: 'memoised: the map keys its drawn picture on it');
      expect(m.statusOf('redundancy').detail, contains('2 repeater ids could not be matched to one repeater and are not counted'));
      calls.clear();
      m.setLayer('snrlinks', true);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(calls, ['graph all=true drive=true'], reason: 'what Redundancy needs is kept in the request');
      expect(m.snrLinesToShow, hasLength(2));
      expect(m.snrLinesToShow, same(m.snrLinesToShow));
      expect(m.redundancy, isNotNull, reason: 'switching the second layer on did not drop the first one\'s data');
      expect(m.statusOf('snrlinks').detail, '2 links between located repeaters');
    });

    test('a failed answer says so with Retry, and nothing is drawn', () async {
      final (_, m, _) = await make();
      addTearDown(m.dispose);
      m.estimatesFetcher = (u, s) async => throw const RegionRepeatersException('down');
      await m.loadEstimates(force: true);
      expect(m.estimatesToShow, isNotEmpty, reason: 'the copy it already had stays (stale), it is not wiped by one failed refresh');
      expect(m.statusOf('estimated').availability, LayerAvailability.stale);
      expect(m.statusOf('estimated').canRetry, isTrue);
    });

    test('nothing loaded yet and the answer fails: failed with Retry, nothing drawn', () async {
      final h = Harness();
      h.client.regionsIndexResult = const [cmh];
      await h.state.init();
      await h.state.updateSettings(h.state.settings.copyWith(regionManual: 'CMH'));
      final m = DriveMapModel(
        h.state,
        prefs: _openPrefs(),
        estimates: (u, s) async => throw const RegionRepeatersException('down'),
        roster: (u, s) async => roster(const []),
      );
      addTearDown(m.dispose);
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(m.estimatesToShow, isEmpty);
      final st = m.statusOf('estimated');
      expect(st.availability, LayerAvailability.failed);
      expect(st.canRetry, isTrue);
    });

    test('Redundancy hides while a time window looks at the past', () async {
      final (_, m, _) = await make();
      addTearDown(m.dispose);
      m.setLayer('redundancy', true);
      await m.loadLinkGraph();
      expect(m.redundancy, isNotNull);
      m.coverageQuery = const CoverageQuery(since: CoverageSince.week);
      expect(m.redundancy, isNull);
      expect(m.statusOf('redundancy').detail, contains('Hidden while looking back'));
    });
  });

  group('the markers and lines on the map', () {
    Future<void> map(WidgetTester t, {List<RepeaterEstimate> est = const [], MapLayerState? layers, List<RedundancyCell> red = const [], List<SnrLink> links = const [], Brightness b = Brightness.light}) async {
      t.view.physicalSize = const Size(500, 500);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(b),
        home: Scaffold(
          body: CoverageMap(
            pings: const [],
            showTiles: false,
            fallbackCenter: const LatLng(40.1, -83.1),
            layerState: layers ?? kDefaultLayerState,
            estimates: est,
            estimateFreshness: (key) => RepeaterFreshness.fresh,
            redundancyCells: red,
            snrLinks: links,
          ),
        ),
      ));
      await t.pump();
    }

    testWidgets('estimated markers: at the position given, paler the less sure (the definition\'s .8 / .6 / .4)', (t) async {
      await map(t, est: estimates.estimates);
      expect(find.byKey(Key('map-estimated-${k('d')}-high')), findsOneWidget);
      expect(find.byKey(Key('map-estimated-${k('e')}-low')), findsOneWidget);
      expect(find.byKey(Key('map-estimated-${k('f')}-medium')), findsOneWidget);
      double opacity(String key, String conf) => t.widget<Opacity>(find.byKey(Key('map-estimated-$key-$conf'))).opacity;
      expect(opacity(k('d'), 'high'), 0.8);
      expect(opacity(k('f'), 'medium'), 0.6);
      expect(opacity(k('e'), 'low'), 0.4);
      expect(opacity(k('e'), 'low'), lessThan(opacity(k('d'), 'high')));
      final layer = t.widget<MarkerLayer>(find.descendant(of: find.byKey(const Key('estimated-layer')), matching: find.byType(MarkerLayer)));
      expect([for (final m in layer.markers) (m.point.latitude, m.point.longitude)], [(40.01, -83.02), (40.2, -83.2), (40.3, -83.3)], reason: 'positions are used as given');
    });

    testWidgets('layer off: no estimated marker; nothing from the server: none either (never invented)', (t) async {
      await map(t, est: estimates.estimates, layers: kDefaultLayerState.toggle('estimated', false));
      expect(find.byKey(const Key('estimated-layer')), findsNothing);
      await map(t, est: const []);
      expect(find.byKey(const Key('estimated-layer')), findsNothing);
    });

    testWidgets('a tap on an estimated marker says it is an estimate, approximate, and how sure', (t) async {
      await map(t, est: estimates.estimates);
      await t.tap(find.byKey(Key('map-estimated-${k('e')}')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('estimated-sheet')), findsOneWidget);
      expect(find.text('Echo'), findsOneWidget);
      expect(find.text('Estimated position, approximate'), findsOneWidget);
      expect(find.textContaining('has not shared a position'), findsOneWidget);
      expect(find.textContaining('1 located neighbour'), findsOneWidget);
    });

    testWidgets('Links by SNR: palette band colour with a casing, the dashed neutral line for a pair seen only relaying; Redundancy cells draw', (t) async {
      final d = MapDefinition.parse(_body);
      final links = snrLinks(graph(), d);
      await map(t, links: links, red: redundancyCells(graph()).cells, layers: kDefaultLayerState.toggle('snrlinks', true).toggle('redundancy', true));
      expect(find.byKey(const Key('snr-links-case-layer')), findsOneWidget);
      final lines = t.widget<PolylineLayer>(find.byKey(const Key('snr-links-layer')));
      expect(lines.polylines, hasLength(1), reason: 'the measured pair');
      final sig = d.signal('standard', dark: false);
      expect(lines.polylines.single.color.toARGB32() & 0xFFFFFF, sig.bands[4] & 0xFFFFFF, reason: 'the palette\'s Good colour, not an invented one');
      final none = t.widget<PolylineLayer>(find.byKey(const Key('snr-links-none-layer')));
      expect(none.polylines, hasLength(1));
      expect(none.polylines.single.pattern, isNot(const StrokePattern.solid()), reason: 'dashed');
      expect(find.byKey(const Key('redundancy-layer')), findsOneWidget);
    });

    testWidgets('Links by SNR / Redundancy switched off draw nothing', (t) async {
      final d = MapDefinition.parse(_body);
      await map(t, links: snrLinks(graph(), d), red: redundancyCells(graph()).cells);
      expect(find.byKey(const Key('snr-links-layer')), findsNothing);
      expect(find.byKey(const Key('redundancy-layer')), findsNothing);
    });
  });

  group('Redundancy and Links by SNR colours are the definition\'s', () {
    test('redundancy steps 1..4 are symbols.redundancy.colours in both themes; opacity .72', () {
      final d = MapDefinition.parse(_body);
      final c = d.symbol('redundancy')['colours'] as Map;
      for (final dark in [false, true]) {
        final hex = (c[dark ? 'dark' : 'light'] as List).cast<String>();
        for (var s = 1; s <= 4; s++) {
          expect(redundancyColour(d, s, dark: dark).toARGB32(), parseHexColour(hex[s - 1]));
        }
      }
      final st = SnrLinkStyle.of(d, dark: true);
      expect(st.opacity, 0.85);
      expect(st.casingOpacity, 0.6);
      expect(st.noSnr.toARGB32(), parseHexColour('#9CA3AF'));
    });
  });

  group('the Layers sheet and the legend', () {
    Future<DriveMapModel> openSheet(WidgetTester t) async {
      useHugeScreen(t);
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(
        h.state,
        prefs: _openPrefs(),
        estimates: (u, s) async => estimates,
        linkGraph: (u, s, {required allSources, required drive}) async => graph(),
        roster: (u, s) async => roster(const []),
      );
      addTearDown(model.dispose);
      await t.pumpWidget(AppScope(state: h.state, child: MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: MapLayersSheet(model: model)))));
      await t.pumpAndSettle();
      return model;
    }

    testWidgets('the new layers are rows with the definition\'s names, and their keys read the definition\'s labels', (t) async {
      final m = await openSheet(t);
      final d = MapDefinition.parse(_body);
      for (final id in ['redundancy', 'snrlinks', 'estimated']) {
        expect(find.byKey(Key('layer-$id'), skipOffstage: false), findsOneWidget, reason: id);
      }
      m.setLayer('redundancy', true); // a layer's key shows while it is on (off shows the definition's hint)
      m.setLayer('snrlinks', true);
      await t.pumpAndSettle();
      expect(find.text('Redundancy'), findsOneWidget);
      expect(find.text('Links by SNR'), findsOneWidget);
      expect(find.text('Estimated positions'), findsOneWidget);
      // Inline keys: identical labels to the web legend (the definition's).
      for (final l in d.layerDef('redundancy')!.legend) {
        expect(find.text(l.label!, skipOffstage: false), findsWidgets, reason: l.label);
      }
      for (final l in d.layerDef('estimated')!.legend) {
        expect(find.text(l.label!, skipOffstage: false), findsWidgets, reason: l.label);
      }
      expect(find.text('Seen relaying, no SNR (width = packets)', skipOffstage: false), findsWidgets);
    });

    testWidgets('a definition from before M3: no new rows, and only Chart / Light / Dark in the base map picker', (t) async {
      ActiveMapDefinition.debugSet(oldDefinition());
      await openSheet(t);
      for (final id in ['redundancy', 'snrlinks', 'estimated']) {
        expect(find.byKey(Key('layer-$id'), skipOffstage: false), findsNothing, reason: id);
      }
      for (final id in ['chart', 'street', 'dark']) {
        expect(find.byKey(Key('base-map-$id')), findsOneWidget);
      }
      expect(find.byKey(const Key('base-map-topo')), findsNothing);
      expect(find.byKey(const Key('base-map-satellite')), findsNothing);
    });

    testWidgets('picking Satellite saves it and the sheet says what the imagery covers; the cycler follows the same list', (t) async {
      final m = await openSheet(t);
      expect(m.availableBaseStyles.map((s) => s.id), ['chart', 'street', 'dark', 'topo', 'satellite']);
      await t.tap(find.byKey(const Key('base-map-satellite')));
      await t.pumpAndSettle();
      expect(m.baseStyle.id, 'satellite');
      expect(find.byKey(const Key('layers-base-map-note')), findsOneWidget);
      expect(find.textContaining('USGS NAIP in the US, Esri World Imagery elsewhere'), findsOneWidget);
    });

    testWidgets('a saved Satellite on a definition that does not offer it is drawn as Chart, and cannot be set', (t) async {
      final m = await openSheet(t);
      await t.tap(find.byKey(const Key('base-map-satellite')));
      await t.pumpAndSettle();
      expect(m.baseStyle.id, 'satellite');
      ActiveMapDefinition.debugSet(oldDefinition());
      await t.pump();
      expect(m.baseStyle.id, 'chart');
      m.setBaseStyle(BaseMapStyle.satellite);
      expect(m.baseStyle.id, 'chart', reason: 'a style the definition does not offer cannot be picked');
    });

    testWidgets('the legend card lists Redundancy steps, the estimated symbols and the SNR bands + neutral dashed line with the definition\'s labels', (t) async {
      t.view.physicalSize = const Size(500, 1200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: Scaffold(body: LegendCard(on: const {'redundancy', 'snrlinks', 'estimated'}, initiallyOpen: true)),
      ));
      await t.pump();
      final d = MapDefinition.parse(_body);
      for (final id in ['redundancy', 'snrlinks', 'estimated']) {
        expect(find.byKey(Key('legend-layer-$id')), findsOneWidget, reason: id);
      }
      for (final id in ['redundancy', 'estimated']) {
        for (final l in d.layerDef(id)!.legend) {
          expect(find.text(l.label!), findsOneWidget, reason: l.label);
        }
      }
      expect(find.text('Seen relaying, no SNR (width = packets)'), findsOneWidget);
      expect(find.textContaining('Link SNR (reported neighbour tables and measured /neighbors reports):'), findsOneWidget);
    });
  });
}
