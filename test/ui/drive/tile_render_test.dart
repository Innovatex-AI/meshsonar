// Real tile pixels on the real Drive screen (raster Topo since M2; Chart / Light / Dark are our vector basemap, rendered and
// checked in test/ui/map/basemap_styles_test.dart and on the simulator): serves real OpenTopoMap tiles (fetched once into TILE_DIR, default
// <system temp>/meshsonar-tiles; any z/x/y gets the nearest real tile so the camera position does not matter), renders the Drive screen
// at 393x852 for every base style and writes PNGs to TILE_OUT. Asserts the map area shows tile colours (not a flat fill).
// Without real tiles in TILE_DIR every test returns at once (nothing to render), like the other environment-dependent tests.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_map/flutter_map.dart' show TileLayer;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart' show BasemapLayer;
import 'package:meshsonar/ui/map/coverage_map.dart';

import '../fakes.dart';

final _tmp = Directory.systemTemp.path;
final tileDir = Platform.environment['TILE_DIR'] ?? '$_tmp/meshsonar-tiles';
String cacheDir = '';
final outDir = Platform.environment['TILE_OUT'] ?? '$_tmp/meshsonar-tilepng';

File? tileFor(String kind) {
  if (!Directory(tileDir).existsSync()) return null;
  final files = Directory(tileDir).listSync().whereType<File>().where((f) => f.path.contains('/${kind}_14_') && f.lengthSync() > 2000).toList()..sort((a, b) => a.path.compareTo(b.path));
  return files.isEmpty ? null : files[files.length ~/ 2];
}

