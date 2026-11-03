// The Drive panel on the real Drive screen (flag driveRedesign on): panel tops per device, hit zones, drag leaves the map alone,
// MapInsets are written at settle, dock states, Ping debounce, auto-collapse with the Passenger switch, tab bar hook.
import 'dart:async';
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/map/cell_raster_layer.dart';
import 'package:meshsonar/ui/map/core/map_insets.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/overlays/attribution_line.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';

/// Pumps the Drive screen alone at [size] (dpr 1) with the shell's bottom padding [navBar] and the device inset [safeBottom].
Future<Harness> pumpDrive(
  WidgetTester tester, {
  required Size size,
  required double navBar,
  required double safeBottom,
  double safeTop = 47,
  bool connect = false,
  bool drive = false,
  ShellController? shell,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  AppFlags.driveRedesign = true;
  addTearDown(() => AppFlags.driveRedesign = false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness();
  await h.state.init();
  if (connect || drive) await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  if (drive) await h.state.startDrive();
  Widget screen = MediaQuery(
    data: MediaQueryData(
      size: size,
      padding: EdgeInsets.only(top: safeTop, bottom: navBar),
      viewPadding: EdgeInsets.only(top: safeTop, bottom: safeBottom),
      textScaler: TextScaler.linear(textScale),
    ),
    child: const DriveScreen(),
  );
  if (shell != null) screen = ShellScope(controller: shell, child: screen);
  await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(theme: meshSonarTheme(brightness), home: screen)));
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

double panelTop(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;

Future<void> settleAnim(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> end(WidgetTester tester, Harness h) async {
  if (h.state.driving) await h.state.stopDrive();
  await tester.pump(const Duration(seconds: 25));
}

void main() {
  group('panel tops per device (table 4.13), asserted on the built screen', () {
    final devices = <(String, Size, double, double, double, double, double)>[
      // name, size, navBar, safeBottom, dockTop, mediumTop, immersiveTop
      ('402x874', const Size(402, 874), 106, 34, 680, 366, 752),
      ('393x852', const Size(393, 852), 106, 34, 658, 354, 730),
      ('375x667 SE', const Size(375, 667), 49, 0, 530, 285, 579),
    ];
    for (final (name, size, nav, safe, dock, med, imm) in devices) {
      testWidgets('$name: Dock $dock, Medium $med, Immersive $imm; the map keeps its size', (tester) async {
        final h = await pumpDrive(tester, size: size, navBar: nav, safeBottom: safe, drive: true);
        final mapSize = tester.getSize(find.byType(CoverageMap));
        expect(mapSize, size, reason: 'the map is full bleed');
        expect(panelTop(tester), closeTo(dock, 2));
        expect((size.height - panelTop(tester) - nav - 88).abs(), lessThan(2), reason: 'Dock = 88 above the tab bar');
        if (name != '375x667 SE') expect(panelTop(tester) / size.height, greaterThanOrEqualTo(0.77));

        // Tap the grabber: Medium.
        await tester.tapAt(Offset(size.width / 2, panelTop(tester) + 8));
        await settleAnim(tester);
        expect(panelTop(tester), closeTo(med, 2));
        expect(tester.getSize(find.byType(CoverageMap)), mapSize, reason: 'opening the panel does not resize the map');

        // Drag the header down past Dock: Immersive.
        await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 400), 1500);
        await settleAnim(tester);
        expect(panelTop(tester), closeTo(dock, 2));
        await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 120), 1500);
        await settleAnim(tester);
        expect(panelTop(tester), closeTo(imm, 2));
        expect(tester.getSize(find.byType(CoverageMap)), mapSize);
        await end(tester, h);
      });
    }
  });

  testWidgets('hit zones: header >= 44 high, grabber taps toggle, Stop and Ping win over the header', (tester) async {
    final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
    final header = tester.getRect(find.byKey(const Key('drive-panel-header')));
    expect(header.height, greaterThanOrEqualTo(44));
    expect(tester.getRect(find.byKey(const Key('drive-panel-grabber'))).height, lessThan(44), reason: 'the visual is small, the zone is the header');
    for (final k in const ['start-stop', 'ping-now']) {
      final r = tester.getRect(find.byKey(Key(k)));
      expect(r.height, greaterThanOrEqualTo(48), reason: k);
      expect(r.width, greaterThanOrEqualTo(48), reason: k);
    }
    expect(tester.getSize(find.byKey(const Key('ping-now'))), const Size(64, 64));
    expect(tester.getSize(find.byKey(const Key('start-stop'))), const Size(104, 52));

    // A tap on Ping does not toggle the panel.
    await tester.tap(find.byKey(const Key('ping-now')));
    await tester.pump(const Duration(milliseconds: 300));
    expect(panelTop(tester), closeTo(680, 2));
    // A tap on Stop opens the confirmation, not the panel.
    await tester.tap(find.byKey(const Key('start-stop')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const Key('stop-drive-dialog')), findsOneWidget);
    expect(panelTop(tester), closeTo(680, 2));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.byKey(const Key('stop-drive-keep')));
    await tester.pump(const Duration(seconds: 1));
    // A tap on the hero area toggles.
    await tester.tapAt(Offset(40, panelTop(tester) + 50));
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(366, 2));
    await end(tester, h);
  });

  testWidgets('dragging 60 frames lays out the map 0 times and repaints no CellRasterLayer; insets are written once, at settle', (tester) async {
    final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
    final insets = MapInsets.maybeNotifier(tester.element(find.byType(AttributionLine)))!;
    final before = insets.publishCount;
    final insetDock = insets.value.bottom;
    final paints = CellRasterLayer.totalPaints;
    final lines = <String>[];
    final oldPrint = debugPrint;
    debugPrint = (String? m, {int? wrapWidth}) => lines.add(m ?? '');
    debugPrintLayouts = true;
    final ids = <String>{};
    void walk(RenderObject r) {
      ids.add(describeIdentity(r).split('#').last);
      r.visitChildren(walk);
    }
    walk(tester.renderObject(find.byType(CoverageMap)));
    expect(ids.length, greaterThan(5));

    int mapLayouts() => lines.where((l) => l.startsWith('Laying out') && ids.any((id) => l.contains('#$id'))).length;
    // Baseline: 60 idle frames (timers, the puck) -- whatever the map does by itself.
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final idle = mapLayouts();
    lines.clear();
    final g = await tester.startGesture(Offset(200, panelTop(tester) + 10));
    for (var i = 0; i < 60; i++) {
      await g.moveBy(const Offset(0, -4));
      await tester.pump(const Duration(milliseconds: 16));
      expect(insets.publishCount, before, reason: 'no insets per frame (frame $i)');
    }
    expect(mapLayouts(), 0, reason: 'the map subtree is not laid out while the panel moves (idle baseline: $idle)');
    expect(lines.where((l) => l.startsWith('Laying out')), isNotEmpty, reason: 'the panel itself does lay out (the probe works)');
    expect(CellRasterLayer.totalPaints, paints);
    await g.up();
    debugPrintLayouts = false;
    debugPrint = oldPrint;
    await settleAnim(tester);
    expect(insets.publishCount, before + 1, reason: 'one write at settle');
    expect(insets.value.bottom, greaterThanOrEqualTo(874 - panelTop(tester) - 2), reason: 'bottom inset covers the panel');
    expect(insets.value.bottom - insetDock, closeTo(680 - panelTop(tester), 2), reason: 'and moved with the panel top');
    expect(panelTop(tester), closeTo(366, 2));
    expect(CellRasterLayer.totalPaints, paints);
    await end(tester, h);
  });

  testWidgets('collapsing Medium to Dock does not move the map and moves the attribution once', (tester) async {
    final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
    final map = tester.getRect(find.byType(CoverageMap));
    final attrDock = tester.getBottomRight(find.byType(AttributionLine));
    expect(attrDock.dy, lessThanOrEqualTo(680), reason: 'the credit sits above the panel');
    await tester.tapAt(Offset(200, 690));
    await settleAnim(tester);
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(366, 2), reason: 'the tap opened Medium');
    final attrMed = tester.getBottomRight(find.byType(AttributionLine));
    expect(attrMed.dy, lessThanOrEqualTo(366));
    await tester.tapAt(Offset(200, 376));
    await settleAnim(tester);
    await settleAnim(tester); // the 0.95-ratio spring settles in about 1.5 s; the clearance is written at settle
    expect(tester.getRect(find.byType(CoverageMap)), map);
    expect(tester.getBottomRight(find.byType(AttributionLine)), attrDock);
    await end(tester, h);
  });

  group('dock', () {
    testWidgets('idle: status, subtitle, Start drive 148x52 at the thumb corner; no AppBar', (tester) async {
      await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, connect: true);
      expect(find.byType(AppBar), findsNothing);
      expect(find.byKey(const Key('status-line')), findsOneWidget);
      expect(tester.getSize(find.byKey(const Key('start-stop'))), const Size(148, 52));
      expect(find.byKey(const Key('ping-now')), findsNothing);
      expect(find.text('Start drive'), findsOneWidget);
    });

    testWidgets('driving: hero shows "Listening" then the repeaters that heard the last ping, and "No echo" in warning colour', (tester) async {
      final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
      expect(find.byKey(const Key('dock-hero-listening')), findsOneWidget);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 3), Echo(repeater: 'b2', snrDb: 1), Echo(repeater: 'a1', snrDb: 2)]));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Text>(find.byKey(const Key('dock-hero'))).data, '2', reason: 'distinct repeaters, a1 counted once');
      expect(tester.widget<Text>(find.byKey(const Key('dock-hero-caption'))).data, startsWith('heard'));
      h.engines.single.emit(silentPing('p2'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.widget<Text>(find.byKey(const Key('dock-hero'))).data, '0');
      expect(tester.widget<Text>(find.byKey(const Key('dock-hero-caption'))).data, startsWith('No echo'));
      final c = AppColorsProbe.warning(tester.element(find.byKey(const Key('dock-hero'))));
      expect(tester.widget<Text>(find.byKey(const Key('dock-hero'))).style!.color, c);
      await end(tester, h);
    });

    testWidgets('Start/Stop/Ping never scroll: they stay put while Medium scrolls', (tester) async {
      final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
      await tester.tapAt(Offset(200, 690));
      await settleAnim(tester);
      final stop = tester.getTopLeft(find.byKey(const Key('start-stop')));
      final ping = tester.getTopLeft(find.byKey(const Key('ping-now')));
      await tester.drag(find.byKey(const Key('drive-panel-medium')), const Offset(0, -150));
      await tester.pump(const Duration(milliseconds: 400));
      expect((tester.getTopLeft(find.byKey(const Key('start-stop'))) - stop).distance, lessThan(0.01));
      expect((tester.getTopLeft(find.byKey(const Key('ping-now'))) - ping).distance, lessThan(0.01));
      await end(tester, h);
    });

    testWidgets('Ping: a second tap inside 2 s is ignored', (tester) async {
      final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
      final eng = h.engines.single;
      final n0 = eng.pingNowCalls;
      await tester.tap(find.byKey(const Key('ping-now')));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('ping-now')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(eng.pingNowCalls - n0, 1);
      h.clockNow = h.clockNow.add(const Duration(seconds: 3));
      await tester.pump(const Duration(seconds: 3));
      await tester.tap(find.byKey(const Key('ping-now')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(eng.pingNowCalls - n0, 2);
      await end(tester, h);
    });

    testWidgets('finished: summary, View report and Start new', (tester) async {
      final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1', snrDb: 3)]));
      await tester.pump(const Duration(milliseconds: 100));
      await h.state.stopDrive();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Drive saved'), findsOneWidget);
      expect(find.byKey(const Key('view-report')), findsOneWidget);
      expect(find.text('Start new'), findsOneWidget);
      await tester.pump(const Duration(seconds: 25));
    });
  });

  group('tab bar hook and Immersive', () {
    testWidgets('the panel hides and shows the tab bar through ShellController.immersive', (tester) async {
      final shell = ShellController();
      final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true, shell: shell);
      expect(shell.immersive, isFalse);
      await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 120), 1500);
      await settleAnim(tester);
      expect(shell.immersive, isTrue);
      expect(panelTop(tester), closeTo(752, 2));
      await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, -120), 1500);
      await settleAnim(tester);
      expect(shell.immersive, isFalse);
      expect(panelTop(tester), closeTo(680, 2));
      await end(tester, h);
    });
  });

  group('auto-collapse (5.3)', () {
    testWidgets('moving above 5 mph: Medium collapses after 15 s without touch; Passenger keeps it open', (tester) async {
      final fixes = StreamController<GeoFix>.broadcast();
      late Harness h;
      Future<void> tick(int seconds) async {
        h.clockNow = h.clockNow.add(Duration(seconds: seconds));
        await tester.pump(Duration(seconds: seconds));
      }

      DriveMapModel.debugFixes = (_) => fixes.stream;
      addTearDown(() {
        DriveMapModel.debugFixes = null;
        fixes.close();
      });
      h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, drive: true);
      fixes.add(GeoFix(lat: 40.0, lon: -82.9, at: DateTime.now(), speedMps: 10));
      await tester.tapAt(Offset(200, 690));
      await settleAnim(tester);
      expect(panelTop(tester), closeTo(366, 2));
      // Turn Passenger on: nothing collapses.
      await tester.tap(find.byKey(const Key('passenger-switch')));
      await tick(1);
      for (var i = 0; i < 30; i++) {
        fixes.add(GeoFix(lat: 40.0, lon: -82.9, at: DateTime.now(), speedMps: 10));
        await tick(1);
      }
      expect(panelTop(tester), closeTo(366, 2), reason: 'Passenger is on');
      await tester.tap(find.byKey(const Key('passenger-switch')));
      await tester.pump(const Duration(milliseconds: 100));
      for (var i = 0; i < 12; i++) {
        fixes.add(GeoFix(lat: 40.0, lon: -82.9, at: DateTime.now(), speedMps: 10));
        await tick(1);
      }
      expect(panelTop(tester), closeTo(366, 2), reason: 'a touch inside 15 s resets the timer');
      for (var i = 0; i < 8; i++) {
        fixes.add(GeoFix(lat: 40.0, lon: -82.9, at: DateTime.now(), speedMps: 10));
        await tick(1);
      }
      await settleAnim(tester);
      expect(panelTop(tester), closeTo(680, 2));
      await end(tester, h);
    });
  });

  testWidgets('remoteQueue.autoRefreshEnabled is off while driving and back on after', (tester) async {
    final h = await pumpDrive(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, connect: true);
    final q = h.state.radioSessions.remoteQueue;
    expect(q.autoRefreshEnabled, isTrue);
    await h.state.startDrive();
    await tester.pump(const Duration(milliseconds: 200));
    expect(q.autoRefreshEnabled, isFalse);
    await h.state.stopDrive();
    await tester.pump(const Duration(milliseconds: 300));
    expect(q.autoRefreshEnabled, isTrue);
    await tester.pump(const Duration(seconds: 25));
  });

  testWidgets('flag off: the old footer layout still builds (escape hatch)', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    expect(AppFlags.driveRedesign, isFalse);
    expect(find.byKey(const Key('drive-panel')), findsNothing);
    expect(find.byKey(const Key('start-stop')), findsOneWidget);
    expect(find.byType(AppBar), findsWidgets);
  });
}

/// The warning colour the dock uses, read the same way the dock reads it.
class AppColorsProbe {
  static Color warning(BuildContext c) => Theme.of(c).brightness == Brightness.dark ? const Color(0xFFFFA14A) : const Color(0xFFA14B00);
}
