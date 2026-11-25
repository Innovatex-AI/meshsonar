// Regression (build 76, a tester's iPhone): "street maps go away when they start a drive".
// Cause: iPhone Low Power Mode made the power profile Saver (Settings > Battery, "Follow Low Power Mode", on by default), Saver
// turned "Simple basemap while driving" on, and the Drive map then left every basemap layer out the moment a drive started.
// Rule now (Andy): the streets never go away when a drive starts. The knob, the preset field and the swap are removed.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart' show BasemapLayer;
import 'package:meshsonar/ui/map/coverage_map.dart';

import '../fakes.dart';

Future<void> _pump(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The street basemap layer on the Drive map: its key names the style ('basemap-chart', 'basemap-dark', ...).
Key? _basemapKey(WidgetTester tester) {
  final f = find.descendant(of: find.byKey(const Key('drive-map')), matching: find.byType(BasemapLayer));
  return f.evaluate().isEmpty ? null : tester.widget<BasemapLayer>(f).key;
}

void main() {
  setUp(PowerProfile.debugReset);
  tearDown(PowerProfile.debugReset);

  Future<Harness> app(WidgetTester tester) async {
    final cache = Directory.systemTemp.createTempSync('ms-keeps-basemap');
    addTearDown(() => cache.deleteSync(recursive: true));
    final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (c) async => cache.path);
    m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'), (c) async => ['wifi']);
    m.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity_status'), (c) async => null);
    for (final n in ['method', 'accelerometer', 'gyroscope', 'magnetometer', 'user_accel']) {
      m.setMockMethodCallHandler(MethodChannel('dev.fluttercommunity.plus/sensors/$n'), (c) async => null);
    }
    // The real basemap layers are built (as on a phone); every tile request gets the server's "nothing here".
    CoverageMap.tilesByDefault = true;
    addTearDown(() => CoverageMap.tilesByDefault = false);
    CoverageMap.debugTileClient = MockClient((req) async => http.Response('', 204));
    addTearDown(() => CoverageMap.debugTileClient = null);
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await _pump(tester);
    return h;
  }

  Future<void> end(WidgetTester tester, Harness h) async {
    if (h.state.driving) await h.state.stopDrive();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
  }

  for (final (name, arrange) in <(String, void Function())>[
    ('default settings', () {}),
    ('iPhone Low Power Mode on', () => PowerProfile.setLowPowerMode(true)),
    ('Saver chosen', () => PowerProfile.debugReset(PowerSettings.saver)),
  ]) {
    testWidgets('starting a drive keeps the same street basemap: $name', (tester) async {
      arrange();
      final h = await app(tester);
      final before = _basemapKey(tester);
      expect(before, const ValueKey('basemap-chart'), reason: 'the street basemap is drawn before the drive');

      await h.state.startDrive();
      await _pump(tester);
      expect(h.state.driving, isTrue);
      expect(_basemapKey(tester), before, reason: 'starting a drive must not drop or change the street basemap');

      await h.state.stopDrive();
      await _pump(tester);
      expect(_basemapKey(tester), before);
      await end(tester, h);
    });
  }

  test('a profile saved by builds 70 to 75 with the old knob still loads, and the knob is gone', () {
    final old = {...PowerSettings.balanced.toJson(), 'mode': 'custom', 'simpleBasemap': true, 'mapFps': 30};
    final s = PowerSettings.fromJson(old);
    expect(s.mode, BatteryMode.custom);
    expect(s.mapFps, 30);
    expect(s.toJson().containsKey('simpleBasemap'), isFalse);
    expect(PowerSettings.saver.toJson().containsKey('simpleBasemap'), isFalse);
  });
}
