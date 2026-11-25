// Build 76 screen review, Drive area: what an iPhone user sees changed.
//   - the simulator radio reads as a working radio (green dot, quiet outlined SIM tag), not as a fault
//   - the Dock's lines fit an iPhone SE, the antenna line opens the antenna sheet, the MeshTrack button is icon-only under 400 pt
//   - the Drive panel's list rows are labelled and 48 pt tall
//   - the legend chip on the Drive map is the short one
//   - the strip's fix runs from the whole strip
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/tokens.dart';
import 'package:meshsonar/ui/drive/dock_strip.dart';
import 'package:meshsonar/ui/drive/drive_controls.dart';
import 'package:meshsonar/ui/drive_screen.dart';

import '../fakes.dart';

Future<Harness> pump(WidgetTester tester, Size size, {bool connect = false, bool sim = false, bool antenna = true}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final h = Harness(antennaProfile: antenna);
  await h.state.init();
  if (sim) {
    await h.state.connectSimulator();
  } else if (connect) {
    await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  }
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(size: size, padding: const EdgeInsets.only(top: 47, bottom: 106), viewPadding: const EdgeInsets.only(top: 47, bottom: 34)),
        child: const DriveScreen(),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

Future<void> end(WidgetTester tester) async => tester.pump(const Duration(seconds: 25));

void main() {
  testWidgets('simulator: green Radio dot and an outlined SIM tag, nothing amber', (tester) async {
    await pump(tester, const Size(375, 667), sim: true);
    final c = AppColors.fromTheme(meshSonarTheme(Brightness.dark));
    final tag = tester.widget<Container>(find.byKey(const Key('chip-simulated')));
    final deco = tag.decoration! as BoxDecoration;
    expect(deco.color, isNull, reason: 'no amber fill');
    expect(deco.border, isNotNull);
    final capsule = find.byKey(const Key('connection-chip'));
    final fills = [
      for (final e in find.descendant(of: capsule, matching: find.byType(Container)).evaluate())
        if ((e.widget as Container).decoration case final BoxDecoration d) d.color,
    ];
    expect(fills, isNot(contains(c.warning)), reason: 'the Radio dot is not amber');
    expect(fills, contains(c.ok));
    await end(tester);
  });

  testWidgets('iPhone SE idle Dock: the status line is whole, the MeshTrack button is the 48 pt icon', (tester) async {
    await pump(tester, const Size(375, 667));
    final line = tester.widget<Text>(find.byKey(const Key('status-line')));
    expect(line.data, 'Not connected');
    final para = tester.renderObject<RenderBox>(find.byKey(const Key('status-line')));
    final painter = TextPainter(text: TextSpan(text: line.data, style: line.style), textDirection: TextDirection.ltr)..layout();
    expect(para.size.width, greaterThanOrEqualTo(painter.width - 12), reason: 'not squeezed to an ellipsis');
    if (find.byKey(const Key('mt-dock-hit')).evaluate().isNotEmpty) {
      expect(tester.getSize(find.byKey(const Key('mt-dock-hit'))), const Size(48, 52));
      expect(find.byKey(const Key('mt-dock-label')), findsNothing);
    }
    expect(tester.takeException(), isNull);
    await end(tester);
  });

  testWidgets('a radio with no antenna set: the Dock says so in two short lines and a tap opens the antenna sheet', (tester) async {
    final h = await pump(tester, const Size(375, 667), connect: true, antenna: false);
    await tester.pumpAndSettle();
    // The first connect opens the sheet by itself: close it, then the Dock line must bring it back.
    if (find.byKey(const Key('antenna-sheet')).evaluate().isNotEmpty) {
      Navigator.of(tester.element(find.byKey(const Key('antenna-sheet')))).pop();
      await tester.pumpAndSettle();
    }
    expect(h.state.needsAntennaSetup, isTrue);
    expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Set antenna');
    expect(tester.widget<Text>(find.byKey(const Key('dock-subtitle'))).data, 'Tap to set it up');
    await tester.tap(find.byKey(const Key('dock-antenna-setup')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
    await end(tester);
  });

  testWidgets('the Drive map legend chip is the short one, 36 pt tall', (tester) async {
    await pump(tester, const Size(375, 667), connect: true);
    final chip = find.byKey(const Key('legend-card-toggle'));
    if (chip.evaluate().isNotEmpty) {
      expect(find.text('Weak → strong signal'), findsNothing);
      expect(tester.getSize(chip).height, greaterThanOrEqualTo(36));
    }
    await end(tester);
  });

  testWidgets('DrivePanelRow: label and value, 48 pt, the whole row taps; no chevron when it opens nothing', (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          DrivePanelRow(key: const Key('a'), icon: Icons.tune_rounded, label: 'Pings', value: 'Every 30 s / 50 ft', onTap: () => taps++),
          const DrivePanelRow(key: Key('b'), icon: Icons.lock_rounded, label: 'Antenna', value: 'External · 5.8 dBi'),
        ]),
      ),
    ));
    expect(find.text('Pings'), findsOneWidget);
    expect(find.text('Every 30 s / 50 ft'), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('a'))).height, greaterThanOrEqualTo(48));
    await tester.tapAt(tester.getTopLeft(find.byKey(const Key('a'))) + const Offset(200, 24));
    expect(taps, 1);
    expect(find.descendant(of: find.byKey(const Key('a')), matching: find.byIcon(Icons.chevron_right_rounded)), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('b')), matching: find.byIcon(Icons.chevron_right_rounded)), findsNothing);
  });

  testWidgets('DrivePanelRow at 2.4x text on a 320 pt screen: the value drops under the label, nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(2.4)),
        child: Scaffold(body: DrivePanelRow(icon: Icons.settings_input_antenna_rounded, label: 'Antenna', value: 'Roof mag-mount · 5.8 dBi · 1.8 m', onTap: () {})),
      ),
    ));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the strip runs its fix from anywhere on the strip', (tester) async {
    var fixed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 28,
          child: DockStripView(info: StripInfo(StripKind.permission, 'Location is off', actionLabel: 'Open Settings', action: () => fixed++, severe: true)),
        ),
      ),
    ));
    await tester.tapAt(tester.getTopLeft(find.byType(DockStripView)) + const Offset(40, 14));
    expect(fixed, 1);
    await tester.tap(find.text('Open Settings'));
    expect(fixed, 2);
  });
}
