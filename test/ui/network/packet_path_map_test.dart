// MAP slice 5 (app half): the packet detail's small route map (page `path`): the numbered, named hops from the packet's resolved
// path, solid for a unique hop and dashed for a likely one; a hop nobody can place is listed and breaks the line; no map without
// the definition's `symbols.path` (build 73).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/still/path_layer.dart';
import 'package:meshsonar/ui/network/packets/packet_detail_body.dart';
import 'package:meshsonar/ui/theme.dart';

Map<String, dynamic> _node(String key, String name) => {'key': key, 'name': name, 'role': 'repeater'};

PacketDetail _detail() {
  final j = jsonDecode(File('test/fixtures/analyzer/packet-detail.advert-first-party.json').readAsStringSync()) as Map<String, dynamic>;
  final d = (j['data'] as Map).cast<String, dynamic>();
  Map<String, dynamic> hop(int i, String prefix, String conf, {double? lat}) {
    final key = '$prefix${'0' * 62}';
    return {
      'index': i,
      'prefix': prefix,
      'confidence': conf,
      if (conf == 'unique' || conf == 'likely') 'node': _node(key, 'Node $prefix'),
      if (lat != null)
        'candidates': [
          {'node': _node(key, 'Node $prefix'), 'position': {'lat': lat, 'lon': -83.0 + i * 0.05}, 'score': 0.9}
        ],
      'candidatesTotal': 1,
      'evidence': <String>[],
    };
  }

  d['paths'] = [
    {
      'id': 'p1',
      'hops': [hop(0, '4f', 'unique', lat: 40.0), hop(1, 'a1', 'likely', lat: 40.05), hop(2, 'b2', 'unknown'), hop(3, 'c3', 'unique', lat: 40.1)],
      'observationIds': ['o1'],
    },
  ];
  return PacketDetail.fromV1(d);
}

Widget _app(PacketDetail d) => MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: Scaffold(body: PacketDetailBody(d: d, expandSections: true)),
    );

void main() {
  void useLive() {
    ActiveMapDefinition.notifier.value = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
    addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
  }

  test('packetPathSpec: unique is certain, likely is likely, an unplaced hop keeps its number but has no position', () {
    final s = packetPathSpec(_detail())!;
    expect(s.hops.map((h) => h.n), [1, 2, 3, 4]);
    expect(s.hops.map((h) => h.certainty), [PathCertainty.certain, PathCertainty.likely, PathCertainty.likely, PathCertainty.certain]);
    expect(s.hops.map((h) => h.placed), [true, true, false, true]);
    expect(s.hops.first.name, 'Node 4f');
    expect(s.unplaced.single.n, 3);
    // 1-2 is likely (one end likely); 2-3 and 3-4 are broken by the unplaced hop
    expect(s.links, hasLength(1));
  });

  testWidgets('with symbols.path the packet page draws the route map, its discs and its key', (t) async {
    useLive();
    t.view.physicalSize = const Size(1170, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(_detail()));
    await t.pump();
    expect(find.byKey(const Key('packet-path-map')), findsOneWidget);
    expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
    expect(find.byKey(const Key('path-disc-3')), findsNothing);
    expect(find.byKey(const Key('path-lines-dashed')), findsOneWidget);
    expect(find.byKey(const Key('path-lines-solid')), findsNothing);
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.text('1 of 4 hops have no position: listed, not drawn.'), findsOneWidget);
    expect(find.text('3 · Node 4f'), findsNothing);
    expect(find.text('1 · Node 4f'), findsOneWidget);
  });

  testWidgets('without symbols.path the packet page has no route map (build 73)', (t) async {
    t.view.physicalSize = const Size(1170, 6000);
    t.view.devicePixelRatio = 3;
    addTearDown(t.view.reset);
    await t.pumpWidget(_app(_detail()));
    await t.pump();
    expect(find.byKey(const Key('packet-path-map')), findsNothing);
    expect(find.byKey(const Key('path-key')), findsNothing);
  });
}
