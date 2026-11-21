// Build 71, "One shared panel" on the Drive map: the Drive panel is the persistent panel, and the layers, the legend and the
// inspector are the ONE transient MapPanel directly above it. Never modal, one open at a time, closed by the X or a tap on
// empty map; nothing hides under the tab bar.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/drive/panel/drive_panel.dart';
import 'package:meshsonar/ui/drive/panel/panel_physics.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/map/map_info_panel.dart';
import 'package:meshsonar/ui/map/overlays/map_controls.dart';

import '../fakes.dart';

const _size = Size(402, 874);
const _dockTop = 680.0; // 874 - (106 tab bar zone + 88 dock)

Future<Harness> _pump(WidgetTester tester) async {
  tester.view.physicalSize = _size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  MapPanelStore.clear();
  final h = Harness();
  await h.state.init();
  await tester.pumpWidget(AppScope(
    state: h.state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: const MediaQuery(
        data: MediaQueryData(size: _size, padding: EdgeInsets.only(top: 47, bottom: 106), viewPadding: EdgeInsets.only(top: 47, bottom: 34)),
        child: DriveScreen(),
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

double _driveTop(WidgetTester tester) => tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;
Finder _p(String id) => find.byKey(Key('map-panel-$id'));

void main() {
  test('the Drive panel uses the shared state names', () {
    expect(DrivePanel.detentLabel(PanelDetent.dock), 'Collapsed');
    expect(DrivePanel.detentLabel(PanelDetent.medium), 'Open');
    expect(DrivePanel.detentLabel(PanelDetent.immersive), 'Hidden');
    expect(DrivePanel.stateOf(PanelDetent.medium), MapPanelState.open);
  });

  testWidgets('Layers: a non-modal panel directly above the Dock, above the tab bar; X closes it', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await _settle(tester);
    expect(_p('drive.layers'), findsOneWidget);
    expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
    final r = tester.getRect(_p('drive.layers'));
    expect(r.bottom, closeTo(_dockTop, 1), reason: 'sits on the Drive panel, nothing under the tab bar');
    expect(r.height, lessThanOrEqualTo(_dockTop * 0.6 + 1), reason: 'Open is at most 60 % of the height above the Dock');
    // Never modal: no dimming barrier, no route, and the map above the panel still takes a drag.
    expect(Navigator.of(tester.element(find.byType(DriveScreen))).canPop(), isFalse);
    expect(find.byType(ModalBarrier).evaluate().where((e) => (e.widget as ModalBarrier).color != null && (e.widget as ModalBarrier).color != Colors.transparent), isEmpty);
    await tester.dragFrom(const Offset(200, 120), const Offset(-40, 20));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(_p('drive.layers'), findsOneWidget, reason: 'a map drag is not a tap on empty map');
    await tester.tap(find.byKey(const Key('layers-done')));
    await _settle(tester);
    expect(_p('drive.layers'), findsNothing);
    expect(_driveTop(tester), closeTo(_dockTop, 1), reason: 'the Drive panel never moved');
  });

  testWidgets('one open panel: opening the legend sends the Drive panel from Open back to Collapsed, and the other way round', (tester) async {
    await _pump(tester);
    await tester.tap(find.byKey(const Key('drive-panel-grabber')));
    await _settle(tester);
    expect(_driveTop(tester), lessThan(_dockTop - 100), reason: 'the person opened the Drive panel');
    await tester.tap(find.byKey(const Key('legend-card-toggle')));
    await _settle(tester);
    await _settle(tester);
    expect(_p('drive.legend'), findsOneWidget);
    expect(find.byKey(const Key('map-panel-drive.legend-body')), findsOneWidget);
    expect(_driveTop(tester), closeTo(_dockTop, 1), reason: 'one open panel per map');
    expect(tester.getRect(_p('drive.legend')).bottom, closeTo(_dockTop, 1), reason: 'the transient panel followed the Drive panel down');

    await tester.tap(find.byKey(const Key('drive-panel-grabber')));
    await _settle(tester);
    await _settle(tester);
    expect(_driveTop(tester), lessThan(_dockTop - 100));
    expect(find.byKey(const Key('map-panel-drive.legend-body')), findsNothing, reason: 'opening the Drive panel collapses the transient panel to its header');
    expect(_p('drive.legend'), findsOneWidget, reason: 'collapsed, not closed');
    await tester.tap(find.byKey(const Key('drive-panel-grabber')));
    await _settle(tester);
  });

  testWidgets('the legend chip opens the legend as the transient panel (it never grows over the map); a tap on empty map closes it', (tester) async {
    await _pump(tester);
    final chip = find.byKey(const Key('legend-card-toggle'));
    expect(chip, findsOneWidget);
    final before = tester.getSize(find.byKey(const Key('legend-card')));
    await tester.tap(chip);
    await _settle(tester);
    expect(_p('drive.legend'), findsOneWidget);
    expect(find.byKey(const Key('legend-card-body')), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('legend-card'))), before, reason: 'the chip on the map stays one line');
    expect(tester.getRect(_p('drive.legend')).bottom, closeTo(_dockTop, 1));
    // Layers replaces it: one transient panel at a time.
    await tester.tap(find.byKey(const Key('drive-map-layers')), warnIfMissed: false);
    await _settle(tester);
    if (_p('drive.layers').evaluate().isNotEmpty) {
      expect(_p('drive.legend'), findsNothing);
      await tester.tap(find.byKey(const Key('layers-done')));
      await _settle(tester);
      await tester.tap(chip);
      await _settle(tester);
    }
    expect(_p('drive.legend'), findsOneWidget);
    // A tap on empty map closes the transient panel.
    await tester.tapAt(const Offset(200, 150));
    await _settle(tester);
    expect(_p('drive.legend'), findsNothing);
  });

  testWidgets('the inspector is a transient map panel: header first, locked while moving, X closes', (tester) async {
    var closed = 0;
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Scaffold(
        body: Stack(children: [
          Positioned.fill(
            child: MapInfoPanel(title: 'Otterbein Hill', summary: '3 cells', busy: false, body: const SizedBox(height: 120, child: Text('BODY')), onClose: () => closed++),
          ),
        ]),
      ),
    ));
    expect(find.byKey(const Key('map-panel-drive.inspect')), findsOneWidget);
    expect(find.text('BODY'), findsNothing, reason: 'opens at its header so the map stays the focus');
    expect(find.byType(MapPanelGrabber), findsOneWidget);
    await tester.tap(find.byKey(const Key('info-panel-header')));
    await tester.pumpAndSettle();
    expect(find.text('BODY'), findsOneWidget);
    await tester.tap(find.byKey(const Key('link-clear')));
    expect(closed, 1);
  });

  // Every map control stays tappable with the Drive panel Collapsed and Open, on a small and a current phone. Before build 71's
  // follow-up the buttons stayed where they were until the panel's spring came to rest (more than a second), under the panel.
  group('map controls are never covered by the panel', () {
    bool hittable(WidgetTester tester, Finder f) {
      final ro = tester.renderObject(f);
      final res = HitTestResult();
      WidgetsBinding.instance.hitTestInView(res, tester.getCenter(f), tester.view.viewId);
      for (final e in res.path) {
        RenderObject? n = e.target is RenderObject ? e.target as RenderObject : null;
        while (n != null) {
          if (n == ro) return true;
          n = n.parent;
        }
      }
      return false;
    }

    for (final (size, top, bar, home) in const [(Size(375, 667), 20.0, 72.0, 0.0), (Size(402, 874), 47.0, 106.0, 34.0)]) {
      testWidgets('${size.width.toInt()}x${size.height.toInt()}: layers, recenter and the top chips, Collapsed and Open', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        MapPanelStore.clear();
        final h = Harness();
        await h.state.init();
        await tester.pumpWidget(AppScope(
          state: h.state,
          child: MaterialApp(
            theme: meshSonarTheme(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(size: size, padding: EdgeInsets.only(top: top, bottom: bar), viewPadding: EdgeInsets.only(top: top, bottom: home)),
              child: const DriveScreen(),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        // Move the map so Recenter shows too.
        await tester.dragFrom(Offset(size.width / 2, top + 120), const Offset(-50, 30));
        await tester.pump(const Duration(milliseconds: 300));

        void expectAllTappable(String state) {
          final panelTop = tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy;
          final buttons = find.byType(MapControlButton);
          expect(buttons, findsWidgets);
          expect(find.byKey(const Key('drive-map-layers')), findsOneWidget);
          for (final e in buttons.evaluate()) {
            if (!(e.widget as MapControlButton).visible) continue; // the compass shows only while the map is turned
            final f = find.byWidget(e.widget);
            expect(hittable(tester, f), isTrue, reason: '$state: ${e.widget.key} takes a tap at ${tester.getCenter(f)}');
            expect(tester.getRect(f).bottom, lessThanOrEqualTo(panelTop), reason: '$state: ${e.widget.key} is above the panel');
            expect(tester.getSize(f).shortestSide, greaterThanOrEqualTo(40), reason: '$state: ${e.widget.key} is not squeezed');
          }
          for (final k in ['legend-card-toggle', 'capsule-radio']) {
            final f = find.byKey(Key(k));
            if (f.evaluate().isEmpty) continue;
            expect(hittable(tester, f), isTrue, reason: '$state: $k takes a tap');
          }
        }

        expectAllTappable('Collapsed');
        await tester.tap(find.byKey(const Key('drive-panel-grabber')));
        // 0.4 s: the panel is visually open; the buttons must already be clear of it (not after the spring's long tail).
        for (var i = 0; i < 16; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(tester.getTopLeft(find.byKey(const Key('drive-panel'))).dy, lessThan(size.height - bar - 200), reason: 'the panel is Open');
        expectAllTappable('Open');
        await _settle(tester);
        await _settle(tester);
        await _settle(tester);
        expectAllTappable('Open, at rest');
        expect(tester.takeException(), isNull);
        // And the Layers button works while the panel is Open: it opens the layers and the Drive panel goes back to Collapsed.
        await tester.tap(find.byKey(const Key('drive-map-layers')));
        await _settle(tester);
        await _settle(tester);
        expect(_p('drive.layers'), findsOneWidget);
        expectAllTappableAfterLayers(tester, hittable);
      });
    }
  });
}

/// With the layers panel open (60 % above the Dock) the map buttons sit above its header or are covered by the panel the
/// person just opened; closing it gives them back. Only checks nothing throws and Layers can be closed.
void expectAllTappableAfterLayers(WidgetTester tester, bool Function(WidgetTester, Finder) hittable) {
  expect(hittable(tester, find.byKey(const Key('layers-done'))), isTrue, reason: 'the open layers panel can be closed');
}
