// MAP slice 5 (app half, build 75): the numbered path map on Network > Tools. The `/v1` answers carry no hop positions (checked
// against the live API and the site: ToolNode is key, name, role), so a hop is placed from the region's already-loaded repeater
// list by its node key, and by prefix when the server named no node (one match certain, several likely). A hop with no position
// keeps its number, is listed under the map and breaks the line. With no `symbols.path` in the definition (MapDefinition.bundled),
// or no loaded list, the screens draw what build 74 drew: no map.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/v1/tools_api.dart';
import 'package:meshsonar/core/v1/v1_client.dart' show resetV1NotLive;
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/still/path_layer.dart';
import 'package:meshsonar/ui/map/still/still_nodes.dart';
import 'package:meshsonar/ui/network/tools/path_inspector_screen.dart';
import 'package:meshsonar/ui/network/tools/tool_path_spec.dart';
import 'package:meshsonar/ui/network/tools/trace_viewer_screen.dart';
import 'package:meshsonar/ui/theme.dart';

String fixture(String name) => File('test/fixtures/analyzer/$name.json').readAsStringSync();
http.Response json(String body) => http.Response(body, 200, headers: {'content-type': 'application/json; charset=utf-8'});
const base = 'https://cmh.meshsonar.com';
const traceHash = '50b835a910da5aac';

// keys of the fixtures' candidate 1 (a1 -> KE9EJF Porta-peater, 3f -> IN.MAR room)
const kA1 = 'a10f4e754a4ae71cace6d45970f59754da883e911140a12ac54841939051b12d';
const kRoom = '3f35e309b39e616352277e74df6874454f6ac48a99006b3d05ce96c84fcada9f';
const kTraceA1 = 'a11032bf794a6d6e0d9cb64239a1da85a9bfae12c0d744d1fac0cb04aeebcce7';

StillNode _n(String key, String name, double lat, double lon, {String role = 'repeater'}) => StillNode(key: key, name: name, lat: lat, lon: lon, role: role);

void _useLive() {
  ActiveMapDefinition.notifier.value = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
  addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
}

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(375, 3600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(const SizedBox());
  await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.dark), home: child));
  await tester.pump();
  await tester.pump();
}

