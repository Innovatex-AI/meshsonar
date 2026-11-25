// MAP slice 4 (app half, build 74): the one Layers sheet reads a MapLayersModel, so any map can open it. DriveMapModel is one;
// PageLayersModel serves the Plan map. Sections, disabled rows with reasons, the Filters count, Road replacing Chart + Light
// when the definition has variables.basemap, and build 73's list when it does not.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_pages.dart';
import 'package:meshsonar/core/map_filter.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/layers/layers_model.dart';
import 'package:meshsonar/ui/map/layers/layers_sheet.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';

import '../../support/huge_screen.dart';
import '../fakes.dart';

MapDefinition _minor7() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());

MapPrefs _prefs() => MapPrefs();

void main() {
  setUp(() => ActiveMapDefinition.debugSet());
  tearDown(() => ActiveMapDefinition.debugSet());

  PageLayersModel pageModel(Harness h, MapPrefs prefs) {
    final feed = StaticRepeaterMapFeed();
    final src = RepeaterMapSource(feed, clock: h.state.services.clock);
    addTearDown(src.dispose);
    final m = PageLayersModel(pageId: kPlanLayerPage, state: h.state, repeaterSource: src, repeaterFeed: feed, mapName: 'the Plan map', alwaysOn: const {kPlanLayerId}, prefs: prefs);
    addTearDown(m.dispose);
    return m;
  }

  group('Road', () {
    test('with variables.basemap Chart and Light are one entry named Road; ids and the other styles are unchanged', () {
      final d = _minor7();
      expect(d.basemapVariableIds, isNotNull);
      final offered = BaseMapStyle.availableFor(d);
      expect(offered.first, BaseMapStyle.chart);
      expect(offered, isNot(contains(BaseMapStyle.street)));
      expect(offered, contains(BaseMapStyle.dark));
      expect(BaseMapStyle.chart.labelIn(d), 'Road');
      expect(BaseMapStyle.dark.labelIn(d), 'Dark');
      expect(BaseMapStyle.chart.id, 'chart');
      expect(BaseMapStyle.street.id, 'street');
      expect(BaseMapStyle.street.look, BaseMapStyle.chart.look, reason: 'same tiles, so cache keys are untouched');
    });

    test('a saved Light (street) draws as Road; the saved value is not rewritten', () {
      final d = _minor7();
      expect(BaseMapStyle.effective(BaseMapStyle.parse('street'), d), BaseMapStyle.chart);
      expect(BaseMapStyle.parse('street'), BaseMapStyle.street);
      expect(BaseMapStyle.effective(BaseMapStyle.dark, d), BaseMapStyle.dark);
    });

    test('without variables.basemap (bundled copy, old server) the list is build 73\'s', () {
      final d = MapDefinition.bundled;
      expect(d.basemapVariableIds, isNull);
      expect(BaseMapStyle.availableFor(d).take(3), [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]);
      expect([for (final s in BaseMapStyle.availableFor(d)) s.labelIn(d)].take(3), ['Chart', 'Light', 'Dark']);
      expect(BaseMapStyle.effective(BaseMapStyle.street, d), BaseMapStyle.street);
    });
  });

  group('PageLayersModel (the Plan map)', () {
    test('the remembered layers of its page, the plan layer always on and never written', () async {
      final h = Harness();
      await h.state.init();
      final prefs = _prefs();
      final m = pageModel(h, prefs);
      expect(m.layerState.isOn(kPlanLayerId), isTrue);
      expect(m.layerState.isOn('measured'), isTrue);
      m.setLayer('measured', false);
      expect(m.layerState.isOn('measured'), isFalse);
      expect(prefs.layerPrefs(kPlanLayerPage).toggles, {'measured': false});
      expect(prefs.layerPrefs(kDriveLayerPage).isEmpty, isTrue, reason: 'the Drive map keeps its own choices');
      m.setLayer(kPlanLayerId, false);
      expect(m.layerState.isOn(kPlanLayerId), isTrue);
      m.resetLayers();
      expect(prefs.layerPrefs(kPlanLayerPage).isEmpty, isTrue);
      expect(m.layerState.isOn('measured'), isTrue);
    });

    test('notifies when its prefs change', () async {
      final h = Harness();
      await h.state.init();
      final prefs = _prefs();
      final m = pageModel(h, prefs);
      var n = 0;
      m.addListener(() => n++);
      m.setLayer('predicted', false);
      expect(n, greaterThan(0));
    });

    test('a layer this map does not draw is unavailable with a one-line reason; the shared ones are not', () async {
      final h = Harness();
      await h.state.init();
      final m = pageModel(h, _prefs());
      for (final id in ['observers', 'phones', 'links', 'estimated', 'redundancy', 'snrlinks', 'borders']) {
        final s = m.statusOf(id);
        expect(s.availability, LayerAvailability.unsupported, reason: id);
        expect(s.detail, 'Not drawn on the Plan map.', reason: id);
      }
      expect(m.statusOf('hexes').detail, 'Your drive is shown on the Drive map.');
      expect(m.statusOf(kRosterLayerId).availability, isNot(LayerAvailability.unsupported));
      expect(m.statusOf(kLabelsLayerId).availability, LayerAvailability.ready);
    });
  });

  group('the sheet on any map', () {
    Future<void> open(WidgetTester t, MapLayersModel model, Harness h) async {
      useHugeScreen(t);
      await t.pumpWidget(AppScope(state: h.state, child: MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: MapLayersSheet(model: model)))));
      await t.pumpAndSettle();
    }

    testWidgets('Plan: sections in order, This drive and the Activity rows disabled with their reasons, Names under Labels, no Filters', (t) async {
      ActiveMapDefinition.debugSet(_minor7());
      final h = Harness();
      await h.state.init();
      final model = pageModel(h, _prefs());
      await open(t, model, h);
      const present = ['base', 'coverage', 'network', 'activity', 'mine', 'context', 'labels', 'size', 'palette'];
      final y = [for (final g in present) t.getTopLeft(find.byKey(Key('layers-group-$g'), skipOffstage: false)).dy];
      expect([...y]..sort(), y, reason: 'Basemap, Coverage, Network, Activity, Mine, Context, Labels, Size and colour, Palette');
      expect(find.byKey(const Key('layers-group-filters'), skipOffstage: false), findsNothing, reason: 'the Plan map has no pings or timeline to filter');
      expect(find.byKey(const Key('layers-filter'), skipOffstage: false), findsNothing);
      // Disabled, never hidden, each with its reason.
      for (final id in ['layer-live', 'layer-path']) {
        final sw = t.widget<Switch>(find.byKey(Key(id), skipOffstage: false));
        expect(sw.onChanged, isNull, reason: id);
      }
      expect(find.textContaining('not drawn in the app yet', skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('layer-hexes-status'), skipOffstage: false), findsOneWidget);
      expect(find.text('Your drive is shown on the Drive map.', skipOffstage: false), findsWidgets);
      expect(find.byKey(const Key('layer-observers-status'), skipOffstage: false), findsOneWidget);
      // Names is the Labels section's row (the switch key is unchanged) and sits below Context.
      expect(t.getTopLeft(find.byKey(const Key('layer-labels'), skipOffstage: false)).dy, greaterThan(t.getTopLeft(find.byKey(const Key('layers-group-labels'), skipOffstage: false)).dy));
      expect(t.getTopLeft(find.byKey(const Key('layer-borders'), skipOffstage: false)).dy, lessThan(t.getTopLeft(find.byKey(const Key('layers-group-labels'), skipOffstage: false)).dy));
      // A shared layer switches and the choice is remembered under the page.
      expect(model.layerState.isOn(kRosterLayerId), isTrue);
      await t.tap(find.byKey(const Key('layer-region-repeaters')));
      await t.pumpAndSettle();
      expect(model.layerState.isOn(kRosterLayerId), isFalse);
    });

    testWidgets('Plan: Road, Dark, Topo, Satellite under variables.basemap; Chart and Light are one entry', (t) async {
      ActiveMapDefinition.debugSet(_minor7());
      final h = Harness();
      await h.state.init();
      final model = pageModel(h, _prefs());
      await open(t, model, h);
      expect(find.byKey(const Key('base-map-chart'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('base-map-street'), skipOffstage: false), findsNothing);
      expect(find.text('Road', skipOffstage: false), findsOneWidget);
      expect(find.text('Chart', skipOffstage: false), findsNothing);
      expect(find.text('Light', skipOffstage: false), findsNothing);
      await t.tap(find.byKey(const Key('base-map-dark')));
      await t.pumpAndSettle();
      expect(h.state.settings.baseMapStyle, 'dark');
      expect(model.baseStyle, BaseMapStyle.dark);
    });

    testWidgets('Drive: the same order with Activity and Mine, Live and Path disabled, This drive under Mine, Filters shows its count', (t) async {
      ActiveMapDefinition.debugSet(_minor7());
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(h.state, prefs: _prefs());
      addTearDown(model.dispose);
      await open(t, model, h);
      const present = ['base', 'coverage', 'network', 'activity', 'mine', 'context', 'labels', 'filters', 'size', 'palette'];
      final y = [for (final g in present) t.getTopLeft(find.byKey(Key('layers-group-$g'), skipOffstage: false)).dy];
      expect([...y]..sort(), y);
      final mine = t.getTopLeft(find.byKey(const Key('layers-group-mine'), skipOffstage: false)).dy;
      expect(t.getTopLeft(find.byKey(const Key('layer-hexes'), skipOffstage: false)).dy, greaterThan(mine));
      expect(t.getTopLeft(find.byKey(const Key('layer-pings'), skipOffstage: false)).dy, greaterThan(mine));
      for (final id in ['layer-live', 'layer-path']) {
        final sw = t.widget<Switch>(find.byKey(Key(id), skipOffstage: false));
        expect(sw.onChanged, isNull, reason: id);
      }
      expect(find.text('FILTERS', skipOffstage: false), findsOneWidget, reason: 'no filter set: no count');
      model.filter = const MapFilter(ownOnly: true);
      model.coverageQuery = const CoverageQuery(since: CoverageSince.week);
      await t.pumpAndSettle();
      expect(find.text('FILTERS · 2', skipOffstage: false), findsOneWidget);
      expect(find.byKey(const Key('layers-filter'), skipOffstage: false), findsOneWidget);
      // The old Chart / Light pair is Road.
      expect(find.byKey(const Key('base-map-street'), skipOffstage: false), findsNothing);
      expect(find.text('Road', skipOffstage: false), findsOneWidget);
    });

    testWidgets('fallback: without variables.basemap the picker is build 73\'s (Chart, Light, Dark) and the groups are the bundled ones', (t) async {
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(h.state, prefs: _prefs());
      addTearDown(model.dispose);
      await open(t, model, h);
      expect(MapDefinition.bundled.basemapVariableIds, isNull);
      for (final id in ['chart', 'street', 'dark']) {
        expect(find.byKey(Key('base-map-$id'), skipOffstage: false), findsOneWidget, reason: id);
      }
      expect(find.text('Chart', skipOffstage: false), findsOneWidget);
      expect(find.text('Light', skipOffstage: false), findsOneWidget);
      expect(find.text('Road', skipOffstage: false), findsNothing);
      for (final g in ['activity', 'mine']) {
        expect(find.byKey(Key('layers-group-$g'), skipOffstage: false), findsNothing, reason: 'the bundled definition has no $g group');
      }
      expect(find.byKey(const Key('layer-live'), skipOffstage: false), findsNothing);
      expect(find.text('FILTERS', skipOffstage: false), findsOneWidget);
    });
  });
}
