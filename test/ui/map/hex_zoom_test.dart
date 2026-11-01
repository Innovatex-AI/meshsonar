// The live drive's hexagons follow the map zoom, with the same table as the network layer (Andy's test drive: the grid
// did not match the zoom).
import 'dart:io';

import 'package:flutter/material.dart' hide Radio;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';
import 'package:h3_ffi/h3_ffi.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/theme.dart';


H3? _load() {
  for (final path in const ['/opt/homebrew/lib/libh3.dylib', '/usr/local/lib/libh3.dylib', 'libh3.so']) {
    if (path.startsWith('/') && !File(path).existsSync()) continue;
    try {
      return const H3FfiFactory().byPath(path);
    } catch (_) {}
  }
  return null;
}

void main() {
  final h3 = _load();
  final skip = h3 == null; // libh3 not found (brew install h3)

  final pings = [
    for (var i = 0; i < 6; i++) DrivePing(id: 'p$i', ts: DateTime.utc(2026, 10, 16, 18, 0, i), lat: 40.126 + i * 0.002, lon: -82.93 + i * 0.002, echoes: const [Echo(repeater: 'a1b2', snrDb: 3)]),
  ];

  Future<void> pump(WidgetTester tester, {int? hexRes, double width = 600}) async {
    CoverageMap.hexEngine = h3;
    addTearDown(() => CoverageMap.hexEngine = null);
    await tester.pumpWidget(
      MaterialApp(
        theme: meshSonarTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              height: 600,
              child: CoverageMap(pings: pings, position: const LatLng(40.13, -82.925), hexRes: hexRes),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
  }

  int polygons(WidgetTester tester) {
    final f = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('drive-hexes-res-'));
    return (tester.widget<KeyedSubtree>(f).child as CellRasterLayer).data.shapes.length;
  }

  String resKey(WidgetTester tester) => find
      .byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('drive-hexes-res-'))
      .evaluate()
      .map((e) => (e.widget.key as ValueKey).value.toString())
      .single;

  testWidgets('opens at the resolution of its opening zoom (13.6 -> res 9)', (tester) async {
    await pump(tester);
    expect(resKey(tester), 'drive-hexes-res-${coverageResForZoom(13.6)}');
    expect(resKey(tester), 'drive-hexes-res-9');
  }, skip: skip);

  testWidgets('zooming in redraws the drive hexagons finer (res 9 -> 10 across the band edge)', (tester) async {
    await pump(tester);
    final coarse = polygons(tester);
    expect(resKey(tester), 'drive-hexes-res-9');

    // Double tap = +1 zoom: 13.6 -> 14.6 crosses the 14 band edge, res 9 -> 10.
    await tester.tapAt(const Offset(150, 150));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(150, 150));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(resKey(tester), 'drive-hexes-res-10');
    expect(polygons(tester), greaterThanOrEqualTo(coarse), reason: 'finer hexagons, never fewer for the same pings');
  }, skip: skip);

  testWidgets('a pinned resolution overrides the zoom', (tester) async {
    await pump(tester, hexRes: 7);
    expect(resKey(tester), 'drive-hexes-res-7');
    await pump(tester, hexRes: 11);
    expect(resKey(tester), 'drive-hexes-res-11');
  }, skip: skip);
}
