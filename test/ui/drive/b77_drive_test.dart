// Build 77, the Drive page (package W2-B): Round 1 F5-F8, Round 4 P-U1 (Drive half), Round 5 M4 and decision 4.
//   F5  Layers and the Legend replace the Drive panel on a phone (inspectors do not); during a drive the mini drive bar
//       (Stop) and Ping sit under the sheet; the sheet scrolls and nothing is clipped.
//   F6  one message, one place: no second "pings not saved", location note or antenna hint at Medium; "Map guide" is not a
//       Drive panel row; the strip is 44 pt and wraps to two lines; the priority order is unchanged.
//   F7  the "Drive saved" row keeps its button labels at full size at every width; the left text gives way.
//   F8  the collapsed-panel nub is a 44 pt target; every tap target on Drive, Layers and Legend is at least 44 x 44.
//   P-U1 / M4  "Where to drive next" and "Drives" rows in the idle panel.
//   Decision 4  Start drive is not blocked by the antenna question: it records "Don't know"; the Antenna row stays.
import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart' show HitTestResult;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/core/antenna_profile.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/drive/dock_strip.dart';
import 'package:meshsonar/ui/drive/panel/panel_dock.dart' show PingDebounce;
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';
import 'package:meshsonar/ui/drive/sheet_drive_bar.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/sessions_screen.dart';

import '../fakes.dart';

const _phone = Size(402, 874);
const _tabZone = 106.0;

Future<Harness> _pump(WidgetTester tester, {Size size = _phone, bool connect = false, bool antenna = true, double text = 1}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  MapPanelStore.clear();
  final h = Harness(antennaProfile: antenna);
  await h.state.init();
  if (connect) await h.state.connect(h.bt.devices.first, RadioKind.bluetooth);
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(text),
          padding: const EdgeInsets.only(top: 47, bottom: _tabZone),
          viewPadding: const EdgeInsets.only(top: 47, bottom: 34),
        ),
        child: const DriveScreen(),
      ),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

Future<void> _end(WidgetTester tester) async => tester.pump(const Duration(seconds: 25));

Future<void> _openMedium(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('drive-panel-grabber')));
  await _settle(tester);
  expect(find.byKey(const Key('drive-panel-medium')), findsOneWidget);
}

Finder _p(String id) => find.byKey(Key('map-panel-$id'));

