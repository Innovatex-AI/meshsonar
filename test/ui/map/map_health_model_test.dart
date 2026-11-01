// "Map and GPS health" on a real DriveMapModel: a drive's fixes feed the puck, the recorder writes a sample every 10 s with the
// frame, puck, camera, tile and layer sections, nothing is written when no drive runs, and the overlay shows the newest sample.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_health.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/map_health_overlay.dart';

import '../fakes.dart';

void main() {
  tearDown(() {
    DriveMapModel.debugFixes = null;
    MapPrefs.shared.healthOverlay = false;
  });

  testWidgets('a drive writes a health sample every 10 s; none outside a drive', (t) async {
    DriveMapModel.debugFixes = (s) => s.activeLocation.fixes;
    final h = Harness()..approveKey();
    await h.state.init();
    final sink = MemoryHealthSink();
    final model = DriveMapModel(h.state, healthSink: sink);
    addTearDown(model.dispose);
    expect(model.health.running, isFalse);

    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await t.pump();
    expect(model.health.running, isTrue);

    var sec = 0;
    GeoFix fix() => GeoFix(lat: 40.126 + sec * 0.0001, lon: -82.93, at: h.clockNow, accuracyM: 6, speedMps: 11, courseDeg: 0);
    for (; sec < 25; sec++) {
      h.clockNow = h.clockNow.add(const Duration(seconds: 1));
      h.location.fixController.add(fix());
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(sink.records.length, 2, reason: '25 s = two 10 s windows');
    final rec = sink.records.first;
    expect(rec['kind'], 'map_health');
    expect(rec.keys, containsAll(['frames', 'puck', 'camera', 'tiles', 'layers', 'window_s', 't']));
    expect((rec['puck'] as Map)['fixes'], 10);
    expect((rec['tiles'] as Map).containsKey('cache_hit'), isTrue);
    expect(model.puck.pose, isNotNull);

    await h.state.stopDrive();
    await t.pump();
    expect(model.health.running, isFalse);
    final n = sink.records.length;
    h.location.fixController.add(fix());
    await t.pump();
    expect(sink.records.length, n, reason: 'no drive, no samples');
    await t.pump(const Duration(seconds: 15));
  });

  testWidgets('the overlay is off by default, shows the newest sample when switched on', (t) async {
    final h = Harness();
    await h.state.init();
    final model = DriveMapModel(h.state, healthSink: MemoryHealthSink());
    addTearDown(model.dispose);
    await t.pumpWidget(MaterialApp(home: Scaffold(body: MapHealthOverlay(model: model))));
    expect(find.byKey(const Key('map-health-overlay')), findsNothing);
    MapPrefs.shared.healthOverlay = true;
    await t.pump();
    expect(find.textContaining('waiting for the first'), findsOneWidget);
    model.health.last = {
      'frames': {'p95_ms': 6.5, 'worst_ms': 21.0, 'janky_16': 3},
      'puck': {'puck_updates_hz': 59.9, 'fixes': 10, 'max_fix_gap_s': 1.2},
      'camera': {'mode': 'follow', 'heading_up': false},
      'tiles': {'source': 'online', 'network_ok': 4, 'cache_hit': 9, 'failed': 0},
    };
    model.healthTick.value++;
    await t.pump();
    expect(find.textContaining('p95 6.5 ms'), findsOneWidget);
    expect(find.textContaining('puck 59.9 Hz'), findsOneWidget);
    expect(find.textContaining('tiles online'), findsOneWidget);
  });
}
