// MAP slices 2 and 3 and the size choices (app half): the one node symbol set drawn on observers and phones, the Live map's nodes
// and names, names that follow the basemap showing, Label size and Icon size (Small / Normal / Large) on the maps and in the Layers
// sheet, and the colour-by tint.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoSlidingSegmentedControl;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/v1/nodes_api.dart' show NodeRow, PacketPosition;
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/layers/observer_layer.dart';
import 'package:meshsonar/ui/map/layers/repeater_name_labels.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart' show RepeaterBadge;
import 'package:meshsonar/ui/map/layers/repeater_sprites.dart';
import 'package:meshsonar/ui/map/map_size_controls.dart';
import 'package:meshsonar/ui/map/node_symbol.dart';
import 'package:meshsonar/ui/network/live/live_nodes_layer.dart';
import 'package:meshsonar/ui/theme.dart';

MapDefinition _v2() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync());

NodeRow _node(String key, String name, {String role = 'repeater', String status = 'active', double lat = 39.96, double lon = -83.0, int? hash, Duration heard = const Duration(hours: 1)}) =>
    NodeRow(key: key, prefix: key.substring(0, 2), role: role, status: status, name: name, position: PacketPosition(lat, lon), hashSize: hash, lastHeardAt: DateTime.now().subtract(heard));