void main() {
  late MockClient client;
  setUp(() {
    resetV1NotLive();
    client = MockClient((r) async {
      if (r.url.path == '/v1/tools/path-inspect') return json(fixture('tools-path-inspect'));
      if (r.url.path == '/v1/traces/$traceHash') return json(fixture('tools-trace'));
      if (r.url.path == '/v1/packets') return json(jsonEncode({'data': [], 'page': {'limit': 30, 'next': null, 'prev': null}, 'meta': (jsonDecode(fixture('tools-trace')) as Map)['meta']}));
      return http.Response('{}', 404);
    });
    toolsApiFactory = (_) => ToolsApi(base, client: client);
  });

  group('toolPathSpec', () {
    final nodes = [_n(kA1, 'Porta', 40.0, -83.0), _n(kRoom, 'Room', 40.1, -83.1, role: 'room'), _n('c4${'0' * 62}', 'C4 one', 40.2, -83.2), _n('3f${'1' * 62}', 'Three-F', 40.05, -83.05), _n('3f${'2' * 62}', 'Three-F far', 41.0, -84.0)];

    test('a named hop is placed by its key; one the list does not hold is unplaced', () {
      final s = toolPathSpec([
        ToolHopInput(prefix: 'a1', node: const ToolNode(key: kA1, name: 'KE9EJF'), sure: true),
        ToolHopInput(prefix: 'ee', node: ToolNode(key: 'ee${'0' * 62}', name: 'Gone')),
      ], nodes);
      expect(s.hops.map((h) => h.n), [1, 2]);
      expect(s.hops.map((h) => h.placed), [true, false]);
      expect(s.hops.first.name, 'KE9EJF');
      expect(s.hops.first.certainty, PathCertainty.certain);
      expect(s.unplaced.single.name, 'Gone');
      expect(s.links, isEmpty);
    });

    test('a hop the server did not name is found by prefix: one match certain, several likely (nearest the hop before), none unplaced', () {
      final s = toolPathSpec([
        const ToolHopInput(prefix: 'c4'),
        const ToolHopInput(prefix: '3f'),
        const ToolHopInput(prefix: 'dd'),
      ], nodes);
      expect(s.hops[0].placed, isTrue);
      expect(s.hops[0].certainty, PathCertainty.certain);
      expect(s.hops[0].name, 'C4 one');
      // three nodes share 3f (the room, Three-F, Three-F far): the one nearest the previous hop (40.2, -83.2) is the room (40.1, -83.1)
      expect(s.hops[1].name, 'Room');
      expect(s.hops[1].certainty, PathCertainty.likely);
      expect(s.hops[2].placed, isFalse);
      expect(s.hops[2].name, 'dd');
      expect(s.unplaced.map((h) => h.n), [3]);
    });

    test('a hop the server is not sure of is likely; the link to it is dashed', () {
      final s = toolPathSpec([
        ToolHopInput(prefix: 'a1', node: const ToolNode(key: kA1, name: 'A'), sure: true),
        ToolHopInput(prefix: '3f', node: const ToolNode(key: kRoom, name: 'R'), sure: false),
      ], nodes);
      expect(s.links.single.certainty, PathCertainty.likely);
      expect(unplacedListText(toolPathSpec([const ToolHopInput(prefix: 'dd'), const ToolHopInput(prefix: 'ee')], nodes)), '1 · dd, 2 · ee');
    });
  });

  group('still nodes', () {
    test('only nodes in view are drawn, at most the cap, nearest the centre first', () {
      final many = [for (var i = 0; i < 400; i++) _n('k$i', 'N$i', 40.0 + i * 0.001, -83.0)];
      final shown = stillNodesInView(many, centre: const LatLng(40.0, -83.0));
      expect(shown, hasLength(kStillNodesCap));
      expect(shown.first.key, 'k0');
    });

    test('freshness bands', () {
      final now = DateTime.utc(2026, 11, 22);
      expect(stillFreshness(now.subtract(const Duration(hours: 2)), now), 'fresh');
      expect(stillFreshness(now.subtract(const Duration(days: 3)), now), 'recent');
      expect(stillFreshness(now.subtract(const Duration(days: 30)), now), 'stale');
      expect(stillFreshness(null, now), 'stale');
    });

    testWidgets('no AppScope, hub, or another region: no list', (t) async {
      List<StillNode>? got = const [];
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        got = stillRepeatersOf(c, regionSlug: 'cmh');
        return const SizedBox();
      })));
      expect(got, isNull);
    });
  });

  group('Path Inspector map', () {
    final nodes = [_n(kA1, 'Porta', 40.0, -83.0), _n(kRoom, 'Room', 40.1, -83.1, role: 'room')];

    testWidgets('the open route is on the numbered map with its key', (tester) async {
      _useLive();
      await _pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', initialHops: 'a1 3f', nodes: nodes));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('path-map-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-2')), findsOneWidget);
      // hopScore 0.74 / 0.23 are under 0.99: both likely, so the line is dashed
      expect(find.byKey(const Key('path-lines-dashed')), findsOneWidget);
      expect(find.byKey(const Key('path-key')), findsOneWidget);
      expect(find.byKey(const Key('path-map-unplaced')), findsNothing);
      expect(find.byKey(const Key('preview-repeaters')), findsOneWidget);
    });

    testWidgets('a hop the list cannot place is listed under the map with the unplaced count', (tester) async {
      _useLive();
      await _pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', initialHops: 'a1 3f', nodes: [nodes.first]));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-2')), findsNothing);
      expect(find.text('1 of 2 hops have no position: listed, not drawn.'), findsOneWidget);
      expect(find.textContaining('Not drawn: 2 · IN.MAR.I70.Dvsn.Obsvr.R'), findsOneWidget);
    });

    testWidgets('no loaded list, or no symbols.path: no map (build 74)', (tester) async {
      _useLive();
      await _pump(tester, PathInspectorScreen(baseUrl: base, regionSlug: 'cmh', initialHops: 'a1 3f'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('path-candidate-1')), findsOneWidget);
      expect(find.byKey(const Key('path-map-1')), findsNothing);

      ActiveMapDefinition.notifier.value = MapDefinition.bundled;
      await _pump(tester, PathInspectorScreen(key: const Key('b'), baseUrl: base, regionSlug: 'cmh', initialHops: 'a1 3f', nodes: nodes));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('path-candidate-1')), findsOneWidget);
      expect(find.byKey(const Key('path-map-1')), findsNothing);
      expect(find.byKey(const Key('path-key')), findsNothing);
    });
  });

  group('Trace Viewer map', () {
    // trace fixture: a1 unique (named), 3f ambiguous (no node), c4 unknown (no node)
    final nodes = [_n(kTraceA1, 'Nagglepuss2', 40.0, -83.0), _n('3f${'1' * 62}', 'Three-F', 40.05, -83.05), _n('3f${'2' * 62}', 'Three-F two', 40.5, -83.5)];

    testWidgets('hops are placed by key and prefix; the unknown one is listed and not drawn', (tester) async {
      _useLive();
      await _pump(tester, TraceViewerScreen(baseUrl: base, regionSlug: 'cmh', initialHash: traceHash, nodes: nodes));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('trace-map')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-2')), findsOneWidget);
      expect(find.byKey(const Key('path-disc-3')), findsNothing);
      // 3f has two matches: likely, so the 1-2 link is dashed
      expect(find.byKey(const Key('path-lines-dashed')), findsOneWidget);
      expect(find.text('1 of 3 hops have no position: listed, not drawn.'), findsOneWidget);
      expect(find.textContaining('Not drawn: 3 · c4'), findsOneWidget);
    });

    testWidgets('without symbols.path, or without a loaded list, there is no map (build 74)', (tester) async {
      await _pump(tester, TraceViewerScreen(baseUrl: base, regionSlug: 'cmh', initialHash: traceHash, nodes: nodes));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('trace-summary')), findsOneWidget);
      expect(find.byKey(const Key('trace-map')), findsNothing);

      _useLive();
      await _pump(tester, TraceViewerScreen(key: const Key('b'), baseUrl: base, regionSlug: 'cmh', initialHash: traceHash));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('trace-summary')), findsOneWidget);
      expect(find.byKey(const Key('trace-map')), findsNothing);
    });
  });
}
