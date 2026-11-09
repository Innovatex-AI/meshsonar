// Contract section 8.5 / coverage-v2-api-contract.md "Heard layer" / coverage-v2-colours.md "Heard": the Heard-by-phones
// layer in the app. Meta switch and heardVersion, the inspector's heard block, outline-only styles with ring dots, website
// `show=heard` <-> app `heardcells`, and the layer drawing heard tiles between predicted and measured.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/coverage_v2.dart';
import 'package:meshsonar/core/map_view_state.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/coverage_tiles_layer.dart';

Map<String, dynamic> _json(String n) => jsonDecode(File('test/fixtures/coverage_v2/$n').readAsStringSync()) as Map<String, dynamic>;

void main() {
  final base = _json('meta.json');

  test('meta: heard is on when tiles.layers lists it; heard tiles carry heardVersion, the others version', () {
    final off = CoverageMeta.fromJson(base);
    expect(off.heard, isFalse);
    final on = CoverageMeta.fromJson({
      ...base,
      'tiles': {...(base['tiles'] as Map), 'layers': ['measured', 'predicted', 'heard']},
      'heardVersion': 42,
      'heardCells': 7,
    });
    expect(on.heard, isTrue);
    expect(on.heardCells, 7);
    expect(on.versionFor(CoverageTileLayer.heard), 42);
    expect(on.versionFor(CoverageTileLayer.measured), on.version);
  });

  test('inspector: the heard block is read (full repeater keys) next to measured or alone', () {
    final key = 'ab' * 32;
    final c = CoverageCellInfo.fromJson({
      'h3': '8b2a1072b59afff',
      'preset': 'sf7bw62.5',
      'heard': {'band': 4, 'n': 9, 'r': 2, 'snrMean': 4.25, 'snrMax': 8.5, 'lastAt': '2026-11-09T12:00:00Z',
        'repeaters': [{'key': key.toUpperCase(), 'n': 6, 'snrMean': 5.0, 'snrMax': 8.5}]},
    });
    expect(c.isEmpty, isFalse);
    expect(c.measured, isNull);
    expect(c.heard!.band, 4);
    expect(c.heard!.r, 2);
    expect(c.heard!.repeaters.single.key, key);
  });

  test('styles: never a fill; a 1.6 px outline at 0.9; zoomed out a hollow ring (stroke 1.2) at 0.85', () {
    final c = CoverageBandColors.of(ColourPalette.standard, Brightness.light);
    final s = heardStyles(c);
    expect(s, hasLength(7));
    for (var b = 1; b <= 6; b++) {
      expect(s[b].fill.a, 0, reason: 'band $b: heard is not a measurement, never filled');
      expect(s[b].borderWidth, 1.6);
      expect(s[b].border.a, closeTo(0.9, 0.01));
      expect(s[b].dotRing, 1.2);
      expect(s[b].dot!.a, closeTo(0.85, 0.01));
    }
    expect(kHeardDotPx, 4.4, reason: 'ring radius 2.2');
  });

  test('links: website show=heard is the app Heard-by-phones layer; app links keep heard = Heard this drive', () {
    final web = MapViewState.fromUri(Uri.parse('https://cmh.meshsonar.com/coverage?show=measured,heard'))!;
    expect(web.show, containsAll(['measured', kHeardCellsLayerId]));
    expect(web.show, isNot(contains('heard')));
    expect(web.toParameters(web: true)['show'], 'measured,heard');
    final app = MapViewState.fromUri(Uri.parse('meshsonar://map?show=heard,heardcells'))!;
    expect(app.show, containsAll(['heard', kHeardCellsLayerId]));
    expect(app.toParameters(web: false)['show'], contains('heardcells'));
  });

  testWidgets('the layer draws heard tiles (keyed by heardVersion)', (t) async {
    final meta = CoverageMeta.fromJson({
      ...base,
      'tiles': {...(base['tiles'] as Map), 'layers': ['measured', 'predicted', 'heard']},
      'heardVersion': 5,
    });
    final store = CoverageTileStore(CoverageV2Client(Uri.parse('https://x.test')), decode: (b, l, z, x, y) async => decodeCoverageTile(b, l, z, x, y));
    final bytes = File('test/fixtures/coverage_v2/measured-13-2207-3102.mvt').readAsBytesSync();
    // A measured fixture tile stands in for a heard one: same geometry and properties, decoded as the measured layer.
    final d = decodeCoverageTile(bytes, CoverageTileLayer.measured, 13, 2207, 3102);
    expect(d.length, greaterThan(0));
    store.debugPut(coverageTileKey(CoverageTileLayer.heard, meta.defaultPreset, 5, 13, 2207, 3102), d);
    var lat = 0.0, lon = 0.0;
    for (var v = d.starts[0]; v < d.starts[1]; v++) {
      lat += d.latLon[2 * v] / (d.starts[1] - d.starts[0]);
      lon += d.latLon[2 * v + 1] / (d.starts[1] - d.starts[0]);
    }
    t.view.physicalSize = const Size(400, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: FlutterMap(
        options: MapOptions(initialCenter: LatLng(lat, lon), initialZoom: 13.5),
        children: [
          CoverageTilesLayer(layer: CoverageTileLayer.heard, store: store, meta: meta, colors: CoverageBandColors.of(ColourPalette.standard, Brightness.dark)),
        ],
      ),
    ));
    await t.pump();
    expect(t.state<CoverageTilesLayerState>(find.byType(CoverageTilesLayer)).cellCount, d.length);
    expect(find.byKey(const ValueKey('coverage-tiles-heard')), findsOneWidget);
    expect(coverageTileHit(store, CoverageTileLayer.heard, meta, lat, lon, 13), isNotNull, reason: 'a tap opens the inspector');
  });
}
