// Drive plan 4.19 regression test 2: every overlay surface the map hosts paints an opaque (alpha 1.0) fill, so whatever sits
// behind it can never show through as a ghost. Exemptions, by design and listed here: the attribution line's 0.88 surface pill on
// Street and Topo (plan section 8), the map labels (MapTag, drawn on the map not over a surface), and the tab bar blur.
// Known and deferred to Drive WP3b: MapIconButton (ui/drive/drive_controls.dart, owned by WP8) and the dock/footer widgets.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/gps_health.dart';
import 'package:meshsonar/core/startup_location.dart';
import 'package:meshsonar/ui/drive/gps_health_banner.dart';
import 'package:meshsonar/ui/drive/heard_box.dart';
import 'package:meshsonar/ui/map/map_info_panel.dart';
import 'package:meshsonar/ui/map/map_layers.dart';
import 'package:meshsonar/ui/map/parts/map_chips.dart';
import 'package:meshsonar/ui/map/parts/simulated_tag.dart';
import 'package:meshsonar/ui/theme.dart';

/// Fill colours painted by [root]'s subtree whose alpha is neither 0 (nothing) nor 1 (opaque).
List<String> translucentFills(WidgetTester tester, Finder root) {
  final out = <String>[];
  void check(String what, Color? c) {
    if (c == null) return;
    final a = c.a;
    if (a > 0.001 && a < 0.999) out.add('$what alpha ${a.toStringAsFixed(2)}');
  }

  for (final e in find.descendant(of: root, matching: find.byWidgetPredicate((_) => true)).evaluate()) {
    final w = e.widget;
    if (w is DecoratedBox) {
      final d = w.decoration;
      if (d is BoxDecoration) check('DecoratedBox', d.color);
    } else if (w is Material) {
      check('Material', w.color);
    } else if (w is ColoredBox) {
      check('ColoredBox', w.color);
    }
  }
  return out;
}

void main() {
  Future<void> pump(WidgetTester tester, Widget child, {Brightness b = Brightness.light}) =>
      tester.pumpWidget(MaterialApp(theme: meshSonarTheme(b), home: Scaffold(body: Center(child: child))));

  for (final b in Brightness.values) {
    testWidgets('GPS banner, Heard box, info panel, pill and SIMULATED tag are opaque (${b.name})', (tester) async {
      final health = computeGpsHealth(
        sinceStart: const Duration(seconds: 3),
        fixAge: null,
        accuracyM: null,
        haveUsableFix: false,
        access: LocationAccess.approximate,
        background: BackgroundLocation.notApplicable,
      );
      await pump(tester, GpsHealthView(health: health), b: b);
      expect(find.byType(GpsHealthView), findsOneWidget);
      expect(translucentFills(tester, find.byType(GpsHealthView)), isEmpty, reason: 'GPS banner');

      await pump(
        tester,
        HeardBox(
          heard: [
            HeardView(id: 'a1b2', label: 'A1B2', snrDb: 5, bestSnrDb: 5, timesHeard: 1, phase: HeardPhase.fresh, pingsAgo: 0, holdLeft: 3, lastPingIndex: 1),
          ],
          holdPings: 3,
          onSelect: (_) {},
          driving: true,
        ),
        b: b,
      );
      expect(translucentFills(tester, find.byKey(const Key('heard-box'))), isEmpty, reason: 'Heard box');

      await pump(tester, MapInfoPanel(title: 't', summary: 's', busy: false, body: const SizedBox(height: 20), onClose: () {}), b: b);
      expect(translucentFills(tester, find.byType(MapInfoPanel)), isEmpty, reason: 'info panel');

      await pump(tester, const MapPill(child: Text('pill')), b: b);
      expect(translucentFills(tester, find.byType(MapPill)), isEmpty, reason: 'pill');

      await pump(tester, const SimulatedTag(), b: b);
      expect(translucentFills(tester, find.byType(SimulatedTag)), isEmpty, reason: 'SIMULATED tag');
    });
  }

  testWidgets('the detector sees a translucent fill (guards the guard)', (tester) async {
    await pump(tester, DecoratedBox(decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.9)), child: const SizedBox(width: 10, height: 10)));
    expect(translucentFills(tester, find.byType(Scaffold)), isNotEmpty);
  });
}