Future<void> _pumpMap(WidgetTester t, List<Widget> children, {double zoom = 12.5, Brightness b = Brightness.light}) async {
  t.view.physicalSize = const Size(500, 700);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: meshSonarTheme(b),
    home: FlutterMap(options: MapOptions(initialCenter: const LatLng(39.96, -83.0), initialZoom: zoom), children: children),
  ));
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    ActiveMapDefinition.debugSet(_v2());
    MapPrefs.shared.labelSize = MapSizeChoice.normal;
    MapPrefs.shared.iconSize = MapSizeChoice.normal;
    MapPrefs.shared.colourBy = null;
  });
  tearDown(() {
    ActiveMapDefinition.debugSet();
    MapPrefs.shared.labelSize = MapSizeChoice.normal;
    MapPrefs.shared.iconSize = MapSizeChoice.normal;
    MapPrefs.shared.colourBy = null;
  });

  group('the one symbol set on observers and phones', () {
    testWidgets('a fixed observer is the eye-on-a-mast badge (solid ring online, faded offline); a phone is the phone outline fading with age', (t) async {
      final now = DateTime.utc(2026, 11, 22, 12);
      final rows = [
        RegionObserver.tryParse({'key': 'on1', 'online': true, 'lat': 39.96, 'lon': -83.0})!,
        RegionObserver.tryParse({'key': 'off1', 'online': false, 'lat': 39.97, 'lon': -83.01})!,
        RegionObserver.tryParse({'key': 'ph1', 'name': 'p', 'kind': 'mobile', 'online': true, 'lat': 39.95, 'lon': -83.0, 'lastSeenAt': now.subtract(const Duration(minutes: 5)).toIso8601String()})!,
      ];
      await _pumpMap(t, [ObserverLayer(observers: rows, now: () => now)], zoom: 11);
      NodeSymbol sym(String key) => t.widget<NodeSymbol>(find.byKey(ValueKey(key)));
      expect((sym('map-observer-on1-online').role, sym('map-observer-on1-online').freshness), ('observer', 'fresh'));
      expect((sym('map-observer-off1-offline').role, sym('map-observer-off1-offline').freshness), ('observer', 'stale'));
      expect(sym('map-observer-ph1-mobile').role, 'phone');
      expect(sym('map-observer-ph1-mobile').opacity, closeTo(0.6, 0.05), reason: '5 of 10 minutes: 1 - 0.8 x 0.5');
      // No triangle painter is left on the observers layer.
      final painters = t.widgetList<CustomPaint>(find.byType(CustomPaint)).map((c) => c.painter.runtimeType.toString()).toSet();
      expect(painters, isNot(contains('ObserverTrianglePainter')));
      expect(painters, contains('NodeSymbolPainter'));
    });

    testWidgets('Icon size: the same marker is 0.85 / 1.0 / 1.25 of the set\'s 24 pt', (t) async {
      final rows = [RegionObserver.tryParse({'key': 'on1', 'online': true, 'lat': 39.96, 'lon': -83.0})!];
      final sizes = <double>[];
      for (final c in MapSizeChoice.values) {
        MapPrefs.shared.iconSize = c;
        await _pumpMap(t, [ObserverLayer(observers: rows)], zoom: 11);
        final paint = t.widget<CustomPaint>(find.descendant(of: find.byKey(const ValueKey('map-observer-on1-online')), matching: find.byType(CustomPaint)).first);
        sizes.add(paint.size.width);
      }
      expect(sizes, [closeTo(20.4, 0.01), 24, 30]);
    });

    testWidgets('colour by status tints the badge with the definition\'s status colour and puts the glyph on the on-tint ink', (t) async {
      await _pumpMap(t, [
        Center(child: Column(children: const [
          NodeSymbol(key: Key('neutral'), role: 'repeater'),
          NodeSymbol(key: Key('degraded'), role: 'repeater', tint: 'degraded', tintVariable: 'status'),
        ])),
      ]);
      NodeSymbolPainter p(String k) => t.widget<CustomPaint>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(CustomPaint)).first).painter! as NodeSymbolPainter;
      expect(p('neutral').tint, isNull);
      expect(p('degraded').tint, 0xFFC77800, reason: 'light theme: #C77800');
    });
  });

  group('Live: the nodes and their names', () {
    final nodes = [
      _node('aa' * 32, 'Hilltop', lat: 39.96, lon: -83.0),
      _node('bb' * 32, 'Reservoir', lat: 39.965, lon: -83.01, role: 'room', status: 'degraded', hash: 1),
      _node('cc' * 32, 'Someone\'s radio', role: 'companion'),
      NodeRow(key: 'dd' * 32, prefix: 'dd', role: 'repeater', name: 'No position'),
    ];

    test('only repeaters and rooms with a position are drawn; freshness and tint follow the node', () {
      expect([for (final r in liveDrawableNodes(nodes)) r.label], ['Hilltop', 'Reservoir']);
      final now = DateTime.now();
      expect(liveNodeFreshness(_node('a' * 64, 'x', heard: const Duration(hours: 2)), now), 'fresh');
      expect(liveNodeFreshness(_node('a' * 64, 'x', heard: const Duration(days: 3)), now), 'recent');
      expect(liveNodeFreshness(_node('a' * 64, 'x', heard: const Duration(days: 9)), now), 'stale');
      final r = _node('a' * 64, 'x', status: 'silent', role: 'room', hash: 3);
      expect([for (final v in ['none', 'status', 'role', 'hash']) liveNodeTint(r, v)], [null, 'silent', 'room', 'multi']);
      expect(liveNodeTint(_node('a' * 64, 'x', hash: 1), 'hash'), 'one');
      expect(liveNodeTint(_node('a' * 64, 'x'), 'hash'), 'unknown');
    });

    testWidgets('at region zoom the nodes are on the map as symbols and named; the packet-crossed one is solid', (t) async {
      await _pumpMap(t, liveNodeLayers(nodes: nodes, inUse: {'aa' * 32}, style: BaseMapStyle.chart, brightness: Brightness.light));
      expect(find.byKey(ValueKey('live-node-${'aa' * 32}')), findsOneWidget);
      expect(find.byKey(ValueKey('live-node-${'bb' * 32}')), findsOneWidget);
      expect(find.byKey(ValueKey('live-node-${'cc' * 32}')), findsNothing, reason: 'a companion is not a Live node');
      NodeSymbolPainter p(String k) => t.widget<CustomPaint>(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(CustomPaint)).first).painter! as NodeSymbolPainter;
      expect(p('live-node-${'aa' * 32}').opacity, 1, reason: 'a packet is crossing it');
      expect(p('live-node-${'bb' * 32}').opacity, lessThan(1), reason: 'dim, so the packets stay the picture');
      expect(p('live-node-${'bb' * 32}').role.id, 'room');
      // The names are the one label engine's: a painter with both names (spec: repeaters from zoom 11, 24 at most).
      final labels = t.widgetList<CustomPaint>(find.byKey(RepeaterNameLabels.paintKey));
      expect(labels, isNotEmpty);
      final lp = labels.first.painter! as LabelPainter;
      expect([for (final l in lp.labels) l.text], containsAll(['Hilltop', 'Reservoir']));
      expect(lp.fontSize, 13, reason: 'spec size at zoom 12.5');
      expect(lp.pill, isFalse, reason: 'Chart is the Road map: a halo, not a pill');
    });

    testWidgets('zoomed out (below the first name zoom) only the nodes in use are drawn', (t) async {
      await _pumpMap(t, liveNodeLayers(nodes: nodes, inUse: {'bb' * 32}, style: BaseMapStyle.chart, brightness: Brightness.light), zoom: 8);
      expect(find.byKey(ValueKey('live-node-${'aa' * 32}')), findsNothing);
      expect(find.byKey(ValueKey('live-node-${'bb' * 32}')), findsOneWidget);
    });

    testWidgets('Colour nodes by Status tints the node badges; Nothing leaves them neutral', (t) async {
      MapPrefs.shared.colourBy = 'status';
      await _pumpMap(t, liveNodeLayers(nodes: nodes, inUse: const {}, style: BaseMapStyle.chart, brightness: Brightness.light));
      NodeSymbolPainter p(String k) => t.widget<CustomPaint>(find.descendant(of: find.byKey(ValueKey(k)), matching: find.byType(CustomPaint)).first).painter! as NodeSymbolPainter;
      expect(p('live-node-${'aa' * 32}').tint, 0xFF0B6FB8, reason: 'active');
      expect(p('live-node-${'bb' * 32}').tint, 0xFFC77800, reason: 'degraded');
      MapPrefs.shared.colourBy = 'none';
      await t.pump();
      expect(p('live-node-${'aa' * 32}').tint, isNull);
    });

    testWidgets('no nodes: nothing is added to the map', (t) async {
      expect(liveNodeLayers(nodes: const [], inUse: const {}, style: BaseMapStyle.chart, brightness: Brightness.light), isEmpty);
    });
  });

  RepeaterBadge aBadge() => RepeaterBadge(key: 'ee' * 32, name: 'Hilltop', lat: 39.96, lon: -83.0, heard: true);

  group('Label size', () {
    List<Widget> names() => [
      RepeaterNameLabels(
        sources: const [],
        badges: [aBadge()],
      ),
    ];

    testWidgets('Small / Normal / Large scale the name text 0.85 / 1.0 / 1.25 on top of the spec size (13 at zoom 12.5)', (t) async {
      final sizes = <double>[];
      for (final c in MapSizeChoice.values) {
        MapPrefs.shared.labelSize = c;
        await _pumpMap(t, names());
        final lp = t.widget<CustomPaint>(find.byKey(RepeaterNameLabels.paintKey)).painter! as LabelPainter;
        sizes.add(lp.fontSize);
      }
      expect(sizes, [closeTo(13 * 0.85, 0.001), 13, closeTo(13 * 1.25, 0.001)]);
    });

    testWidgets('names on Topo sit on a pill, on Satellite a pill with light ink, on Light under a dark app dark ink', (t) async {
      Future<LabelPainter> painterFor(BaseMapStyle s, Brightness b) async {
        final tone = labelToneFor(s, b);
        await _pumpMap(
          t,
          [RepeaterNameLabels(sources: const [], badges: [aBadge()], pill: tone.pill, darkMap: tone.dark)],
          b: b,
        );
        return t.widget<CustomPaint>(find.byKey(RepeaterNameLabels.paintKey)).painter! as LabelPainter;
      }

      final topo = await painterFor(BaseMapStyle.topo, Brightness.light);
      expect(topo.pill, isTrue);
      final sat = await painterFor(BaseMapStyle.satellite, Brightness.light);
      expect((sat.pill, sat.ink), (true, const Color(0xFFF4F6F8)));
      final lightUnderDark = await painterFor(BaseMapStyle.street, Brightness.dark);
      expect((lightUnderDark.pill, lightUnderDark.ink), (false, const Color(0xFF1B1F24)));
      expect(lightUnderDark.halo, const Color(0xFFFFFFFF));
    });
  });

  group('Icon size on the Drive map\'s repeater badges', () {
    test('the atlas key and the badge radius follow the choice', () {
      final theme = RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.blue, ok: Colors.green);
      expect(RepeaterSpriteKey(theme, 2, 1.0) == RepeaterSpriteKey(theme, 2, 1.25), isFalse);
      expect(RepeaterSpriteKey(theme, 2) == RepeaterSpriteKey(theme, 2, 1.0), isTrue);
    });

    test('a scaled sprite paints without error and covers a bigger area', () {
      final theme = RepeaterSpriteTheme(brightness: Brightness.light, accent: Colors.blue, ok: Colors.green);
      for (final s in [0.85, 1.0, 1.25]) {
        final rec = ui.PictureRecorder();
        paintRepeaterSprite(Canvas(rec), const Offset(50, 50), const RepeaterSpriteSpec(RepeaterFreshness.fresh, false, SpriteVariant.badgeLarge), theme, scale: s);
        final pic = rec.endRecording();
        expect(pic.approximateBytesUsed, greaterThan(0));
        pic.dispose();
      }
    });
  });

  group('the size and colour rows (Layers sheet)', () {
    testWidgets('Label size and Icon size each offer Small / Normal / Large, Normal selected; a tap saves the choice; colour by lists the definition\'s options', (t) async {
      await t.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: Column(children: [MapSizeControls(), ColourByControl()])))));
      expect(find.text('Label size'), findsOneWidget);
      expect(find.text('Icon size'), findsOneWidget);
      for (final id in ['label', 'icon']) {
        expect(t.widget<CupertinoSlidingSegmentedControl<MapSizeChoice>>(find.byKey(Key('map-$id-size'))).groupValue, MapSizeChoice.normal);
        for (final c in ['small', 'normal', 'large']) {
          expect(find.byKey(Key('map-$id-size-$c')), findsOneWidget);
        }
      }
      await t.tap(find.byKey(const Key('map-label-size-large')));
      await t.pump(const Duration(milliseconds: 400));
      await t.tap(find.byKey(const Key('map-icon-size-small')));
      await t.pump(const Duration(milliseconds: 400));
      expect((MapPrefs.shared.labelSize, MapPrefs.shared.iconSize), (MapSizeChoice.large, MapSizeChoice.small));
      expect(find.byKey(const Key('map-colour-by-none')), findsOneWidget);
      expect(find.byKey(const Key('map-colour-by-status')), findsOneWidget);
      expect(find.byKey(const Key('map-colour-by-hash')), findsOneWidget);
      expect(find.byKey(const Key('map-colour-by-role')), findsOneWidget);
      expect(find.byKey(const Key('map-colour-by-scope')), findsNothing, reason: 'the server says Scope has no data yet');
      await t.tap(find.byKey(const Key('map-colour-by-role')));
      await t.pump();
      expect(colourByNow(), 'role');
    });

    testWidgets('an older definition without colour by shows the size rows only', (t) async {
      ActiveMapDefinition.debugSet();
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: Column(children: [MapSizeControls(), ColourByControl()]))));
      expect(find.byKey(const Key('map-size-controls')), findsOneWidget);
      expect(find.byKey(const Key('map-colour-by')), findsNothing);
      expect(colourByNow(), 'none');
    });
  });
}
