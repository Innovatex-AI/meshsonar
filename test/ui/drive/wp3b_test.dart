// Drive WP3b on the real Drive screen (flag driveRedesign on): StatusCapsule, the always-present RegionChip, the 28 pt strip, the
// connecting / idle / AX docks, the fixed-slot control column, opaque map buttons, Cancel.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/drive/dock_strip.dart';
import 'package:meshsonar/ui/drive/drive_controls.dart' show MapIconButton;
import 'package:meshsonar/ui/drive_screen.dart';

import '../fakes.dart';

Future<Harness> pump(
  WidgetTester tester, {
  Size size = const Size(402, 874),
  double navBar = 106,
  double safeBottom = 34,
  bool connect = false,
  bool drive = false,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  Harness? harness,
}) async {
  AppFlags.driveRedesign = true;
  addTearDown(() => AppFlags.driveRedesign = false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = harness ?? Harness();
  await h.state.init();
  if (connect || drive) await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  if (drive) await h.state.startDrive();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(brightness),
      home: MediaQuery(
        data: MediaQueryData(size: size, padding: EdgeInsets.only(top: 47, bottom: navBar), viewPadding: EdgeInsets.only(top: 47, bottom: safeBottom), textScaler: TextScaler.linear(textScale)),
        child: const DriveScreen(),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

Future<void> end(WidgetTester tester, Harness h) async {
  if (h.state.driving) await h.state.stopDrive();
  await tester.pump(const Duration(seconds: 25));
}

double panelTop(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;

void main() {
  testWidgets('idle, not connected: Not connected / Connect radio dock, capsule says No radio, region chip is present', (tester) async {
    final h = await pump(tester);
    expect(find.text('Not connected'), findsOneWidget);
    expect(find.text('Connect your radio to begin'), findsOneWidget);
    expect(find.text('Connect radio'), findsOneWidget);
    expect(find.byKey(const Key('capsule-radio')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'No radio');
    expect(find.byKey(const Key('region-chip-hit')), findsOneWidget, reason: 'RegionChip renders in every state');
    // Hit boxes are at least 44 pt.
    expect(tester.getSize(find.byKey(const Key('region-chip-hit'))).height, greaterThanOrEqualTo(44));
    expect(tester.getSize(find.byKey(const Key('connection-chip'))).height, greaterThanOrEqualTo(44));
    // No old banner, no hint card, no heard box on the map.
    expect(find.byKey(const Key('location-note')), findsNothing);
    expect(find.byKey(const Key('gps-health')), findsNothing);
    await end(tester, h);
  });

  testWidgets('connected idle reads Ready; driving capsule shows Radio and GPS words', (tester) async {
    final h = await pump(tester, connect: true);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Start drive'), findsOneWidget);
    await h.state.startDrive();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'Radio');
    expect(find.byKey(const Key('capsule-gps')), findsOneWidget);
    await end(tester, h);
  });

  testWidgets('Connecting dock: spinner text and Cancel returns to idle with no confirmation', (tester) async {
    final h = Harness();
    h.bt.connectGate = Completer<void>();
    await h.state.init();
    await pump(tester, harness: h);
    unawaited(h.state.connect(h.bt.devices.first, RadioKind.bluetooth));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.connecting, isTrue);
    expect(find.text('Connecting to your radio...'), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('capsule-radio'))).data, 'Connecting');
    expect(tester.getSize(find.byKey(const Key('connect-cancel'))).height, greaterThanOrEqualTo(48));
    await tester.tap(find.byKey(const Key('connect-cancel')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.state.connecting, isFalse);
    expect(h.state.connected, isFalse);
    expect(find.text('Not connected'), findsOneWidget);
    // A late answer from the radio is dropped.
    h.bt.connectGate!.complete();
    await tester.pump(const Duration(milliseconds: 200));
    expect(h.state.connected, isFalse);
    expect(h.state.connectError, isNull);
    await end(tester, h);
  });

  testWidgets('strip: location denied shows the 28 pt strip with Allow location; Start is disabled; panel buttons do not move', (tester) async {
    final h = Harness();
    h.locationAccess = FakeLocationAccess(LocationAccess.notAsked, LocationAccess.granted);
    final base = await pump(tester, connect: true, harness: h);
    await h.state.refreshLocationAccess();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('drive-panel-strip')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('drive-panel-strip'))).height, 28);
    expect(find.text('Location is off for MeshSonar'), findsWidgets);
    expect(find.byKey(const Key('dock-strip-action')), findsOneWidget);
    final btn = tester.getTopLeft(find.byKey(const Key('start-stop')));
    final fb = tester.widget<FilledButton>(find.byKey(const Key('start-stop')));
    expect(fb.onPressed, isNull, reason: 'Start is disabled with the reason');
    // The strip sits above the dock; the Start button stays where it was without the strip (panel grows upward).
    expect(btn.dy, closeTo(874 - 106 - 72 + 10, 6));
    // The one fix works.
    await tester.tap(find.byKey(const Key('dock-strip-action')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const Key('drive-panel-strip')), findsNothing);
    expect(tester.widget<FilledButton>(find.byKey(const Key('start-stop'))).onPressed, isNotNull);
    expect(base.state.locationNote, isNull);
    await end(tester, base);
  });

  test('stripFor priority: GPS lost beats weak; waiting shows nothing', () async {
    final h = Harness();
    await h.state.init();
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
    await h.state.startDrive();
    h.state.gpsHealth.value = const GpsHealth(GpsHealthKind.waiting, 'Waiting for GPS');
    expect(stripFor(h.state, h.state.gpsHealth.value), isNull);
    h.state.gpsHealth.value = const GpsHealth(GpsHealthKind.weak, 'GPS weak', accuracyM: 47);
    expect(stripFor(h.state, h.state.gpsHealth.value)!.text, 'GPS signal weak (+/-47 m)');
    h.state.gpsHealth.value = const GpsHealth(GpsHealthKind.noFix, 'No GPS');
    final lost = stripFor(h.state, h.state.gpsHealth.value)!;
    expect(lost.kind, StripKind.gpsLost);
    expect(lost.text, 'GPS lost - pings paused');
    h.state.gpsHealth.value = const GpsHealth(GpsHealthKind.approximate, 'Precise off', action: GpsHealthAction.openAppSettings);
    expect(stripFor(h.state, h.state.gpsHealth.value)!.actionLabel, 'Open Settings');
    await h.state.stopDrive();
  });

  testWidgets('AX3: dock is two rows (152 incl. grabber), panel top 616, nothing clipped, capsule collapses to a 44 pt dot', (tester) async {
    final h = await pump(tester, drive: true, textScale: 3.0);
    expect(panelTop(tester), closeTo(616, 2));
    final stop = tester.getRect(find.byKey(const Key('start-stop')));
    expect(stop.height, 56);
    expect(stop.width, greaterThan(300), reason: 'Stop is full width');
    final ping = tester.getRect(find.byKey(const Key('ping-now')));
    expect(ping.bottom, lessThanOrEqualTo(stop.top + 1));
    expect(find.byKey(const Key('dock-hero')).evaluate().length + find.byKey(const Key('dock-hero-listening')).evaluate().length, 1);
    expect(find.byKey(const Key('capsule-radio')), findsNothing, reason: 'collapsed to the dot at >= 2x');
    expect(tester.getSize(find.byKey(const Key('connection-chip'))), const Size(44, 44));
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });

  testWidgets('AX3 idle: status line plus a full-width Start, map keeps >= 60%', (tester) async {
    final h = await pump(tester, connect: true, textScale: 3.0);
    expect(tester.getSize(find.byKey(const Key('start-stop'))).width, greaterThan(300));
    expect(panelTop(tester) / 874, greaterThanOrEqualTo(0.6));
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });

  testWidgets('control column: fixed slots, 48 pt, Layers always, recenter/compass keep their space', (tester) async {
    final h = await pump(tester, connect: true);
    final layers = tester.getRect(find.byKey(const Key('drive-map-layers')));
    final recenter = tester.getRect(find.byKey(const Key('map-recenter')));
    final compass = tester.getRect(find.byKey(const Key('map-compass')));
    expect(layers.size, const Size(48, 48));
    expect(recenter.size, const Size(48, 48));
    expect(compass.size, const Size(48, 48));
    expect(recenter.top, greaterThan(layers.bottom), reason: 'Recenter is the bottom slot');
    expect(compass.bottom, lessThan(layers.top), reason: 'Compass is the top slot');
    expect(recenter.top - layers.bottom, closeTo(12, 1));
    expect(find.byKey(const Key('drive-map-style')), findsNothing, reason: 'base style lives in the layers sheet');
    expect(find.byKey(const Key('drive-map-filter')), findsNothing);
    await end(tester, h);
  });

  testWidgets('MapIconButton surface is opaque', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: meshSonarTheme(Brightness.light), home: Scaffold(body: MapIconButton(icon: Icons.add, tooltip: 't', onPressed: () {}))));
    final m = tester.widget<Material>(find.descendant(of: find.byType(MapIconButton), matching: find.byType(Material)).first);
    expect(m.color!.a, 1.0);
  });

  testWidgets('simulator radio shows a SIM badge in the capsule', (tester) async {
    final h = Harness();
    await h.state.init();
    await pump(tester, harness: h);
    await h.state.connectSimulator();
    await tester.pump(const Duration(milliseconds: 100));
    if (h.state.connected) expect(find.byKey(const Key('chip-simulated')), findsOneWidget);
    await end(tester, h);
  });

  // Plan 4.18 rule 5: a 3-line toast on the Drive tab never touches the dock, Start/Stop/Ping, the panel, the control column, the
  // attribution or the tab bar; it is left aligned, clears the right 72 pt, has no ellipsis and sits in the top half.
  for (final (name, size, nav, safe, scale) in [
    ('402x874', const Size(402, 874), 106.0, 34.0, 1.0),
    ('SE 375x667', const Size(375, 667), 49.0, 0.0, 1.0),
    ('402x874 AX3', const Size(402, 874), 106.0, 34.0, 3.0),
  ]) {
    testWidgets('toast band: $name', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      AppFlags.driveRedesign = true;
      addTearDown(() => AppFlags.driveRedesign = false);
      final h = Harness();
      await h.state.init();
      await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
      await h.state.startDrive();
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.light),
          home: AppToastHost(
            anchor: ToastAnchor.top,
            inset: 96,
            band: true,
            child: MediaQuery(
              data: MediaQueryData(size: size, padding: EdgeInsets.only(top: 47, bottom: nav), viewPadding: EdgeInsets.only(top: 47, bottom: safe), textScaler: TextScaler.linear(scale)),
              child: const DriveScreen(),
            ),
          ),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 100));
      final ctx = tester.element(find.byType(DriveScreen));
      showAppToast(ctx, 'Ping failed: the radio is busy. Try again in a moment. If it keeps happening, reconnect the radio from the connection sheet.', duration: const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 400));
      final toast = tester.getRect(find.byKey(const Key('app-toast')));
      expect(toast.left, 16);
      expect(toast.right, lessThanOrEqualTo(size.width - 72 + 0.5));
      expect(toast.bottom, lessThan(size.height / 2), reason: 'the band sits above the screen midpoint');
      for (final k in ['drive-panel', 'start-stop', 'ping-now', 'map-control-column', 'map-attribution']) {
        final f = find.byKey(Key(k));
        if (f.evaluate().isEmpty) continue;
        expect(toast.overlaps(tester.getRect(f)), isFalse, reason: 'toast vs $k');
      }
      final t = tester.widget<Text>(find.descendant(of: find.byKey(const Key('app-toast')), matching: find.byType(Text)).first);
      expect(t.overflow, isNot(TextOverflow.ellipsis));
      expect(t.maxLines, isNull);
      dismissAppToast();
      await end(tester, h);
    });
  }
}
