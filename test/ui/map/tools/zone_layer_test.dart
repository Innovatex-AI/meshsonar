// Privacy zones from `symbols.tools.zone` / `handle` (MAP slice 6, app half): fill and opacity normal / active, dashed edge and width,
// light and dark; and the fallback, where a definition without them draws what build 73 drew (the editor's CircleLayer in theme
// colours) and the drive report draws nothing.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/map/tools/hidden_track_layer.dart';
import 'package:meshsonar/ui/map/tools/zone_layer.dart';

import '../../../support/tool_definition.dart';

const zones = [
  PrivacyZone(lat: 40.0, lon: -83.0, radiusM: 300),
  PrivacyZone(lat: 40.01, lon: -83.01, radiusM: 500),
];

Future<void> pumpMap(WidgetTester t, Widget layer, Brightness b) => t.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: b),
      home: SizedBox(
        width: 300,
        height: 300,
        child: FlutterMap(options: const MapOptions(initialCenter: LatLng(40, -83), initialZoom: 13), children: [layer]),
      ),
    ));

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('${b.name}: normal and active zone from the definition, dashed edge', (t) async {
      final dark = b == Brightness.dark;
      await pumpMap(t, ZoneLayer(zones: zones, selected: 1, definition: liveToolDefinition()), b);
      final polys = t.widget<PolygonLayer>(find.byType(PolygonLayer)).polygons;
      expect(polys, hasLength(2));
      final fill = dark ? 0xFF94A3B8 : 0xFF64748B, edge = dark ? 0xFFE6EDF3 : 0xFF1F2933;
      expect(polys[0].color, Color(fill).withValues(alpha: 0.16));
      expect(polys[1].color, Color(fill).withValues(alpha: 0.28));
      expect(polys[0].borderColor, Color(edge));
      expect(polys[0].borderStrokeWidth, 1);
      expect(polys[1].borderStrokeWidth, 2);
      expect(polys[0].pattern, StrokePattern.dashed(segments: [2, 2]));
      expect(polys[1].pattern, StrokePattern.dashed(segments: [4, 4]), reason: 'the dash scales with the edge width');
      expect(find.byType(CircleLayer), findsNothing);
    });
  }

  test('the circle has the radius of the zone', () {
    final pts = zoneCirclePoints(40, -83, 500);
    for (final p in pts) {
      expect(distanceM(40, -83, p.latitude, p.longitude), closeTo(500, 1));
    }
  });

  testWidgets('without tool style the editor keeps its build 73 circles in theme colours', (t) async {
    late ThemeData theme;
    await t.pumpWidget(MaterialApp(
      home: Builder(builder: (context) {
        theme = Theme.of(context);
        return SizedBox(
          width: 300,
          height: 300,
          child: FlutterMap(
            options: const MapOptions(initialCenter: LatLng(40, -83), initialZoom: 13),
            children: [ZoneLayer(zones: zones, selected: 0, fallback: ZoneFallback.of(theme), definition: MapDefinition.bundled)],
          ),
        );
      }),
    ));
    expect(find.byType(PolygonLayer), findsNothing);
    final c = t.widget<CircleLayer>(find.byType(CircleLayer)).circles;
    expect(c[0].color, theme.colorScheme.primary.withValues(alpha: 0.30));
    expect(c[0].borderStrokeWidth, 3);
    expect(c[1].color, theme.colorScheme.tertiary.withValues(alpha: 0.18));
    expect(c[1].borderStrokeWidth, 2);
    expect(c[1].borderColor, theme.colorScheme.tertiary);
    expect(c[1].useRadiusInMeter, isTrue);
  });

  testWidgets('without tool style and no fallback (the drive report) nothing is drawn', (t) async {
    await pumpMap(t, ZoneLayer(zones: zones, definition: MapDefinition.bundled), Brightness.light);
    expect(find.byType(PolygonLayer), findsNothing);
    expect(find.byType(CircleLayer), findsNothing);
  });

  testWidgets('the handle: definition colours (selected = move fill), else the theme avatar of build 73', (t) async {
    final def = liveToolDefinition();
    late ThemeData th;
    Widget pin(bool sel, MapDefinition d, Brightness b) => MaterialApp(
          theme: ThemeData(brightness: b),
          home: Builder(builder: (context) {
            th = Theme.of(context);
            return ZonePin(index: 1, selected: sel, fallback: ZoneFallback.of(th), definition: d);
          }),
        );
    await t.pumpWidget(pin(false, def, Brightness.light));
    var box = t.widget<Container>(find.byType(Container)).decoration as BoxDecoration;
    expect(box.color, const Color(0xFFFFFFFF));
    expect(find.text('2'), findsOneWidget);
    await t.pumpWidget(pin(true, def, Brightness.dark));
    await t.pumpAndSettle();
    box = t.widget<Container>(find.byType(Container)).decoration as BoxDecoration;
    expect(box.color, const Color(0xFFE6EDF3));
    await t.pumpWidget(pin(true, MapDefinition.bundled, Brightness.light));
    expect(find.byType(CircleAvatar), findsOneWidget);
    expect(t.widget<CircleAvatar>(find.byType(CircleAvatar)).backgroundColor, th.colorScheme.primary);
  });

  DrivePing p(int i, double lat) => DrivePing(id: 'p$i', ts: DateTime.utc(2026, 11, 22, 12, 0, i), lat: lat, lon: -83.0, echoes: const []);

  test('hiddenRuns: the runs a zone hides, joined to the visible pings on each side; a lone ping has no line', () {
    final gate = PrivacyZones(const [PrivacyZone(lat: 40.0, lon: -83.0, radiusM: 300)]);
    final pings = [p(0, 40.02), p(1, 40.001), p(2, 40.0), p(3, 40.02), p(4, 40.0005), p(5, 40.02)];
    final runs = hiddenRuns(pings, gate);
    expect(runs, hasLength(2));
    expect(runs[0], [LatLng(40.02, -83), LatLng(40.001, -83), LatLng(40.0, -83), LatLng(40.02, -83)]);
    expect(runs[1], [LatLng(40.02, -83), LatLng(40.0005, -83), LatLng(40.02, -83)]);
    expect(hiddenRuns([p(0, 40.0)], gate), isEmpty);
    expect(hiddenRuns(pings, const PrivacyZones([])), isEmpty);
  });

  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('${b.name}: the hidden part is the definition\'s faded dashed line', (t) async {
      await pumpMap(t, HiddenTrackLayer(runs: [[LatLng(40, -83), LatLng(40.01, -83)]], definition: liveToolDefinition()), b);
      final l = t.widget<PolylineLayer>(find.byType(PolylineLayer)).polylines.single;
      expect(l.color, Color(b == Brightness.dark ? 0xFF94A3B8 : 0xFF64748B).withValues(alpha: 0.6));
      expect(l.strokeWidth, 2);
      expect(l.pattern, StrokePattern.dashed(segments: [2, 4]));
    });
  }

  testWidgets('the hidden part without tool style is not drawn', (t) async {
    await pumpMap(t, HiddenTrackLayer(runs: [[LatLng(40, -83), LatLng(40.01, -83)]], definition: MapDefinition.bundled), Brightness.light);
    expect(find.byType(PolylineLayer), findsNothing);
  });
}
