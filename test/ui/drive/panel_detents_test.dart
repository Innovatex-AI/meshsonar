// Build 70, item 70-2: the Drive panel slides and the map never shrinks. On the real Drive screen (the only layout now): the map's
// size equals the screen at every detent (Dock, Medium, past Medium = Full, the collapsed pill), the panel moves between detents
// by a drag and by a fling either way, the map pans and zooms with the panel at Dock, and with no radio the panel sits at Dock.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';

import 'drive_panel_test.dart' show pumpDrive, panelTop, settleAnim, end;

const _size = Size(402, 874);
const _dock = 680.0, _medium = 366.0, _immersive = 752.0;

void main() {
  Future<void> expectMapIsScreen(WidgetTester tester, String at) async {
    expect(tester.getSize(find.byType(CoverageMap)), _size, reason: 'the map is the screen at $at');
    expect(tester.getTopLeft(find.byType(CoverageMap)), Offset.zero, reason: 'the map is full bleed at $at');
  }

  testWidgets('connected: drag and fling through Dock, Medium, Full (past Medium) and the pill; the map is the screen at every one', (tester) async {
    // Driving, so the collapsed pill is the panel itself (idle, the pill is the small Start capsule).
    final h = await pumpDrive(tester, size: _size, navBar: 106, safeBottom: 34, drive: true);
    expect(panelTop(tester), closeTo(_dock, 2));
    await expectMapIsScreen(tester, 'Dock');

    // Slow drag up on the header: Medium.
    await tester.timedDrag(find.byKey(const Key('drive-panel-header')), const Offset(0, -320), const Duration(milliseconds: 800));
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_medium, 2));
    await expectMapIsScreen(tester, 'Medium');

    // Further up (Full): the panel rubber-bands past Medium while the finger is down, the map stays put, and it rests on Medium.
    final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('drive-panel-grabber'))));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -30));
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(panelTop(tester), lessThan(_medium - 5), reason: 'pulled past Medium');
    await expectMapIsScreen(tester, 'Full (finger down)');
    await gesture.up();
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_medium, 2));
    await expectMapIsScreen(tester, 'Full (released)');

    // Fling down: Dock. Fling down again: the collapsed pill.
    await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 400), 1500);
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_dock, 2));
    await expectMapIsScreen(tester, 'Dock after a fling');
    await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 120), 1500);
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_immersive, 2));
    await expectMapIsScreen(tester, 'collapsed');

    // Fling up from the pill: back to Dock; fling up again: Medium.
    await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, -120), 1500);
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_dock, 2));
    await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, -300), 1500);
    await settleAnim(tester);
    expect(panelTop(tester), closeTo(_medium, 2));
    await expectMapIsScreen(tester, 'Medium after a fling');
    await end(tester, h);
  });

  testWidgets('the map pans and zooms with the panel at Dock, and the panel stays at Dock', (tester) async {
    final h = await pumpDrive(tester, size: _size, navBar: 106, safeBottom: 34, connect: true);
    final map = find.byType(CoverageMap);
    await tester.dragFrom(const Offset(200, 300), const Offset(-80, 60));
    await tester.pump(const Duration(milliseconds: 300));
    // Pinch out (two fingers moving apart).
    final a = await tester.startGesture(const Offset(180, 350));
    final b = await tester.startGesture(const Offset(220, 350));
    for (var i = 0; i < 8; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(panelTop(tester), closeTo(_dock, 2), reason: 'a map gesture never moves the panel');
    expect(tester.getSize(map), _size);
    await end(tester, h);
  });

  testWidgets('no radio: the panel sits at Dock (never the middle) and the map is the screen', (tester) async {
    final h = await pumpDrive(tester, size: _size, navBar: 106, safeBottom: 34);
    expect(h.state.connected, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(panelTop(tester), closeTo(_dock, 2));
    expect(find.byKey(const Key('drive-panel-medium')), findsNothing);
    await expectMapIsScreen(tester, 'Dock, no radio');
    await tester.dragFrom(const Offset(200, 300), const Offset(-60, 40));
    await tester.pump(const Duration(milliseconds: 300));
    expect(panelTop(tester), closeTo(_dock, 2));
    await end(tester, h);
  });
}
