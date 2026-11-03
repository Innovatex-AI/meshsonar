// Drive WP7: the lower-left quadrant of the map has no overlay in any state; SIM is a badge in the capsule, the offline state is a
// pill at the top.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/overlays/map_overlay_host.dart';

import '../fakes.dart';

Future<Harness> pump(WidgetTester tester, Size size, {bool connect = false, bool drive = false, bool sim = false, double scale = 1}) async {
  AppFlags.driveRedesign = true;
  addTearDown(() => AppFlags.driveRedesign = false);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness();
  await h.state.init();
  if (sim) {
    await h.state.connectSimulator();
  } else if (connect || drive) {
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  }
  if (drive) await h.state.startDrive();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(size: size, padding: const EdgeInsets.only(top: 47, bottom: 106), viewPadding: const EdgeInsets.only(top: 47, bottom: 34), textScaler: TextScaler.linear(scale)),
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

/// Every Text and Icon the map host puts on screen, outside the panel, must stay out of the lower-left quadrant of the map area.
void expectLowerLeftEmpty(WidgetTester tester, Size size) {
  final panelTop = tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;
  final quadrant = Rect.fromLTRB(0, size.height * 0.5, size.width * 0.5, panelTop);
  // The overlay slots only (the host's layout children); text drawn by the map itself (range-ring labels) is map content.
  final slots = find.descendant(of: find.byType(MapOverlayHost), matching: find.byType(CustomMultiChildLayout));
  final texts = find.descendant(of: slots, matching: find.byType(Text));
  final icons = find.descendant(of: slots, matching: find.byType(Icon));
  for (final f in [...texts.evaluate(), ...icons.evaluate()]) {
    if (f.widget.key == const Key('map-attribution-text')) continue;
    final box = f.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (r.height <= 0 || r.width <= 0) continue;
    expect(quadrant.overlaps(r), isFalse, reason: 'overlay at $r is in the lower-left quadrant $quadrant (${f.widget})');
  }
}

void main() {
  for (final (name, drive) in [('idle', false), ('driving', true)]) {
    testWidgets('lower-left quadrant is empty: $name', (tester) async {
      final size = const Size(402, 874);
      final h = await pump(tester, size, connect: true, drive: drive);
      expectLowerLeftEmpty(tester, size);
      expect(find.byKey(const Key('map-simulated')), findsNothing);
      await end(tester, h);
    });
  }

  testWidgets('the offline state is a pill at the top, under the region chip', (tester) async {
    final size = const Size(402, 874);
    final h = await pump(tester, size);
    if (!CoverageMap.tilesByDefault) {
      expect(find.byKey(const Key('map-offline')), findsOneWidget);
      final pill = tester.getRect(find.byKey(const Key('map-offline')));
      expect(pill.top, lessThan(size.height / 3));
      expect(pill.left, lessThan(size.width / 2));
      final chip = tester.getRect(find.byKey(const Key('region-chip-hit')));
      expect(pill.top, greaterThanOrEqualTo(chip.bottom - 1));
    }
    expectLowerLeftEmpty(tester, size);
    await end(tester, h);
  });

  testWidgets('simulator radio: SIM badge in the capsule, no tag on the map', (tester) async {
    final size = const Size(402, 874);
    final h = await pump(tester, size, sim: true);
    expect(h.state.connected, isTrue);
    expect(find.byKey(const Key('chip-simulated')), findsOneWidget);
    expect(find.byKey(const Key('map-simulated')), findsNothing);
    expectLowerLeftEmpty(tester, size);
    await end(tester, h);
  });

  testWidgets('AX3: attribution still present bottom-right, lower-left still empty', (tester) async {
    final size = const Size(402, 874);
    final h = await pump(tester, size, connect: true, scale: 3.0);
    expect(find.byKey(const Key('map-attribution')), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('map-attribution'))).right, greaterThan(size.width - 40));
    expectLowerLeftEmpty(tester, size);
    expect(tester.takeException(), isNull);
    await end(tester, h);
  });
}
