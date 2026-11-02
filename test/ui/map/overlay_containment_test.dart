// Drive plan 4.19 regression test 1: every overlay slot, in every size x text scale, holds its child inside its own rect, and
// the slot rects never overlap each other (the old lower-left stack grew past its pane and painted into the GPS banner and
// the Heard box; that is what produced the ghosted double text). The toast band is the one allowed overlap (4.18).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/overlays/map_overlay_host.dart';

const _sizes = [Size(402, 176), Size(402, 874), Size(375, 667), Size(834, 1210), Size(1210, 834)];
const _scales = [1.0, 2.0, 3.1]; // 3.1 = AX3

Rect _slotRect(WidgetTester tester, Finder child) {
  Rect? out;
  tester.element(child).visitAncestorElements((e) {
    if (e.widget is ClipRect) {
      out = tester.getRect(find.byElementPredicate((x) => identical(x, e)));
      return false;
    }
    return true;
  });
  return out!;
}

void main() {
  testWidgets('no bottom-leading slot exists: nothing can be parked in the lower-left corner', (tester) async {
    expect(MapSlot.values.map((s) => s.name), unorderedEquals(['banner', 'topLeading', 'topTrailing', 'toast', 'controls', 'attribution', 'bottom']));
  });

  for (final size in _sizes) {
    for (final scale in _scales) {
      testWidgets('slots stay inside their rects and disjoint at ${size.width.toInt()}x${size.height.toInt()}, text x$scale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Widget box(String k, double w, double h) => SizedBox(key: Key(k), width: w, height: h, child: const ColoredBox(color: Colors.blue));
        await tester.pumpWidget(MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: MapOverlayHost(
                map: const ColoredBox(color: Colors.grey),
                banner: SizedBox(key: const Key('banner'), width: double.infinity, height: 56 * scale.clamp(1, 2)),
                topLeading: box('lead', 260, 600),
                topTrailing: Column(key: const Key('trail'), mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < 6; i++) box('t$i', 46, 46)]),
                controls: Column(key: const Key('ctrl'), mainAxisSize: MainAxisSize.min, children: [box('c0', 40, 40), box('c1', 40, 40), box('c2', 40, 40)]),
                bottom: Column(key: const Key('bottom'), mainAxisSize: MainAxisSize.min, children: [box('b0', 360, 90), box('b1', 360, 90), box('b2', 360, 90)]),
                attribution: SizedBox(key: const Key('attr'), width: 220, height: 18.0 * scale.clamp(1, 2)),
              ),
            ),
          ),
        ));
        await tester.pump();
        final host = tester.getRect(find.byType(MapOverlayHost));
        final named = <String, Rect>{};
        for (final k in ['banner', 'lead', 'trail', 'ctrl', 'bottom']) {
          // A slot squeezed to nothing by the others (a 176 pt pane) drops its content rather than overflow.
          if (find.byKey(Key(k)).evaluate().isEmpty) continue;
          final slot = _slotRect(tester, find.byKey(Key(k)));
          final child = tester.getRect(find.byKey(Key(k)));
          expect(slot.left, greaterThanOrEqualTo(host.left - 0.5), reason: '$k slot inside host');
          expect(slot.right, lessThanOrEqualTo(host.right + 0.5), reason: '$k slot inside host');
          expect(slot.bottom, lessThanOrEqualTo(host.bottom + 0.5), reason: '$k slot inside host');
          expect(child.left, greaterThanOrEqualTo(slot.left - 0.5), reason: '$k child inside its slot');
          expect(child.top, greaterThanOrEqualTo(slot.top - 0.5), reason: '$k child inside its slot');
          expect(child.right, lessThanOrEqualTo(slot.right + 0.5), reason: '$k child inside its slot');
          expect(child.bottom, lessThanOrEqualTo(slot.bottom + 0.5), reason: '$k child inside its slot');
          named[k] = slot;
        }
        named['attr'] = tester.getRect(find.byKey(const Key('attr')));
        final keys = named.keys.toList();
        for (var i = 0; i < keys.length; i++) {
          for (var j = i + 1; j < keys.length; j++) {
            final a = named[keys[i]]!, b = named[keys[j]]!;
            if (a.isEmpty || b.isEmpty) continue;
            expect(a.deflate(0.5).overlaps(b.deflate(0.5)), isFalse, reason: '${keys[i]} $a overlaps ${keys[j]} $b');
          }
        }
        expect(named['attr']!.right, closeTo(host.right - kOverlayMargin, 0.5), reason: 'attribution is bottom-right');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
