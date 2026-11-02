// Drive plan 4.19 regression test 3: the ghosted double text. In the Drive tree no two Text widgets with different owners paint
// overlapping rects (map labels are painted by a CustomPainter and are not Text widgets, so they are excluded by construction),
// and after opening and closing the Layers sheet and the Credits sheet while driving, the colour-key words are found nowhere
// outside a sheet. Also pins the root cause (WP2 step 0): the old credit stack was 203 pt tall in a 176 pt pane.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart' show FlutterMap;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/ui/drive/drive_controls.dart' show DriveStatsStrip;
import 'package:meshsonar/ui/map/overlays/map_overlay_host.dart';

import '../drive_redesign_test.dart' show driving, heardRow, settle, drain;
import '../fakes.dart';

/// Pairs of visible Text widgets (under [root]) whose painted rects overlap by more than a sliver.
List<String> overlappingTexts(WidgetTester tester, Finder root) {
  // Map labels (Text widgets inside the FlutterMap's marker layers) belong to the map and are excluded.
  final labels = find.descendant(of: root, matching: find.descendant(of: find.byType(FlutterMap), matching: find.byType(Text))).evaluate().toSet();
  final texts = find.descendant(of: root, matching: find.byType(Text)).evaluate().where((e) => !labels.contains(e)).toList();
  final rects = <(String, Rect, Element)>[];
  for (final e in texts) {
    final w = e.widget as Text;
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final data = w.data ?? w.textSpan?.toPlainText() ?? '';
    if (data.trim().isEmpty) continue;
    // Skip offstage routes.
    var offstage = false;
    e.visitAncestorElements((a) {
      if (a.widget is Offstage && (a.widget as Offstage).offstage) {
        offstage = true;
        return false;
      }
      return true;
    });
    if (offstage) continue;
    rects.add((data, MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size), e));
  }
  final out = <String>[];
  for (var i = 0; i < rects.length; i++) {
    for (var j = i + 1; j < rects.length; j++) {
      final a = rects[i].$2.deflate(1), b = rects[j].$2.deflate(1);
      if (a.isEmpty || b.isEmpty || !a.overlaps(b)) continue;
      // A Text and its own ancestor Text (rich nesting) share an owner.
      if (_related(rects[i].$3, rects[j].$3)) continue;
      out.add('"${rects[i].$1}" ${rects[i].$2} overlaps "${rects[j].$1}" ${rects[j].$2}');
    }
  }
  return out;
}

bool _related(Element a, Element b) {
  var rel = false;
  a.visitAncestorElements((x) {
    if (identical(x, b)) rel = true;
    return !rel;
  });
  return rel;
}

void main() {
  testWidgets('root cause pinned: the old stack (203 pt) could not fit a 176 pt pane; the host clips every slot to its rect', (tester) async {
    tester.view.physicalSize = const Size(402, 176);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The legend that used to be stacked bottom-left: four stacked blocks totalling 203 pt in a 176 pt pane.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MapOverlayHost(
          map: const ColoredBox(color: Colors.grey),
          banner: const SizedBox(height: 56, width: double.infinity, child: Text('GPS good')),
          bottom: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 4; i++) SizedBox(key: Key('legacy$i'), height: 203 / 4, width: 300, child: Text('Coverage cells $i'))]),
          attribution: const SizedBox(width: 160, height: 18),
        ),
      ),
    ));
    await tester.pump();
    final banner = tester.getRect(find.text('GPS good'));
    for (var i = 0; i < 4; i++) {
      expect(tester.getRect(find.byKey(Key('legacy$i'))).top, greaterThanOrEqualTo(banner.bottom - 0.5), reason: 'never paints up into the banner');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('driving: no overlapping Text, and the colour key never leaks out of its sheet', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);
    expect(heardRow('a1b2'), findsOneWidget);
    expect(overlappingTexts(tester, find.byKey(const Key('drive-map'))), isEmpty);

    // Credits sheet open then closed.
    await tester.tap(find.byKey(const Key('map-attribution-info')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('credits-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('credits-sheet')), findsNothing);
    expect(find.text('Coverage cells', findRichText: true), findsNothing);
    expect(find.textContaining('Coverage cells ·'), findsNothing);
    expect(overlappingTexts(tester, find.byKey(const Key('drive-map'))), isEmpty);

    // Layers sheet open then closed.
    await tester.tap(find.byKey(const Key('drive-map-layers')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('layers-sheet')), findsNothing);
    expect(find.textContaining('Coverage cells ·'), findsNothing);
    expect(overlappingTexts(tester, find.byKey(const Key('drive-map'))), isEmpty);
    await h.state.stopDrive();
    await drain(tester);
  });

  testWidgets('expanded and back: still no overlapping Text, and the footer collapses to status + buttons', (tester) async {
    final h = await driving(tester);
    h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5)]));
    await settle(tester);
    await tester.tap(find.byKey(const Key('map-fullscreen')));
    await settle(tester);
    expect(find.byKey(const Key('fullscreen-close')), findsOneWidget);
    expect(find.byKey(const Key('start-stop')), findsOneWidget);
    expect(find.byType(DriveStatsStrip), findsNothing, reason: 'the footer stat strips collapse');
    expect(overlappingTexts(tester, find.byKey(const Key('drive-map'))), isEmpty);
    await h.state.stopDrive();
    await drain(tester);
  });
}
