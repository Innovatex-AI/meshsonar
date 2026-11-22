// MAP slice 6 (app half): the drive detail map draws the drive key, the reader's saved basemap, the `drive-detail` preset's layers, the
// privacy zones and the part of the drive they hide; and with the bundled definition (no `pages`, no `symbols.tools`) it draws what build 73 did.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/drive_detail_map.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';

import '../support/tool_definition.dart';
import 'fakes.dart';

DrivePing at(String id, double lat, int sec) => DrivePing(id: id, ts: DateTime.utc(2026, 10, 16, 18, 0, sec), lat: lat, lon: -82.93, echoes: const []);

void main() {
  group('driveDetailLayerState', () {
    test('the bundled definition has no preset: null, so build 73 keeps its default layers', () {
      expect(driveDetailLayerState(MapDefinition.bundled), isNull);
    });

    test('the live preset: its layers on, the other definition layers off, the app extras kept', () {
      final d = liveToolDefinition();
      final s = driveDetailLayerState(d)!;
      for (final on in ['borders', 'hexes', 'repeaters', 'pings', 'heard']) {
        expect(s.isOn(on), isTrue, reason: on);
      }
      for (final off in ['measured', 'predicted', 'heardcells', 'estimated', 'observers', 'phones', 'links', 'labels']) {
        expect(s.isOn(off), isFalse, reason: off);
      }
      expect(s.modeOf('pings'), 'snr');
    });
  });

  Future<Harness> openDetail(WidgetTester tester, MapDefinition def, {String basemap = 'chart', bool zone = true}) async {
    useTallScreen(tester);
    ActiveMapDefinition.notifier.value = def;
    addTearDown(() => ActiveMapDefinition.notifier.value = MapDefinition.bundled);
    final h = Harness()..approveKey();
    h.store.seed(
      DriveSession(id: 'd1', startedAt: DateTime.utc(2026, 10, 16, 18), endedAt: DateTime.utc(2026, 10, 16, 18, 10), label: 'Evening loop', channel: '#wardriving'),
      [at('p1', 40.10, 0), at('p2', 40.11, 10), at('p3', 40.1105, 20), at('p4', 40.12, 30)],
      syncedFirst: 1,
    );
    await h.pumpApp(tester);
    if (zone) await h.state.privacyZones.setZones(const [PrivacyZone(lat: 40.1102, lon: -82.93, radiusM: 200)]);
    await h.state.updateSettings(h.state.settings.copyWith(baseMapStyle: basemap));
    await openDrivesTab(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open-d1')));
    await tester.pumpAndSettle();
    return h;
  }

  testWidgets('live definition: key with the hidden part and the zone, zone circle, dashed hidden line, saved basemap', (tester) async {
    await openDetail(tester, liveToolDefinition(), basemap: 'dark');
    expect(find.byKey(const Key('drive-key')), findsOneWidget);
    expect(find.text('Hidden from the public: faded and dashed'), findsOneWidget);
    expect(find.text('Privacy zone'), findsOneWidget);
    final lines = tester.widgetList<PolylineLayer>(find.byType(PolylineLayer)).expand((l) => l.polylines).where((l) => l.pattern.segments != null);
    expect(lines, hasLength(1), reason: 'one run of pings inside the zone');
    expect(lines.single.strokeWidth, 2);
    final polys = tester.widgetList<PolygonLayer>(find.byType(PolygonLayer)).expand((l) => l.polygons).where((p) => p.pattern.segments != null);
    expect(polys, hasLength(1), reason: 'the zone');
    final map = tester.widget<CoverageMap>(find.byType(CoverageMap));
    expect(map.baseStyle, BaseMapStyle.dark, reason: 'the reader\'s saved basemap');
    expect(map.layerState!.isOn('measured'), isFalse, reason: 'the drive-detail preset');
    expect(map.legend, isNotNull);
  });

  testWidgets('bundled definition: the key names the ping colours, no zone, no hidden line, nothing from the tool style', (tester) async {
    await openDetail(tester, MapDefinition.bundled);
    expect(find.byKey(const Key('drive-key')), findsOneWidget);
    expect(find.byKey(const Key('drive-key-bands')), findsOneWidget);
    expect(find.byKey(const Key('drive-key-hidden')), findsNothing);
    expect(find.byKey(const Key('drive-key-zone')), findsNothing);
    final dashed = tester.widgetList<PolylineLayer>(find.byType(PolylineLayer)).expand((l) => l.polylines).where((l) => l.pattern.segments != null);
    expect(dashed, isEmpty);
    final zones = tester.widgetList<PolygonLayer>(find.byType(PolygonLayer)).expand((l) => l.polygons).where((p) => p.pattern.segments != null);
    expect(zones, isEmpty);
    final map = tester.widget<CoverageMap>(find.byType(CoverageMap));
    expect(map.layerState, isNull, reason: 'no preset: the default layers of build 73');
    expect(map.extraLayers, isEmpty);
  });
}
