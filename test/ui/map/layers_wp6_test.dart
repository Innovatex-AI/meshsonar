// Drive WP6 (plan 7.3): every F-item has a test here or in the file named in its comment, plus layer-sheet rows, persistence
// across a relaunch and the guide rows.
import 'repeater_probe.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/coverage_timeline.dart';
import 'package:meshsonar/core/hex_cells.dart' show HexCell, HexPoint;
import 'package:meshsonar/core/map_links.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/repeater_reach.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/coverage_layer_controls.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/coverage_timeline_slider.dart';
import 'package:meshsonar/ui/map/layers/layers_sheet.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/legend_sheet.dart';
import 'package:meshsonar/ui/map/map_layers.dart';

import '../fakes.dart';

String? _file;
MapPrefs _openPrefs() => MapPrefs(read: () async => _file, write: (s) async => _file = s);

const _site = SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'cellLinks', 'reachDriverKey'});

class _KeylessClient extends FakeCmatClient {
  _KeylessClient(super.u);
  final reachKeys = <String>[];
  final cellKeys = <String>[];
  @override
  Future<RepeaterReach> repeaterReach(String driverKey, String repeaterKey, {double? lat, double? lon, bool h3 = false}) async {
    reachKeys.add(driverKey);
    return RepeaterReach(key: repeaterKey, cellDeg: 0.0025, cells: const [], totals: const ReachTotals(heardPings: 0, drives: 0, drivers: 0), snrByDistance: const []);
  }

  @override
  Future<CellLinks> cellLinks(String driverKey, String h3) async {
    cellKeys.add(driverKey);
    return CellLinks.parse({'h3': h3, 'res': 9, 'links': <Object>[], 'asOf': '2026-11-02T00:00:00Z'});
  }
}

class _KeylessHarness extends Harness {
  @override
  FakeCmatClient newClient(Uri u) => _KeylessClient(u)..siteConfigResult = _site;
}

HexCell hexCell({required int heard, double? best}) => HexCell(
  id: 'a',
  boundary: const [HexPoint(0, 0), HexPoint(0, 1), HexPoint(1, 1)],
  sent: 3,
  heard: heard,
  bestSnrDb: best,
);

