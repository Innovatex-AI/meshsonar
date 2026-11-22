// MAP slice 5 (app half, build 75): the `repeaters` / `observers` layers of the page presets on the small maps. A preview has no node
// feed of its own, so it draws them only from the list the caller passes (the region's already-loaded nodes); nothing is drawn
// without a list, without the page's preset (MapDefinition.bundled, no `pages`), or for a layer the preset does not list.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/map_preview.dart';
import 'package:meshsonar/ui/map/still/place_map.dart';
import 'package:meshsonar/ui/map/still/still_nodes.dart';
import 'package:meshsonar/ui/theme.dart';

void _useLive() {
  ActiveMapDefinition.notifier.value = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
  addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
}

final _reps = [
  const StillNode(key: 'aa11', name: 'One', lat: 40.0, lon: -83.0),
  const StillNode(key: 'bb22', name: 'Room', role: 'room', lat: 40.01, lon: -83.01),
];
final _obs = [const StillNode(key: 'cc33', name: 'Obs', role: 'observer', lat: 40.02, lon: -83.02)];

Future<void> _pump(WidgetTester t, {String? page, List<StillNode>? repeaters, List<StillNode>? observers}) async {
  await t.pumpWidget(MaterialApp(
    theme: meshSonarTheme(Brightness.light),
    home: SizedBox(
      width: 400,
      height: 400,
      child: MapPreview(page: page, center: const LatLng(40.0, -83.0), zoom: 13, tiles: false, repeaters: repeaters, observers: observers),
    ),
  ));
  await t.pump();
}

void main() {
  testWidgets('page path lists repeaters and observers: both are drawn with node symbols', (t) async {
    _useLive();
    await _pump(t, page: 'path', repeaters: _reps, observers: _obs);
    expect(find.byKey(const Key('preview-repeaters')), findsOneWidget);
    expect(find.byKey(const Key('preview-observers')), findsOneWidget);
    expect(find.byKey(const Key('still-node-aa11')), findsOneWidget);
    expect(find.byKey(const Key('still-node-bb22')), findsOneWidget);
    expect(find.byKey(const Key('still-node-cc33')), findsOneWidget);
  });

  testWidgets('page node lists repeaters only: observers passed to it are not drawn', (t) async {
    _useLive();
    await _pump(t, page: 'node', repeaters: _reps, observers: _obs);
    expect(find.byKey(const Key('preview-repeaters')), findsOneWidget);
    expect(find.byKey(const Key('preview-observers')), findsNothing);
  });

  testWidgets('no list, an empty list, no page, or no pages in the definition: nothing is drawn', (t) async {
    _useLive();
    await _pump(t, page: 'path');
    expect(find.byKey(const Key('preview-repeaters')), findsNothing);
    await _pump(t, page: 'path', repeaters: const [], observers: const []);
    expect(find.byKey(const Key('preview-repeaters')), findsNothing);
    expect(find.byKey(const Key('preview-observers')), findsNothing);
    await _pump(t, repeaters: _reps, observers: _obs);
    expect(find.byKey(const Key('preview-repeaters')), findsNothing);

    ActiveMapDefinition.notifier.value = MapDefinition.bundled;
    await _pump(t, page: 'path', repeaters: _reps, observers: _obs);
    expect(find.byKey(const Key('preview-repeaters')), findsNothing);
    expect(find.byKey(const Key('preview-observers')), findsNothing);
  });

  testWidgets('a place map leaves its own node out of the repeaters behind it', (t) async {
    _useLive();
    await t.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: SingleChildScrollView(
        child: StillPlaceMap(page: 'node', role: 'repeater', name: 'One', lat: 40.0, lon: -83.0, tiles: false, nodeKey: 'AA11', repeaters: _reps),
      ),
    ));
    await t.pump();
    expect(find.byKey(const Key('still-node-aa11')), findsNothing);
    expect(find.byKey(const Key('still-node-bb22')), findsOneWidget);
  });
}