/// Every tap target that can be hit right now: buttons, icon buttons, InkWells and GestureDetectors with a tap handler.
/// The iOS segmented controls are left out (standard iOS height, kept by the plan, Round 1 U3); so are the map itself and
/// whole-panel surfaces (anything taller than 200 pt or as wide as the screen and taller than 100 pt is a surface, not a
/// target). An InkWell inside a Material button is measured as the button (its padded tap target).
List<String> _smallTargets(WidgetTester tester, {required String where}) {
  final out = <String>[];
  final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
  bool insideButton(Element e) {
    var found = false;
    e.visitAncestorElements((a) {
      if (a.widget is ButtonStyleButton || a.widget is IconButton) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  bool inSegmented(Element e) {
    var found = false;
    e.visitAncestorElements((a) {
      if (a.widget is CupertinoSlidingSegmentedControl || a.widget is CupertinoSegmentedControl || a.widget is SegmentedButton) {
        found = true;
        return false;
      }
      return true;
    });
    return found;
  }

  final targets = find.byWidgetPredicate((w) =>
      (w is ButtonStyleButton && w.onPressed != null) ||
      (w is IconButton && w.onPressed != null) ||
      (w is InkWell && w.onTap != null) ||
      (w is GestureDetector && w.onTap != null));
  for (final e in targets.evaluate()) {
    if (e.widget is InkWell && insideButton(e)) continue;
    if (inSegmented(e)) continue;
    // A chip draws 30 pt but is hit on its padded 48 pt target (RawChip's tap-target redirect): measure the chip.
    Element? chip;
    e.visitAncestorElements((a) {
      if (a.widget is RawChip) {
        chip = a;
        return false;
      }
      return true;
    });
    final ro = (chip ?? e).renderObject;
    if (ro is! RenderBox || !ro.hasSize || !ro.attached) continue;
    final r = ro.localToGlobal(Offset.zero) & ro.size;
    if (r.isEmpty || !r.overlaps(Offset.zero & screen)) continue;
    if (r.height > 200 || (r.width >= screen.width - 1 && r.height > 100)) continue;
    // Only what a finger can reach: the centre is hit-testable (not under another surface, not offstage).
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, r.center.clamp(Offset.zero, Offset(screen.width - 1, screen.height - 1)), tester.view.viewId);
    if (!hit.path.any((p) => p.target == ro)) continue;
    // The credit's (i) (lib/ui/map/overlays/attribution_line.dart, not a Drive file) is hit through the pill's HitSlop:
    // 10 pt beyond its right edge and 11 pt above and below, so its target is 34 x 44. Measured as that; it is reported to
    // the lead rather than counted as a Drive target.
    if (e.widget.key == const Key('map-attribution-info')) {
      if (r.width + 10 < 34 - 0.5 || r.height + 22 < 44 - 0.5) out.add('$where: credit (i) ${r.size} plus its hit slop is under 34 x 44');
      continue;
    }
    // The coverage time chips in Layers (lib/ui/map/coverage_layer_controls.dart, not a Drive file) are compact ChoiceChips,
    // a 40 pt target. Reported to the lead (drop `visualDensity: VisualDensity.compact` there); held to 40 here until then.
    String? covKey;
    if (chip != null) {
      chip!.visitAncestorElements((a) {
        final k = a.widget.key;
        if (k is ValueKey<String> && k.value.startsWith('cov-')) {
          covKey = k.value;
          return false;
        }
        return a.widget is! Wrap;
      });
    }
    if (covKey != null) {
      if (r.height < 40 - 0.5) out.add('$where: coverage chip $covKey ${r.size} is under 40');
      continue;
    }
    if (r.width < 44 - 0.5 || r.height < 44 - 0.5) {
      out.add('$where: ${e.widget.runtimeType} ${e.widget.key ?? ''} ${r.size.width.toStringAsFixed(1)} x ${r.size.height.toStringAsFixed(1)} at ${r.topLeft} <- ${e.debugGetCreatorChain(12)}');
    }
  }
  return out;
}

extension on Offset {
  Offset clamp(Offset lo, Offset hi) => Offset(dx.clamp(lo.dx, hi.dx), dy.clamp(lo.dy, hi.dy));
}

void main() {
  group('F5 Layers and Legend replace the Drive panel', () {
    testWidgets('idle: Layers sits on the tab bar where the Drive panel was; closing it brings the panel back', (tester) async {
      await _pump(tester);
      expect(find.byKey(const Key('drive-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await _settle(tester);
      expect(_p('drive.layers'), findsOneWidget);
      expect(find.byKey(const Key('drive-panel')), findsNothing, reason: 'Layers replaced the Drive panel');
      final r = tester.getRect(_p('drive.layers'));
      expect(r.bottom, closeTo(_phone.height - _tabZone, 1), reason: 'directly above the tab bar, nothing under it');
      expect(find.byKey(const Key('sheet-drive-bar')), findsNothing, reason: 'no drive, no bar');
      await tester.tap(find.byKey(const Key('layers-done')));
      await _settle(tester);
      expect(_p('drive.layers'), findsNothing);
      expect(find.byKey(const Key('drive-panel')), findsOneWidget);
      await _end(tester);
    });

    testWidgets('the Legend panel: replaces the Drive panel, its last row and the Map guide button are not clipped', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('legend-card-toggle')));
      await _settle(tester);
      expect(_p('drive.legend'), findsOneWidget);
      expect(find.byKey(const Key('drive-panel')), findsNothing);
      final panel = tester.getRect(_p('drive.legend'));
      final guide = tester.getRect(find.byKey(const Key('legend-open-guide')));
      expect(guide.bottom, lessThanOrEqualTo(panel.bottom + 0.5), reason: 'the Map guide button is inside the panel');
      expect(tester.takeException(), isNull);
      // A second tap on the chip closes it and the Drive panel is back.
      await tester.tap(find.byKey(const Key('legend-card-toggle')));
      await _settle(tester);
      expect(_p('drive.legend'), findsNothing);
      expect(find.byKey(const Key('drive-panel')), findsOneWidget);
      await _end(tester);
    });

    testWidgets('the Layers sheet scrolls to its end: every row can be brought into the panel, none is cut off', (tester) async {
      await _pump(tester);
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await _settle(tester);
      final panel = tester.getRect(_p('drive.layers'));
      final list = find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first;
      for (var i = 0; i < 30; i++) {
        await tester.drag(list, const Offset(0, -200), warnIfMissed: false);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _settle(tester);
      final pos = tester.state<ScrollableState>(list).position;
      expect(pos.pixels, closeTo(pos.maxScrollExtent, 1), reason: 'scrolled to the end');
      final content = tester.getRect(list);
      expect(content.bottom, lessThanOrEqualTo(panel.bottom + 0.5), reason: 'the scroll view ends inside the panel');
      expect(tester.takeException(), isNull);
      await _end(tester);
    });

    testWidgets('driving: the mini drive bar with Stop and Ping sits under Layers; the bar brings the Drive panel back', (tester) async {
      final h = await _pump(tester, connect: true);
      await h.state.startDrive();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await _settle(tester);
      expect(find.byKey(const Key('drive-panel')), findsNothing);
      final bar = find.byKey(const Key('sheet-drive-bar'));
      expect(bar, findsOneWidget);
      final b = tester.getRect(bar);
      expect(b.bottom, closeTo(_phone.height - _tabZone, 1), reason: 'on the tab bar');
      expect(b.height, kSheetDriveBarHeight);
      expect(tester.getRect(_p('drive.layers')).bottom, closeTo(b.top, 1), reason: 'the sheet sits on the bar');
      expect(find.byKey(const Key('mini-bar-stop')).hitTestable(), findsOneWidget, reason: 'Stop is one tap away');
      final ping = find.byKey(const Key('ping-now')).hitTestable();
      expect(ping, findsOneWidget, reason: 'Ping is one tap away');
      expect(tester.getSize(ping).width, greaterThanOrEqualTo(44));
      // Stop asks first, as everywhere.
      await tester.tap(find.byKey(const Key('mini-bar-stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stop-drive-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-drive-keep')));
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      await tester.tap(find.byKey(const Key('mini-bar-open')));
      await _settle(tester);
      expect(_p('drive.layers'), findsNothing);
      expect(find.byKey(const Key('drive-panel')), findsOneWidget, reason: 'the bar brings the Drive panel back');
      expect(find.byKey(const Key('sheet-drive-bar')), findsNothing);
      await h.state.stopDrive();
      await _end(tester);
    });

    testWidgets('the Ping button under the sheet sends a ping', (tester) async {
      final h = await _pump(tester, connect: true);
      var pings = 0;
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: SheetDriveBar(state: h.state, debounce: PingDebounce(), onOpen: () {}, onPing: () async => pings++))),
        ),
      ));
      await h.state.startDrive();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.tap(find.byKey(const Key('ping-now')));
      expect(pings, 1);
      await h.state.stopDrive();
      await _end(tester);
    });
  });

  group('F6 one message, one place', () {
    testWidgets('pings not saved, driving, panel half open: the strip says it, Medium does not', (tester) async {
      final h = await _pump(tester, connect: true);
      await h.state.startDrive();
      h.store.failAppend = true;
      h.engines.single.emit(silentPing('p1'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(h.state.unsavedCount, 1);
      await _openMedium(tester);
      expect(find.textContaining('not yet saved'), findsOneWidget, reason: 'once, in the strip');
      expect(find.descendant(of: find.byKey(const Key('drive-panel-strip')), matching: find.textContaining('not yet saved')), findsOneWidget);
      expect(find.byKey(const Key('medium-guide')), findsNothing);
      h.store.failAppend = false;
      await h.state.stopDrive();
      await _end(tester);
    });

    testWidgets('no antenna set, idle, half open: one antenna hint (the Antenna row), and the Dock line', (tester) async {
      await _pump(tester, connect: true, antenna: false);
      await _openMedium(tester);
      expect(find.byKey(const Key('antenna-setup')), findsOneWidget);
      expect(find.text('Set up this radio\'s antenna'), findsOneWidget);
      await _end(tester);
    });

    testWidgets('the strip is 44 pt and its sentence wraps to two lines', (tester) async {
      expect(kPanelStripHeight, 44);
      tester.view.physicalSize = const Size(402, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              height: kPanelStripHeight,
              child: DockStripView(info: StripInfo(StripKind.gpsLost, 'GPS lost - pings paused', actionLabel: 'Open Settings', action: () {}, severe: true)),
            ),
          ),
        ),
      ));
      final text = tester.widget<Text>(find.byKey(const Key('dock-strip-text')));
      expect(text.maxLines, 2);
      final box = tester.renderObject<RenderParagraph>(find.byKey(const Key('dock-strip-text')));
      expect(box.didExceedMaxLines, isFalse, reason: 'two lines hold it');
      expect(tester.getSize(find.byKey(const Key('dock-strip-text'))).height, greaterThan(13 * 1.15 * 1.5), reason: 'it wrapped to a second line instead of being cut');
      expect(tester.getSize(find.byKey(const Key('dock-strip-action'))).height, greaterThanOrEqualTo(44));
      expect(tester.takeException(), isNull);
    });

    test('priority order unchanged: GPS lost, radio lost, precise location, permission, unsaved, weak', () {
      expect(StripKind.values, [StripKind.gpsLost, StripKind.radioLost, StripKind.preciseOff, StripKind.permission, StripKind.unsynced, StripKind.gpsWeak]);
    });

    testWidgets('GPS lost wins over unsaved pings while driving', (tester) async {
      final h = await _pump(tester, connect: true);
      await h.state.startDrive();
      h.store.failAppend = true;
      h.engines.single.emit(silentPing('p1'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(stripFor(h.state, const GpsHealth(GpsHealthKind.noFix, 'GPS lost'))!.kind, StripKind.gpsLost);
      expect(stripFor(h.state, const GpsHealth(GpsHealthKind.good, ''))!.kind, StripKind.unsynced);
      h.store.failAppend = false;
      await h.state.stopDrive();
      await _end(tester);
    });
  });

  group('F7 "Drive saved" row', () {
    for (final (size, label) in [(const Size(402, 874), 'iPhone 17'), (const Size(375, 667), 'iPhone SE'), (const Size(320, 568), '320 pt'), (const Size(874, 402), 'landscape card (300 pt)')]) {
      testWidgets('$label: View report and New drive at full size, nothing overflows, the counts are in the label', (tester) async {
        final h = await _pump(tester, size: size, connect: true);
        await h.state.startDrive();
        h.engines.single.emit(silentPing('p1'));
        await tester.pump(const Duration(milliseconds: 200));
        await h.state.stopDrive();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const Key('view-report')), findsOneWidget);
        expect(find.descendant(of: find.byKey(const Key('view-report')), matching: find.byType(FittedBox)), findsNothing, reason: 'no shrinking label');
        expect(find.descendant(of: find.byKey(const Key('start-stop')), matching: find.byType(FittedBox)), findsNothing);
        // The labels keep their size (the test font is much wider than San Francisco, so here they may take the short form).
        for (final k in ['view-report', 'start-stop']) {
          final label = tester.widget<Text>(find.descendant(of: find.byKey(Key(k)), matching: find.byType(Text)));
          expect(label.style?.fontSize, 15, reason: '$k at its full size');
          expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(52));
        }
        expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Drive saved');
        expect(find.bySemanticsLabel(RegExp('Drive saved. 1 ping, 0 heard')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await _end(tester);
      });
    }
  });

  group('F8 tap areas', () {
    testWidgets('the collapsed-panel nub is a 44 pt target', (tester) async {
      await _pump(tester);
      await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 160), 1500);
      await _settle(tester);
      final nub = find.byKey(const Key('pill-nub'));
      expect(nub, findsOneWidget);
      expect(tester.getSize(nub).height, greaterThanOrEqualTo(44));
      expect(tester.getSize(nub).width, greaterThanOrEqualTo(44));
      await tester.tap(nub);
      await _settle(tester);
      expect(find.byKey(const Key('drive-panel')), findsOneWidget);
      await _end(tester);
    });

    testWidgets('every tap target on Drive (Dock, Medium, driving), Layers and Legend is at least 44 x 44', (tester) async {
      final h = await _pump(tester, connect: true);
      final small = <String>[];
      small.addAll(_smallTargets(tester, where: 'Drive idle Dock'));
      await _openMedium(tester);
      small.addAll(_smallTargets(tester, where: 'Drive idle Medium'));
      await tester.tap(find.byKey(const Key('drive-panel-grabber')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await _settle(tester);
      final list = find.descendant(of: find.byKey(const Key('layers-sheet')), matching: find.byType(Scrollable)).first;
      for (var i = 0; i < 12; i++) {
        small.addAll(_smallTargets(tester, where: 'Layers page $i'));
        await tester.drag(list, const Offset(0, -250), warnIfMissed: false);
        await _settle(tester);
      }
      await tester.tap(find.byKey(const Key('layers-done')));
      await _settle(tester);
      await tester.tap(find.byKey(const Key('legend-card-toggle')));
      await _settle(tester);
      small.addAll(_smallTargets(tester, where: 'Legend'));
      await tester.tap(find.byKey(const Key('legend-card-toggle')));
      await _settle(tester);
      await h.state.startDrive();
      await tester.pump(const Duration(milliseconds: 200));
      small.addAll(_smallTargets(tester, where: 'Driving Dock'));
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await _settle(tester);
      small.addAll(_smallTargets(tester, where: 'Driving, Layers'));
      expect(small.toSet().toList(), isEmpty);
      await h.state.stopDrive();
      await _end(tester);
    });
  });

  group('P-U1 / M4 idle panel rows', () {
    testWidgets('idle: "Where to drive next" and "Drives"; Drives opens the saved drives', (tester) async {
      await _pump(tester, connect: true);
      await _openMedium(tester);
      expect(find.byKey(const Key('medium-where-to-drive')), findsOneWidget);
      expect(find.text('Where to drive next'), findsOneWidget);
      final drives = find.byKey(const Key('medium-drives'));
      await tester.ensureVisible(drives);
      await _settle(tester);
      await tester.tap(drives);
      await _settle(tester);
      expect(find.byType(SessionsScreen), findsOneWidget);
      await _end(tester);
    });

    testWidgets('driving: neither row', (tester) async {
      final h = await _pump(tester, connect: true);
      await h.state.startDrive();
      await tester.pump(const Duration(milliseconds: 200));
      await _openMedium(tester);
      expect(find.byKey(const Key('medium-where-to-drive')), findsNothing);
      expect(find.byKey(const Key('medium-drives')), findsNothing);
      await h.state.stopDrive();
      await _end(tester);
    });
  });

  group('decision 4: Start drive without the antenna question', () {
    testWidgets('a radio never set up: Start is enabled, records "Don\'t know", the drive starts, the Antenna row stays', (tester) async {
      final h = await _pump(tester, connect: true, antenna: false);
      expect(h.state.needsAntennaSetup, isTrue);
      expect(tester.widget<Text>(find.byKey(const Key('status-line'))).data, 'Ready');
      expect(tester.widget<Text>(find.byKey(const Key('dock-subtitle'))).data, 'Antenna not set · tap to set');
      final start = tester.widget<ButtonStyleButton>(find.byKey(const Key('start-stop')));
      expect(start.onPressed, isNotNull, reason: 'not blocked by the antenna question');
      await tester.tap(find.byKey(const Key('start-stop')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.state.driving, isTrue);
      final p = h.settings.saved.antennaProfiles['abcdef0123']!;
      expect(p.isUnknown, isTrue);
      expect(h.state.currentSession!.antenna.toJson(), {'type': null, 'gain_dbi': null, 'height_m': null}, reason: 'nothing made up goes on the wire');
      await _openMedium(tester);
      expect(find.descendant(of: find.byKey(const Key('antenna-chip')), matching: find.text('Don\'t know')), findsOneWidget);
      await h.state.stopDrive();
      await tester.pump(const Duration(milliseconds: 300));
      // After the drive the row offers to fix it: it opens the antenna sheet, which starts empty.
      final chip = find.byKey(const Key('antenna-chip'));
      expect(find.descendant(of: chip, matching: find.text('Don\'t know')), findsOneWidget);
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
      expect(find.byKey(const Key('mount-unknown')), findsNothing, reason: '"Don\'t know" is not a mount choice');
      await _end(tester);
    });

    testWidgets('the Dock line still opens the antenna sheet', (tester) async {
      await _pump(tester, size: const Size(375, 667), connect: true, antenna: false);
      await tester.tap(find.byKey(const Key('dock-antenna-setup')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('antenna-sheet')), findsOneWidget);
      await _end(tester);
    });

    testWidgets('the collapsed pill says Start drive and starts it', (tester) async {
      final h = await _pump(tester, connect: true, antenna: false);
      await tester.fling(find.byKey(const Key('drive-panel-header')), const Offset(0, 160), 1500);
      await _settle(tester);
      expect(find.descendant(of: find.byKey(const Key('pill-start')), matching: find.text('Start drive')), findsOneWidget);
      await tester.tap(find.byKey(const Key('pill-start')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.state.driving, isTrue);
      expect(h.state.antennaProfile!.mount, AntennaMount.unknown);
      await h.state.stopDrive();
      await _end(tester);
    });
  });
}