void main() {
  setUp(() => _file = null);

  group('F3 hexagon colours follow the Pings mode', () {
    test('By SNR: best SNR gradient, purple-free grey when nothing heard; Heard: green / grey', () {
      for (final mc in [MeshSonarColors.light, MeshSonarColors.dark]) {
        expect(hexColor(mc, hexCell(heard: 2, best: 8), PingColorMode.snr), mc.forPing(heard: true, snr: 8));
        expect(hexColor(mc, hexCell(heard: 0), PingColorMode.snr), mc.silent);
        expect(hexColor(mc, hexCell(heard: 2, best: 8), PingColorMode.result), mc.snrStrong);
        expect(hexColor(mc, hexCell(heard: 2, best: -9), PingColorMode.result), mc.snrStrong, reason: 'any ping heard = green');
        expect(hexColor(mc, hexCell(heard: 0), PingColorMode.result), mc.silent);
      }
    });
  });

  group('F11 persistence across a relaunch', () {
    testWidgets('switches, Pings mode, Repeaters scope, window and source come back; Reset forgets; the filter does not persist', (t) async {
      final h = Harness();
      await h.state.init();
      final prefs = _openPrefs();
      final a = DriveMapModel(h.state, prefs: prefs);
      expect(a.layerState, kDefaultLayerState);
      a.setLayer('measured', false);
      a.setLayer('network', true);
      a.setLayer('predicted', false);
      a.pingColors = PingColorMode.result;
      a.coverageQuery = const CoverageQuery(res: 10, since: CoverageSince.week, source: CoverageSource.meshsonar);
      a.timeline.scrubTo(0); // not a layer: never remembered
      await t.pump(const Duration(milliseconds: 1));
      a.dispose();

      // "Relaunch": a new prefs instance reading the same file, a new model.
      final prefs2 = _openPrefs();
      await prefs2.load();
      final b = DriveMapModel(h.state, prefs: prefs2);
      addTearDown(b.dispose);
      expect(b.layerState.isOn('measured'), isFalse);
      expect(b.layerState.isOn('network'), isTrue);
      expect(b.layerState.isOn('predicted'), isFalse);
      expect(b.layerState.isOn('pings'), isTrue, reason: 'untouched layers keep their default');
      expect(b.pingColors, PingColorMode.result);
      expect(b.coverageQuery.res, isNull, reason: 'the detail chips are gone: a pinned resolution is never remembered (D1)');
      expect(b.coverageQuery.since, CoverageSince.week);
      expect(b.coverageQuery.source, CoverageSource.meshsonar);
      expect(b.coverageQuery.until, isNull, reason: 'the timeline is always Live on launch');

      b.resetLayers();
      expect(b.layerState, kDefaultLayerState);
      expect(b.coverageQuery.res, isNull);
      expect(b.coverageQuery.since, CoverageSince.all);
      expect(b.coverageQuery.source, CoverageSource.all);
      final prefs3 = _openPrefs();
      await prefs3.load();
      expect(prefs3.layerPrefs(kDriveLayerPage), LayerPrefs.empty);
    });

    testWidgets('repeater names: the old Settings key is the fallback until chosen; the choice then lives in LayerPrefs', (t) async {
      final h = Harness();
      await h.state.init();
      await h.state.updateSettings(h.state.settings.copyWith(mapRepeaterLabels: false));
      final m = DriveMapModel(h.state, prefs: _openPrefs());
      addTearDown(m.dispose);
      expect(m.layerState.isOn('labels'), isFalse);
      m.setLayer('labels', true);
      final p = _openPrefs();
      await p.load();
      expect(p.layerPrefs(kDriveLayerPage).toggles['labels'], isTrue);
    });
  });

  group('F2 / F9 on the map (F4 range rings were removed with the coverage redesign)', () {
    const a = RepeaterRef(key: 'aaaa1111', name: 'Alpha', lat: 40.01, lon: -83.0);
    const b = RepeaterRef(key: 'bbbb2222', name: 'Bravo', lat: 40.02, lon: -83.0);
    final heardA = HeardView(id: 'aa', label: 'Alpha', ref: a, snrDb: 4);

    Future<void> pumpMap(WidgetTester t, {required MapLayerState layers, List<HeardView>? heard, LatLng? position, List<DrivePing> pings = const []}) async {
      t.view.physicalSize = const Size(800, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: Scaffold(
            body: CoverageMap(pings: pings, repeaters: const [a, b], heard: heard, position: position, layerState: layers, showTiles: false),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 100));
    }

    testWidgets('F2: "Heard this drive" draws only the repeaters this drive heard; off draws none', (t) async {
      await pumpMap(t, layers: kDefaultLayerState, heard: [heardA], position: const LatLng(40.0, -83.0));
      expect(repeaterItem(t, 'aaaa1111'), isNotNull);
      expect(repeaterItem(t, 'bbbb2222'), isNull, reason: 'known but not heard: not on this layer');
      await pumpMap(t, layers: kDefaultLayerState.toggle('heard', false), heard: [heardA], position: const LatLng(40.0, -83.0));
      expect(repeaterItem(t, 'aaaa1111'), isNull);
    });

    testWidgets('F9: the Lines switch gates the lines drawn after a tap', (t) async {
      final ping = DrivePing(id: 'p1', ts: DateTime.utc(2026, 10, 31, 14), lat: 40.0, lon: -83.0, echoes: const [Echo(repeater: 'aaaa', snrDb: 4.5)]);
      await pumpMap(t, layers: kDefaultLayerState, pings: [ping], position: const LatLng(40.0, -83.0));
      await t.tap(find.byKey(const ValueKey('map-ping-tap-p1')));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('link-lines')), findsOneWidget, reason: 'Lines on: the tap draws them');
      await pumpMap(t, layers: kDefaultLayerState.toggle('links', false), pings: [ping], position: const LatLng(40.0, -83.0));
      await t.tap(find.byKey(const ValueKey('map-ping-tap-p1')));
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const Key('link-lines')), findsNothing, reason: 'Lines off: no lines after a tap either');
    });
  });

  group('F8 no driver key needed for tap-a-cell and tap-a-repeater lines', () {
    test('reach and cell links are enabled by the server capability alone and send no key', () async {
      final h = _KeylessHarness();
      await h.state.init();
      await h.state.refreshUploadSiteConfig(force: true);
      expect(h.state.keyApproved, isFalse);
      expect(h.state.reachEnabled, isTrue);
      expect(h.state.cellLinksEnabled, isTrue);
      await h.state.repeaterReach('aa' * 32);
      await h.state.cellLinks('892a9084b23ffff');
      final c = h.client as _KeylessClient;
      expect(c.reachKeys, ['']);
      expect(c.cellKeys, ['']);
    });
  });

  group('F10 timeline copy', () {
    Future<DriveMapModel> pump(WidgetTester t, RegionTimeline? Function() tl) async {
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(h.state, prefs: _openPrefs());
      addTearDown(model.dispose);
      model.timelineFetcher = (_) async => tl();
      await t.pumpWidget(MaterialApp(home: Scaffold(body: CoverageTimelineSlider(model: model))));
      await t.pump();
      await t.pump();
      return model;
    }

    testWidgets('an empty region says no growth history yet, not "could not be loaded"', (t) async {
      await pump(t, () => const RegionTimeline([]));
      expect(find.byKey(const Key('timeline-empty')), findsOneWidget);
      expect(find.textContaining('No growth history yet for'), findsOneWidget);
      expect(find.byKey(const Key('timeline-unavailable')), findsNothing);
    });

    testWidgets('one day of data says so', (t) async {
      // The harness clock is 2026-10-16: the first data day is today, one step.
      await pump(t, () => RegionTimeline([TimelineDay(DateTime.utc(2026, 10, 16), 4, 4)]));
      expect(find.text('Only one day of data so far'), findsOneWidget);
      expect(find.byKey(const Key('timeline-unavailable')), findsNothing);
    });

    testWidgets('a failed request is the only case that says it could not be loaded', (t) async {
      await pump(t, () => null);
      expect(find.byKey(const Key('timeline-unavailable')), findsOneWidget);
      expect(find.textContaining("Couldn't load the timeline"), findsOneWidget);
    });
  });

  group('the layers sheet', () {
    Future<DriveMapModel> openSheet(WidgetTester t, {Harness? harness}) async {
      t.view.physicalSize = const Size(800, 4200);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final h = harness ?? Harness();
      await h.state.init();
      final model = DriveMapModel(h.state, prefs: _openPrefs());
      addTearDown(model.dispose);
      await t.pumpWidget(
        AppScope(
          state: h.state,
          child: MaterialApp(
            theme: meshSonarTheme(Brightness.light),
            home: Scaffold(body: MapLayersSheet(model: model)),
          ),
        ),
      );
      await t.pumpAndSettle();
      return model;
    }

    testWidgets('sections in order: Base map, Coverage, Network; the plan section 5 rows; no rings, no neighbours', (t) async {
      await openSheet(t);
      final ys = [
        for (final g in ['base', 'coverage', 'network']) t.getTopLeft(find.byKey(Key('layers-group-$g'), skipOffstage: false)).dy,
      ];
      expect([...ys]..sort(), ys);
      final rows = ['layer-network-coverage', 'layer-predicted', 'layer-hexes', 'layer-pings', 'layer-region-repeaters', 'layer-labels', 'layer-observers', 'layer-links'];
      final rowY = [for (final id in rows) t.getTopLeft(find.byKey(Key(id), skipOffstage: false)).dy];
      expect([...rowY]..sort(), rowY, reason: 'Measured, Predicted, This drive, Ping dots, Repeaters, Names, Observers, Lines');
      for (final id in ['layer-rings', 'layer-neighbours', 'layer-network', 'layer-repeaters']) {
        expect(find.byKey(Key(id), skipOffstage: false), findsNothing, reason: '$id is not a row of its own');
      }
      for (final text in ['Measured coverage', 'Predicted coverage', 'This drive', 'Ping dots', 'Repeaters', 'Names', 'Observers', 'Lines to repeaters']) {
        expect(find.text(text), findsWidgets, reason: text);
      }
      expect(find.text('Colour by'), findsNothing);
      expect(find.textContaining('Range rings'), findsNothing);
    });

    testWidgets('F7: Measured coverage says whose coverage it is; Predicted says it is not on an old server', (t) async {
      await openSheet(t);
      expect(find.text("Everyone's drives: the average signal in each cell."), findsOneWidget);
      // Predicted and Heard (no ping, Nov 9) both say so: the fake server has neither coverageV2 nor coverageHeard.
      expect(find.text('Not available on this server yet'), findsNWidgets(2), reason: 'the fake server has no coverageV2');
      expect(t.widget<Switch>(find.byKey(const Key('layer-predicted'))).onChanged, isNull);
      expect(t.widget<Switch>(find.byKey(const Key('layer-heardcells'))).onChanged, isNull, reason: 'Heard needs coverageHeard');
    });

    testWidgets('Repeaters: one switch with a This region / All MeshCore scope; Names is under it', (t) async {
      final m = await openSheet(t);
      expect(t.widget<Switch>(find.byKey(const Key('layer-region-repeaters'))).value, isTrue);
      expect(m.repeatersAll, isFalse);
      await t.tap(find.byKey(const Key('layer-scope-all')));
      await t.pumpAndSettle();
      expect(m.layerState.isOn('network'), isTrue);
      expect(m.layerState.isOn('repeaters'), isFalse);
      expect(t.widget<Switch>(find.byKey(const Key('layer-region-repeaters'))).value, isTrue, reason: 'still on, other scope');
      await t.tap(find.byKey(const Key('layer-region-repeaters')));
      await t.pumpAndSettle();
      expect(repeatersOn(m.layerState), isFalse);
      expect(t.widget<Switch>(find.byKey(const Key('layer-labels'))).onChanged, isNull, reason: 'Names needs Repeaters on');
    });

    testWidgets('inline keys sit under the rows and follow the Pings mode', (t) async {
      final m = await openSheet(t);
      expect(find.byKey(const Key('layer-pings-key')), findsOneWidget);
      expect(find.byKey(const Key('layer-hexes-key')), findsOneWidget);
      expect(find.text('no reading'), findsWidgets, reason: 'purple row in the SNR key');
      await t.tap(find.byKey(const Key('layer-color-result')));
      await t.pumpAndSettle();
      expect(m.pingColors, PingColorMode.result);
      expect(find.text('not heard'), findsWidgets);
    });

    testWidgets('Coverage options is a page inside the sheet: window, growth slider, source, back; no colour by or detail', (t) async {
      final m = await openSheet(t);
      await t.ensureVisible(find.byKey(const Key('layer-measured-options')));
      await t.tap(find.byKey(const Key('layer-measured-options')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('layers-options-page')), findsOneWidget);
      expect(find.byType(CoverageOptionsBody), findsOneWidget);
      expect(find.byKey(const Key('cov-color-Share heard')), findsNothing);
      expect(find.byKey(const Key('cov-res-Auto')), findsNothing);
      await t.tap(find.byKey(const Key('cov-since-7 d')));
      await t.pump();
      expect(m.coverageQuery.since, CoverageSince.week);
      await t.tap(find.byKey(const Key('layers-options-back')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('layers-options-page')), findsNothing);
      expect(find.textContaining('Window 7 d'), findsOneWidget);
    });

    testWidgets('Reset asks first, then restores the defaults', (t) async {
      final m = await openSheet(t);
      m.setLayer('observers', true);
      await t.pumpAndSettle();
      await t.ensureVisible(find.byKey(const Key('layers-reset')));
      await t.tap(find.byKey(const Key('layers-reset')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('layers-reset-confirm')), findsOneWidget);
      expect(m.layerState.isOn('observers'), isTrue, reason: 'nothing changed before the confirmation');
      await t.tap(find.byKey(const Key('layers-reset-confirm')));
      await t.pumpAndSettle();
      expect(m.layerState, kDefaultLayerState);
    });

    testWidgets('the base map picker replaces the cycler: four tiles, a tap selects', (t) async {
      final m = await openSheet(t);
      for (final id in ['chart', 'street', 'dark', 'topo']) {
        expect(find.byKey(Key('base-map-$id')), findsOneWidget);
      }
      expect(find.text('needs signal'), findsOneWidget);
      await t.tap(find.byKey(const Key('base-map-dark')));
      await t.pumpAndSettle();
      expect(m.baseStyle.id, 'dark');
    });
  });

  group('the guide', () {
    Future<void> pumpGuide(WidgetTester t, {PingColorMode ping = PingColorMode.snr, bool v2 = false}) async {
      t.view.physicalSize = const Size(420, 5000);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: Scaffold(body: MapLegendSheet(key: ValueKey('${ping.name}$v2'), pingColors: ping, coverageV2: v2)),
      ));
      await t.pumpAndSettle();
    }

    testWidgets('F3/6.3: Your coverage hexagons, the three repeater states and the green tick are explained; no "amber tower" claim', (t) async {
      await pumpGuide(t);
      expect(find.text('Map guide'), findsOneWidget);
      expect(find.byKey(const Key('legend-section-yours')), findsOneWidget);
      expect(find.byKey(const Key('legend-row-yours-strong')), findsOneWidget);
      await pumpGuide(t, ping: PingColorMode.result);
      expect(find.byKey(const Key('legend-row-yours-heard')), findsOneWidget);
      for (final id in ['repeater-fresh', 'repeater-recent', 'repeater-older', 'repeater-heard']) {
        expect(find.byKey(Key('legend-row-$id')), findsOneWidget, reason: id);
      }
      expect(find.textContaining('Amber tower'), findsNothing);
    });

    testWidgets('F1: the old best-SNR key keeps the purple "heard, signal unknown" and the grey rows', (t) async {
      await pumpGuide(t);
      expect(find.byKey(const Key('legend-row-cell-unknown')), findsOneWidget);
      expect(find.byKey(const Key('legend-row-cell-none')), findsOneWidget);
      expect(find.byKey(const Key('legend-colour-by-heard')), findsNothing, reason: 'no colour-by modes (D9)');
    });

    testWidgets('coverage v2: five bands with dB ranges, No reply, Heard no direct signal, Faint, hatched Predicted', (t) async {
      await pumpGuide(t, v2: true);
      expect(find.text('Measured coverage'), findsOneWidget);
      expect(find.text('Predicted coverage'), findsWidgets);
      for (final id in ['cell-band-5', 'cell-band-4', 'cell-band-3', 'cell-band-2', 'cell-band-1', 'cell-band-0', 'cell-band-6', 'cell-faded', 'predicted-sample', 'predicted-none']) {
        expect(find.byKey(Key('legend-row-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Excellent, above +7.5 dB'), findsOneWidget);
      expect(find.text('Fair, \u22122.5 to +2.5 dB'), findsOneWidget);
      expect(find.text('Edge, below \u22127.5 dB'), findsOneWidget);
      expect(find.text('Faint = under 3 pings'), findsOneWidget);
    });
  });
}
