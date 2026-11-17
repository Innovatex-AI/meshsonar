// Build 70 battery plan, the UI slice: A1 the wakelock follows PowerProfile.current.screenOn (always / Drive tab only / never),
// A5 the drive UI 1 s clocks run only while a drive is running, visible and in front (DockHero and PingCircle have none with no
// drive), A3 the puck frame cap, A14 the speed-zoom bands, A4 AppState no longer notifies on every position-only engine tick, and
// the simple basemap while driving.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart' show RadioKind;
import 'package:meshsonar/core/camera_follow.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/device_feedback.dart';
import 'package:meshsonar/ui/drive/drive_clock.dart';
import 'package:meshsonar/ui/drive/panel/panel_dock.dart';
import 'package:meshsonar/ui/map/basemap_layer.dart' show simpleBasemapNow;
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/live_puck.dart' show puckFrameCap;
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';

import '../fakes.dart';

class _Feedback implements DeviceFeedback {
  final List<bool> awake = [];
  @override
  Future<void> keepAwake(bool on) async => awake.add(on);
  @override
  Future<void> pingResult({required bool heard}) async {}
}

Future<void> _pump(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

bool _clock(WidgetTester tester, Type t) => (tester.state(find.byType(t, skipOffstage: false)) as DriveClock).clockRunning;

void main() {
  late _Feedback fb;
  setUp(() {
    fb = _Feedback();
    DeviceFeedbackScope.fallback = fb;
    PowerProfile.debugReset();
  });
  tearDown(() {
    DeviceFeedbackScope.fallback = const NoDeviceFeedback();
    PowerProfile.debugReset();
  });

  Future<Harness> driving(WidgetTester tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    await _pump(tester);
    return h;
  }

  Future<void> stop(WidgetTester tester, Harness h) async {
    if (h.state.driving) await h.state.stopDrive();
    await tester.pump(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
  }

  group('A1 wakelock', () {
    testWidgets('Balanced (Drive tab only): awake on the Drive tab, released on another tab and in the background, back on return', (tester) async {
      expect(PowerProfile.current.screenOn, ScreenOnMode.driveTabOnly);
      final h = await driving(tester);
      expect(fb.awake, [true]);
      await tapShellTab(tester, 'Chat');
      expect(fb.awake, [true, false], reason: 'another tab: the screen may sleep');
      await tapShellTab(tester, 'Drive');
      expect(fb.awake, [true, false, true]);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _pump(tester);
      expect(fb.awake.last, isFalse, reason: 'in the background');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pump(tester);
      expect(fb.awake.last, isTrue);
      await h.state.stopDrive();
      await _pump(tester);
      expect(fb.awake.last, isFalse, reason: 'no drive, no wakelock');
      expect(PowerCounters.get(PowerCounters.screenOnSeconds), greaterThanOrEqualTo(0));
      await stop(tester, h);
    });

    testWidgets('Max data (always): stays awake on another tab during a drive', (tester) async {
      PowerProfile.debugReset(PowerSettings.maxData);
      final h = await driving(tester);
      await tapShellTab(tester, 'Chat');
      expect(fb.awake, [true]);
      await stop(tester, h);
      expect(fb.awake, [true, false]);
    });

    testWidgets('Saver (never): no wakelock even on the Drive tab; switching to Balanced mid-drive takes it', (tester) async {
      PowerProfile.debugReset(PowerSettings.saver);
      final h = await driving(tester);
      expect(fb.awake, isEmpty);
      await PowerProfile.set(PowerSettings.balanced);
      await _pump(tester);
      expect(fb.awake, [true]);
      await stop(tester, h);
    });
  });

  group('A5 drive clocks', () {
    testWidgets('no drive: DockHero and PingCircle have no timer (they are not even built)', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await _pump(tester);
      expect(find.byType(DockHero, skipOffstage: false), findsNothing);
      expect(find.byType(PingCircle, skipOffstage: false), findsNothing);
      await stop(tester, h);
    });

    testWidgets('driving: the clocks run on the Drive tab, stop on another tab and in the background, restart on return', (tester) async {
      final h = await driving(tester);
      expect(_clock(tester, DockHero), isTrue);
      expect(_clock(tester, PingCircle), isTrue);
      await tapShellTab(tester, 'Chat');
      expect(_clock(tester, DockHero), isFalse, reason: 'Drive tab hidden');
      expect(_clock(tester, PingCircle), isFalse);
      expect(_clock(tester, MiniDriveBar), isTrue, reason: 'the mini bar is what shows now');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _pump(tester);
      expect(_clock(tester, MiniDriveBar), isFalse, reason: 'background');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _pump(tester);
      expect(_clock(tester, MiniDriveBar), isTrue);
      await tapShellTab(tester, 'Drive');
      expect(_clock(tester, DockHero), isTrue);
      expect(_clock(tester, PingCircle), isTrue);
      await stop(tester, h);
    });
  });

  group('A4 notifications', () {
    testWidgets('position-only engine ticks notify AppState at most every 2 s; driveStatus gets every one', (tester) async {
      final h = await driving(tester);
      var notes = 0, ticks = 0;
      void onState() => notes++;
      void onStatus() => ticks++;
      h.state.addListener(onState);
      h.state.driveStatus.addListener(onStatus);
      addTearDown(() => h.state.removeListener(onState));
      final engine = h.engines.single;
      EngineStatus at(int i) => EngineStatus(EngineState.driving, lastFix: GeoFix(lat: 40.1 + i * 0.0001, lon: -82.9, at: h.clockNow, accuracyM: 5));
      engine.setStatus(at(0));
      await tester.pump(const Duration(milliseconds: 10));
      notes = 0;
      ticks = 0;
      // Ten fixes 0.5 s apart (5 s): every one reaches driveStatus, AppState hears about two or three of them.
      for (var i = 1; i <= 10; i++) {
        h.clockNow = h.clockNow.add(const Duration(milliseconds: 500));
        engine.setStatus(at(i));
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(ticks, 10);
      expect(notes, inInclusiveRange(2, 3));
      expect(h.state.status.lastFix!.lat, closeTo(40.101, 1e-9), reason: 'status is always the newest');
      // A real change (a ping starts) is told at once.
      notes = 0;
      engine.setStatus(EngineStatus(EngineState.pinging, lastFix: at(10).lastFix));
      await tester.pump(const Duration(milliseconds: 10));
      expect(notes, greaterThanOrEqualTo(1));
      engine.setStatus(at(11));
      await tester.pump(const Duration(milliseconds: 10));
      h.state.driveStatus.removeListener(onStatus);
      await stop(tester, h);
    });
  });

  test('A3 frame cap: the profile fps, at most 30 while only the heading turns', () {
    expect(puckFrameCap(120), 120);
    expect(puckFrameCap(60), 60);
    expect(puckFrameCap(30), 30);
    expect(puckFrameCap(120, headingOnly: true), 30);
    expect(puckFrameCap(0), 60);
  });

  test('A14 speed zoom snaps to three bands and lands exactly on them', () {
    final bands = {for (var v = 0.0; v <= 40; v += 0.5) speedZoomBand(v)};
    expect(bands, {0.0, -0.65, -1.3});
    expect(speedZoomBand(5), 0);
    expect(speedZoomBand(40), closeTo(-1.3, 1e-9));
    var z = 0.0;
    for (var i = 0; i < 200; i++) {
      z = easeTowardSnapped(z, -0.65, 0.1, 1.5);
    }
    expect(z, -0.65, reason: 'the eased zoom stops changing');
  });

  testWidgets('simple basemap: Saver while driving draws the map with no basemap tiles', (tester) async {
    expect(simpleBasemapNow(driving: true), isFalse, reason: 'Balanced keeps the basemap');
    PowerProfile.debugReset(PowerSettings.saver);
    expect(simpleBasemapNow(driving: false), isFalse, reason: 'only while driving');
    expect(simpleBasemapNow(driving: true), isTrue);
    final h = await driving(tester);
    expect(tester.widget<CoverageMap>(find.byType(CoverageMap)).plainBasemap, isTrue);
    await h.state.stopDrive();
    await _pump(tester);
    expect(tester.widget<CoverageMap>(find.byType(CoverageMap)).plainBasemap, isFalse);
    await stop(tester, h);
  });
}