void main() {
  final key = GlobalKey();
  for (final style in ['topo']) {
    testWidgets('inside the real app shell: $style', (tester) async {
      final osm = tileFor('osm');
      if (osm == null) return;
      cacheDir = '$_tmp/meshsonar-tilecache-${DateTime.now().microsecondsSinceEpoch}';
      final m = tester.binding.defaultBinaryMessenger;
      m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async {
        Directory(cacheDir).createSync(recursive: true);
        return cacheDir;
      });
      m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (c) async => ['wifi']);
      m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (c) async => null);
    for (final n in ['method', 'accelerometer', 'gyroscope', 'magnetometer', 'user_accel']) {
      m.setMockMethodCallHandler(MethodChannel('dev.fluttercommunity.plus/sensors/$n'), (c) async => null);
    }
      for (final n in ['method', 'accelerometer', 'gyroscope', 'magnetometer', 'user_accel']) {
        m.setMockMethodCallHandler(MethodChannel('dev.fluttercommunity.plus/sensors/$n'), (c) async => null);
      }
      CoverageMap.tilesByDefault = true;
      addTearDown(() => CoverageMap.tilesByDefault = false);
      CoverageMap.debugTileClient = MockClient((req) async => http.Response.bytes(osm.readAsBytesSync(), 200, headers: {'content-type': 'image/png'}));
      addTearDown(() => CoverageMap.debugTileClient = null);
      AppFlags.driveRedesign = true;
      addTearDown(() => AppFlags.driveRedesign = false);
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 47, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 47, bottom: 34);
      addTearDown(tester.view.reset);
      final h = Harness();
      await h.state.init();
      await h.state.updateSettings(h.state.settings.copyWith(baseMapStyle: style));
      await tester.pumpWidget(RepaintBoundary(key: key, child: MeshSonarApp(state: h.state)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 3)));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      }
      await tester.runAsync(() async {
        final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        Directory(outDir).createSync(recursive: true);
        File('$outDir/shell-$style.png').writeAsBytesSync(data.buffer.asUint8List());
      });
      await tester.pump(const Duration(seconds: 25));
    });
  }

  testWidgets('switching the base map from the layers sheet changes the tiles', (tester) async {
    final osm = tileFor('osm'), topo = tileFor('topo');
    if (osm == null || topo == null) return;
    cacheDir = '$_tmp/meshsonar-tilecache-${DateTime.now().microsecondsSinceEpoch}';
      final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async {
      Directory(cacheDir).createSync(recursive: true);
      return cacheDir;
    });
    m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (c) async => ['wifi']);
    m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (c) async => null);
      for (final n in ['method', 'accelerometer', 'gyroscope', 'magnetometer', 'user_accel']) {
        m.setMockMethodCallHandler(MethodChannel('dev.fluttercommunity.plus/sensors/$n'), (c) async => null);
      }
    CoverageMap.tilesByDefault = true;
    addTearDown(() => CoverageMap.tilesByDefault = false);
    final urls = <String>[];
    CoverageMap.debugTileClient = MockClient((req) async {
      urls.add(req.url.host);
      final f = req.url.host.contains('opentopomap') ? topo : osm;
      return http.Response.bytes(f.readAsBytesSync(), 200, headers: {'content-type': 'image/png'});
    });
    addTearDown(() => CoverageMap.debugTileClient = null);
    AppFlags.driveRedesign = true;
    addTearDown(() => AppFlags.driveRedesign = false);
    const size = Size(393, 852);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = Harness();
    await h.state.init();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await tester.pumpWidget(AppScope(
      state: h.state,
      child: MaterialApp(
        home: RepaintBoundary(
          key: key,
          child: MediaQuery(
            data: const MediaQueryData(size: size, padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
            child: const DriveScreen(),
          ),
        ),
      ),
    ));
    Future<void> settle() async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      }
    }

    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 5)));
    await settle();
    await settle();
    expect(find.byType(BasemapLayer), findsOneWidget, reason: 'Chart is our vector basemap');
    expect(find.byType(TileLayer), findsNothing);
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await settle();
    final swatch = find.byKey(const Key('base-map-topo'));
    debugPrint('SWATCH found=${swatch.evaluate().length}');
    if (swatch.evaluate().isEmpty) {
      await tester.drag(find.byType(Scrollable).last, const Offset(0, -300));
      await settle();
    }
    expect(swatch, findsOneWidget);
    await tester.ensureVisible(swatch);
    await tester.tap(swatch, warnIfMissed: false);
    await settle();
    debugPrint('SWITCH style=${h.state.settings.baseMapStyle} hosts=${urls.toSet()}');
    expect(h.state.settings.baseMapStyle, 'topo');
    expect(tester.widget<TileLayer>(find.byType(TileLayer)).urlTemplate, contains('opentopomap'), reason: 'the map draws topo tiles after the swatch is tapped');
    await tester.runAsync(() async {
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      Directory(outDir).createSync(recursive: true);
      File('$outDir/after-switch-topo.png').writeAsBytesSync(data.buffer.asUint8List());
    });
    await tester.pump(const Duration(seconds: 25));
  });

  for (final style in ['topo']) {
    for (final state in ['idle']) {
      testWidgets('tiles visible: $style $state', (tester) async {
        final osm = tileFor('osm'), topo = tileFor('topo');
        if (osm == null || topo == null) {
          markTestSkipped('no tiles in $tileDir');
          return;
        }
        cacheDir = '$_tmp/meshsonar-tilecache-${DateTime.now().microsecondsSinceEpoch}';
      final m = tester.binding.defaultBinaryMessenger;
        m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async {
          Directory(cacheDir).createSync(recursive: true);
          return cacheDir;
        });
        m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (c) async => ['wifi']);
        m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (c) async => null);
      for (final n in ['method', 'accelerometer', 'gyroscope', 'magnetometer', 'user_accel']) {
        m.setMockMethodCallHandler(MethodChannel('dev.fluttercommunity.plus/sensors/$n'), (c) async => null);
      }
        CoverageMap.tilesByDefault = true;
        addTearDown(() => CoverageMap.tilesByDefault = false);
        var requests = 0;
        CoverageMap.debugTileClient = MockClient((req) async {
          requests++;
          final f = req.url.host.contains('opentopomap') ? topo : osm;
          return http.Response.bytes(f.readAsBytesSync(), 200, headers: {'content-type': 'image/png'});
        });
        addTearDown(() => CoverageMap.debugTileClient = null);
        AppFlags.driveRedesign = true;
        addTearDown(() => AppFlags.driveRedesign = false);
        const size = Size(393, 852);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final h = Harness();
        await h.state.init();
        await h.state.updateSettings(h.state.settings.copyWith(baseMapStyle: style));
        await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
        if (state == 'driving') await h.state.startDrive();
        await tester.pumpWidget(AppScope(
          state: h.state,
          child: MaterialApp(
            home: RepaintBoundary(
              key: key,
              child: MediaQuery(
                data: const MediaQueryData(size: size, padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
                child: const DriveScreen(),
              ),
            ),
          ),
        ));
        await tester.runAsync(() => Future<void>.delayed(const Duration(seconds: 6)));
        for (var i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
        }
        await tester.runAsync(() async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final image = await boundary.toImage();
          final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          Directory(outDir).createSync(recursive: true);
          File('$outDir/$style-$state.png').writeAsBytesSync(data.buffer.asUint8List());
          // Colours in the map area (above the panel), 8 px grid.
          final raw = (await image.toByteData())!;
          final colours = <int>{};
          for (var y = 100; y < 600; y += 8) {
            for (var x = 0; x < 393; x += 8) {
              final o = (y * 393 + x) * 4;
              colours.add((raw.getUint8(o) >> 4) << 8 | (raw.getUint8(o + 1) >> 4) << 4 | (raw.getUint8(o + 2) >> 4));
            }
          }
          debugPrint('TILECOLOURS $style $state ${colours.length}');
          expect(requests, lessThanOrEqualTo(26), reason: 'a phone-size map asks for the viewport only, not a ring of pre-load tiles');
          expect(colours.length, greaterThan(35), reason: '$style $state: the map area shows tile colours, not a flat fill');
        });
        if (h.state.driving) await h.state.stopDrive();
        await tester.pump(const Duration(seconds: 25));
      });
    }
  }
}
