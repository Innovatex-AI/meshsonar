// Network > Live on the full map engine (build 75): the Layers button and sheet for page `live`, the one legend chip, the nodes from
// the definition's `live` preset, the panels never stacking, a definition without `pages` drawing as build 74 did, and a packet
// never rebuilding the node layer.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_pages.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/coverage_map.dart' show CoverageMap;
import 'package:meshsonar/ui/map/layers/layers_sheet.dart' show layerSwitchKey;
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show kLabelsLayerId, kRosterLayerId;
import 'package:meshsonar/ui/network/live/live_map_controller.dart';
import 'package:meshsonar/ui/network/live/live_map_view.dart';
import 'package:meshsonar/ui/network/live/live_nodes_layer.dart' show liveNodeMarkerBuilds;
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'live_map_test.dart' show FakeSse, fixture, j, makeController, packetEvent, settle;

const _region = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus', url: 'https://cmh.meshsonar.com', bbox: [-83.2, 39.8, -82.8, 40.2]);

MapDefinition _withPages() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());

Future<LiveMapController> _pump(WidgetTester tester, FakeSse fake) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  MapPanelStore.clear();
  late LiveMapController c;
  await tester.runAsync(() async => c = makeController(fake));
  await tester.pumpWidget(AppScope(
    state: Harness().state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(body: NetworkLiveMap(region: _region, controller: c, showBasemap: false)),
    ),
  ));
  await tester.pump();
  // The nodes load (a few pages of /v1/nodes) after the first frame.
  await tester.runAsync(settle);
  await tester.pump();
  return c;
}

void main() {
  setUp(() {
    PowerProfile.debugReset();
    resetV1NotLive();
    nodesApiFactory = (b) => NodesApi(b, client: MockClient((r) async => j(fixture(r.url.path.endsWith('/nodes') ? 'nodes.json' : 'observers.json'))));
    packetsApiFactory = (b) => PacketsApi(b, client: MockClient((r) async => http.Response('{}', 404)));
    MapPrefs.shared.setLayerPrefs(kLiveLayerPage, LayerPrefs.empty);
  });
  tearDown(() {
    nodesApiFactory = (b) => NodesApi(b);
    packetsApiFactory = (b) => PacketsApi(b);
    MapPrefs.shared.setLayerPrefs(kLiveLayerPage, LayerPrefs.empty);
    ActiveMapDefinition.debugSet();
  });

  group('with the definition\'s live preset', () {
    setUp(() => ActiveMapDefinition.debugSet(_withPages()));

    testWidgets('the nodes, their names, the region border, a Layers button and the one legend chip are on the map', (tester) async {
      final c = await _pump(tester, FakeSse());
      expect(find.byType(CoverageMap), findsOneWidget);
      expect(find.byKey(const Key('live-nodes-markers')), findsOneWidget);
      expect(find.byKey(const Key('live-nodes-names')), findsOneWidget);
      expect(find.byKey(const Key('region-borders-layer')), findsOneWidget);
      expect(find.byKey(const Key('drive-map-layers')), findsOneWidget);
      expect(find.byKey(const Key('live-legend-card')), findsOneWidget);
      final on = tester.widget<CoverageMap>(find.byType(CoverageMap)).layerState!.on;
      expect(on, containsAll([kRosterLayerId, kLabelsLayerId, 'borders']));
      expect(on.contains('measured') || on.contains('hexes'), isFalse, reason: 'the live preset has no coverage');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('Layers opens the shared sheet for page live; Repeaters off hides the nodes and is remembered under `live`', (tester) async {
      final c = await _pump(tester, FakeSse());
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
      await tester.dragUntilVisible(find.byKey(layerSwitchKey(kRosterLayerId)), find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first, const Offset(0, -120));
      await tester.ensureVisible(find.byKey(layerSwitchKey(kRosterLayerId)));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(layerSwitchKey(kRosterLayerId)));
      await tester.pump();
      expect(find.byKey(const Key('live-nodes-markers')), findsNothing);
      expect(MapPrefs.shared.layerPrefs(kLiveLayerPage).toggles[kRosterLayerId], isFalse);
      expect(MapPrefs.shared.layerPrefs('drive').toggles.containsKey(kRosterLayerId), isFalse, reason: 'the Drive map keeps its own choice');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the Live panel and the Layers panel never stack, and a drawn packet and Layers take turns', (tester) async {
      final fake = FakeSse();
      final c = await _pump(tester, fake);
      // Layers open (the Live panel is at its header): the Live body is not there.
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
      expect(find.byKey(const Key('live-panel-body')), findsNothing);
      // Opening the Live panel sends Layers back to its header: the two bodies are never open together.
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('live-panel-body')), findsOneWidget);
      expect(find.byKey(const Key('layers-sheet')), findsNothing, reason: 'one open panel per map');
      expect(find.byKey(const Key('live-map-pause')), findsOneWidget, reason: 'the Live header keeps working');
      // Back to Live collapsed, Layers open again, then a drawn packet takes the spot of the Layers panel.
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(() async {
        fake.send(packetEvent('1111000011112222'));
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      // The Layers panel is still the map's panel (at its header): the button closes it, a second tap opens it again.
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('drive-map-layers')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
      c.showPacket(c.feed.single);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      expect(find.byKey(const Key('layers-sheet')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('200 packets do not rebuild the node layer', (tester) async {
      final fake = FakeSse();
      final c = await _pump(tester, fake);
      await tester.runAsync(() async {
        fake.send(packetEvent('0000000011112222'));
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      final before = liveNodeMarkerBuilds;
      expect(before, greaterThan(0), reason: 'the node layer is on the map');
      await tester.runAsync(() async {
        for (var i = 1; i <= 200; i++) {
          fake.send(packetEvent('${(1000 + i).toRadixString(16).padLeft(4, '0')}000011112222', at: '2026-11-20T14:${(i ~/ 60).toString().padLeft(2, '0')}:${(i % 60).toString().padLeft(2, '0')}.000Z'));
        }
        await settle();
      });
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(c.feed.length, greaterThan(100), reason: 'the packets arrived');
      expect(liveNodeMarkerBuilds, before, reason: 'the nodes in use did not change, so the node layer did not rebuild');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('a definition without pages (the bundled copy) draws as build 74 did', () {
    setUp(() => ActiveMapDefinition.debugSet());

    testWidgets('the nodes and their names, no border, no coverage; the Layers button is still there', (tester) async {
      expect(ActiveMapDefinition.current.hasPages, isFalse);
      final c = await _pump(tester, FakeSse());
      expect(find.byKey(const Key('live-nodes-markers')), findsOneWidget);
      expect(find.byKey(const Key('live-nodes-names')), findsOneWidget);
      expect(find.byKey(const Key('region-borders-layer')), findsNothing);
      expect(tester.widget<CoverageMap>(find.byType(CoverageMap)).layerState!.on, {kRosterLayerId, kLabelsLayerId});
      expect(find.byKey(const Key('drive-map-layers')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
