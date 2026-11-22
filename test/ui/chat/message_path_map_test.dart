// MAP slice 5 (app half): the chat message's path map. With the definition's `symbols.path` it is the ONE path layer (numbered,
// named, solid certain / dashed likely, an unknown or unplaced hop listed and breaking the line); without it, the build 73 amber
// line with the repeater symbols.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/hop_resolver.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/ui/chat/message_info_card.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/theme.dart';

HopNode _n(String h, String? name, {double? lat, double? lon, List<String> candidates = const []}) =>
    HopNode(hash: h, name: name, source: HopSource.roster, lat: lat, lon: lon, candidates: candidates);

Future<void> _open(WidgetTester t, List<HopNode> nodes, {bool connect = true}) async {
  t.view.physicalSize = const Size(1170, 2400);
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: MessagePathMapScreen(title: 'How it reached you', nodes: nodes, connect: connect)));
  await t.pump();
}

void main() {
  void useLive() {
    ActiveMapDefinition.notifier.value = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
    addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
  }

  final nodes = [
    _n('a1', 'Ridge', lat: 40.0, lon: -83.0),
    _n('b2', null),
    _n('c3', 'Hill', lat: 40.05, lon: -83.05),
    _n('d4', 'Dale', lat: 40.1, lon: -83.1, candidates: ['Dale', 'Dell']),
  ];

  testWidgets('with symbols.path: numbered named discs, unknown hop listed and breaking the line, likely link dashed', (t) async {
    useLive();
    await _open(t, nodes);
    expect(find.byKey(const Key('path-map')), findsOneWidget);
    expect(find.byKey(const Key('path-disc-1')), findsOneWidget);
    expect(find.byKey(const Key('path-disc-2')), findsNothing);
    expect(find.byKey(const Key('path-disc-3')), findsOneWidget);
    expect(find.text('1 · Ridge'), findsOneWidget);
    expect(find.text('3 · Hill'), findsOneWidget);
    expect(find.text('4 · Dale'), findsOneWidget);
    // 1-2 and 2-3 are broken by the unknown hop; 3-4 is likely (ambiguous end): dashed only
    expect(find.byKey(const Key('path-lines-solid')), findsNothing);
    expect(find.byKey(const Key('path-lines-dashed')), findsOneWidget);
    expect(find.byKey(const Key('path-map-missing')), findsOneWidget);
    expect(find.text('1 of 4 hops have no position: listed, not drawn.'), findsOneWidget);
  });

  testWidgets('connect false (repeaters that relayed it): no line and no numbers', (t) async {
    useLive();
    await _open(t, nodes, connect: false);
    expect(find.byKey(const Key('path-lines-solid')), findsNothing);
    expect(find.byKey(const Key('path-lines-dashed')), findsNothing);
    expect(find.text('Ridge'), findsOneWidget);
  });

  testWidgets('without symbols.path: build 73, one amber line and the repeater symbols, no path key', (t) async {
    await _open(t, nodes);
    expect(find.byKey(const Key('path-map')), findsOneWidget);
    expect(find.byKey(const Key('path-key')), findsNothing);
    expect(find.byKey(const Key('path-disc-1')), findsNothing);
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.text('1. Ridge'), findsOneWidget);
    expect(find.text('2. Hill'), findsOneWidget);
  });
}
