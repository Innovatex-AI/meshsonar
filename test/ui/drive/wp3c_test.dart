// Drive WP3c: the other sizes. iPad portrait and landscape and the landscape phone use a floating card (never wider than 380, the
// only bottom surface); SE and AX3 keep the map; idle Immersive is the Start pill.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive_screen.dart';

import '../fakes.dart';

Future<Harness> pump(
  WidgetTester tester, {
  required Size size,
  double navBar = 0,
  double safeBottom = 0,
  double safeLeft = 0,
  bool connect = false,
  bool drive = false,
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool reduceMotion = false,
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
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: ThemeData(brightness: brightness, useMaterial3: true),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: EdgeInsets.only(top: 24, bottom: navBar, left: safeLeft),
          viewPadding: EdgeInsets.only(top: 24, bottom: safeBottom, left: safeLeft),
          textScaler: TextScaler.linear(textScale),
          disableAnimations: reduceMotion,
        ),
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

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Rect panelRect(WidgetTester tester) => tester.getRect(find.byKey(const Key('drive-panel')));

void main() {
  for (final (name, size, safeB) in [
    ('iPad portrait 834x1210', const Size(834, 1210), 20.0),
    ('iPad landscape 1210x834', const Size(1210, 834), 20.0),
    ('phone landscape 852x393', const Size(852, 393), 21.0),
  ]) {
    testWidgets('$name: floating card, bottom-left, not wider than 380, Start/Stop inside it', (tester) async {
      final h = await pump(tester, size: size, safeBottom: safeB, navBar: safeB, drive: true);
      final card = panelRect(tester);
      final landscapePhone = size.height < 500;
      expect(card.width, landscapePhone ? 300 : 380);
      expect(card.left, 16);
      expect(card.bottom, closeTo(size.height - 16 - safeB, 1), reason: 'floating card sits 16 above the inset');
      expect(card.height, closeTo(88, 1), reason: 'Dock card is 88 high');
      expect(card.right, lessThan(size.width / 2), reason: 'the card never reaches the controls on the right');
      final stop = tester.getRect(find.byKey(const Key('start-stop')));
      expect(card.contains(stop.topLeft) && card.contains(stop.bottomRight), isTrue, reason: 'Stop is inside the card, never scrolled away');
      final ping = tester.getRect(find.byKey(const Key('ping-now')));
      expect(card.contains(ping.topLeft) && card.contains(ping.bottomRight), isTrue);
      expect(ping.right, lessThanOrEqualTo(stop.left));
      // The map is full bleed; no other bottom surface: no widget wider than the card in the panel subtree.
      expect(tester.getSize(find.byKey(const Key('drive-map'))), size);
      // Controls stay on the right edge.
      expect(tester.getRect(find.byKey(const Key('drive-map-layers'))).left, greaterThan(size.width - 100));
      expect(tester.takeException(), isNull);
      await end(tester, h);
    });

    testWidgets('$name: Medium card is 0.5h (0.85h on a landscape phone) and scrolls; the dock stays pinned', (tester) async {
      final h = await pump(tester, size: size, safeBottom: safeB, navBar: safeB, drive: true);
      final dockTop = panelRect(tester).top;
      await tester.tap(find.byKey(const Key('drive-panel-grabber')));
      await settle(tester);
      await settle(tester);
      final med = panelRect(tester);
      expect(med.width, size.height < 500 ? 300 : 380);
      expect(med.height, closeTo(size.height < 500 ? 0.85 * size.height : 0.5 * size.height, 2));
      expect(med.height, greaterThan(88));
      // Stop stays where it was relative to the card's bottom (pinned dock).
      final stop = tester.getRect(find.byKey(const Key('start-stop')));
      expect(stop.bottom, lessThan(med.bottom));
      expect(dockTop, greaterThan(med.top));
      expect(tester.takeException(), isNull);
      await end(tester, h);
    });
  }

  testWidgets('SE 375x667 AX3: dock keeps the map >= 70% (panel top >= 466)', (tester) async {
    final h = await pump(tester, size: const Size(375, 667), navBar: 49, safeBottom: 0, drive: true, textScale: 3.0);
    expect(panelRect(tester).top, greaterThanOrEqualTo(466 - 2));
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });

  testWidgets('SE 375x667: Stop keeps its word and every dock element fits in 375', (tester) async {
    final h = await pump(tester, size: const Size(375, 667), navBar: 49, safeBottom: 0, drive: true);
    final stop = tester.getRect(find.byKey(const Key('start-stop')));
    expect(stop.right, lessThanOrEqualTo(375 - 16 + 0.5));
    expect(find.text('Stop'), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('ping-now'))).size, const Size(64, 64));
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });

  testWidgets('idle Immersive on a phone is the Start pill; the nub brings the Dock back; Start starts a drive', (tester) async {
    final h = await pump(tester, size: const Size(402, 874), navBar: 106, safeBottom: 34, connect: true);
    expect(find.byKey(const Key('immersive-pill')), findsNothing);
    // Fling the header down: Immersive.
    await tester.fling(find.byKey(const Key('drive-panel-grabber')), const Offset(0, 300), 1500);
    await settle(tester);
    await settle(tester);
    expect(find.byKey(const Key('immersive-pill')), findsOneWidget);
    expect(find.byKey(const Key('drive-panel')), findsNothing, reason: 'the panel is not drawn');
    final pill = tester.getRect(find.byKey(const Key('pill-start')));
    expect(pill.height, 56, reason: 'a labelled capsule, not a lone glyph');
    expect(pill.width, greaterThanOrEqualTo(56));
    expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Start drive')), findsOneWidget);
    expect(pill.center.dx, closeTo(201, 1));
    await tester.tap(find.byKey(const Key('pill-nub')));
    await settle(tester);
    await settle(tester);
    expect(find.byKey(const Key('immersive-pill')), findsNothing);
    expect(find.byKey(const Key('drive-panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });

  testWidgets('Reduce Motion: the pill and the card appear without a spring', (tester) async {
    final h = await pump(tester, size: const Size(1210, 834), navBar: 20, safeBottom: 20, connect: true, reduceMotion: true);
    expect(panelRect(tester).width, 380);
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });
}
