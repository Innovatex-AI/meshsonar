// Legend & Info: every section explains what it shows with the real swatches, follows the colour mode and the colour
// palette, is reachable from the layers sheet and Settings > About, and its swatch colours equal the colours the maps draw.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/network_coverage.dart';
import 'package:meshsonar/ui/claims/claim_widgets.dart';
import 'package:meshsonar/ui/map/coverage_layer_controls.dart' show coverageLegend;
import 'package:meshsonar/ui/map/coverage_map.dart' show networkLevelColor;
import 'package:meshsonar/ui/map/layers/layers_sheet.dart' show NetworkAgeLegend;
import 'package:meshsonar/ui/map/legend_sheet.dart';
import 'package:meshsonar/ui/map/map_layers.dart' show PingColorMode;
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';

Future<void> pumpLegend(
  WidgetTester tester, {
  Brightness brightness = Brightness.dark,
  ColourPalette palette = ColourPalette.standard,
  CoverageColorBy colorBy = CoverageColorBy.snr,
  PingColorMode pingColors = PingColorMode.snr,
  double textScale = 1.0,
  Size size = const Size(420, 4000),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(brightness, palette: palette),
    home: MediaQuery(
      data: MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(body: MapLegendSheet(colorBy: colorBy, pingColors: pingColors)),
    ),
  ));
  await tester.pumpAndSettle();
}

Color swatchColor(WidgetTester tester, String id) =>
    tester.widget<LegendSwatch>(find.descendant(of: find.byKey(Key('legend-swatch-$id')), matching: find.byType(LegendSwatch))).color;

MeshSonarColors colours(WidgetTester tester) => MeshSonarColors.of(tester.element(find.byKey(const Key('legend-sheet'))));

void main() {
  group('sections', () {
    testWidgets('all eight sections are there, in order, with headers', (tester) async {
      await pumpLegend(tester);
      for (final id in ['pings', 'cells', 'repeaters', 'links', 'observers', 'heard', 'owned', 'why']) {
        expect(find.byKey(Key('legend-section-$id')), findsOneWidget, reason: id);
      }
      expect(find.text('Map legend'), findsOneWidget);
      expect(find.byKey(const Key('legend-palette-note')), findsOneWidget);
      final ys = [for (final id in ['pings', 'cells', 'repeaters', 'links', 'observers', 'heard', 'owned', 'why']) tester.getTopLeft(find.byKey(Key('legend-section-$id'))).dy];
      expect([...ys]..sort(), ys);
    });

    testWidgets('your pings: strength scale, grey = nothing heard, purple = heard but no signal reading', (tester) async {
      await pumpLegend(tester);
      final mc = colours(tester);
      expect(swatchColor(tester, 'ping-strong'), mc.forPing(heard: true, snr: 10));
      expect(swatchColor(tester, 'ping-mid'), mc.forPing(heard: true, snr: 0));
      expect(swatchColor(tester, 'ping-weak'), mc.forPing(heard: true, snr: -10));
      expect(swatchColor(tester, 'ping-silent'), mc.silent);
      expect(swatchColor(tester, 'ping-unknown'), mc.heardUnknown);
      expect(find.text('Grey: nothing heard'), findsOneWidget);
      expect(find.text('Purple: heard, no signal reading'), findsOneWidget);
      expect(find.byKey(const Key('legend-ping-gradient')), findsOneWidget);
    });

    testWidgets('your pings in Heard / not mode: one heard colour, grey, no purple row', (tester) async {
      await pumpLegend(tester, pingColors: PingColorMode.result);
      final mc = colours(tester);
      expect(swatchColor(tester, 'ping-heard'), mc.snrStrong);
      expect(swatchColor(tester, 'ping-silent'), mc.silent);
      expect(find.byKey(const Key('legend-row-ping-unknown')), findsNothing);
      expect(find.byKey(const Key('legend-ping-gradient')), findsNothing);
    });

    for (final by in CoverageColorBy.values) {
      testWidgets('network cells follow the colour mode: ${by.name}', (tester) async {
        await pumpLegend(tester, colorBy: by);
        final expected = coverageLegend(by);
        for (final (level, _) in expected) {
          expect(find.byKey(Key('legend-row-cell-${level.name}')), findsOneWidget, reason: '${by.name} ${level.name}');
        }
        // levels this mode never uses are not listed
        for (final level in CoverageLevel.values) {
          if (!expected.any((e) => e.$1 == level)) expect(find.byKey(Key('legend-row-cell-${level.name}')), findsNothing);
        }
        expect(find.byKey(const Key('legend-row-cell-faded')), findsOneWidget);
        expect(find.textContaining('fewer than 3 pings'), findsWidgets);
        if (by == CoverageColorBy.snr) {
          expect(find.text('Strong: +5 dB or better'), findsOneWidget);
          expect(find.text('Good: 0 to +5'), findsOneWidget);
          expect(find.text('Fair: -5 to 0'), findsOneWidget);
          expect(find.text('Weak: below -5'), findsOneWidget);
          expect(find.text('Purple: heard, signal unknown'), findsOneWidget);
          expect(find.text('Grey: mapped, nothing heard'), findsOneWidget);
        }
        if (by == CoverageColorBy.heard) expect(find.text('Strong: 75%+ heard'), findsOneWidget);
        if (by == CoverageColorBy.noise) {
          expect(find.text('Strong: quiet, under -125 dBm'), findsOneWidget);
          expect(find.byKey(const Key('legend-noise-note')), findsOneWidget);
        }
      });
    }

    testWidgets('the colour-by chips switch the cell legend in place', (tester) async {
      await pumpLegend(tester);
      expect(find.text('Strong: +5 dB or better'), findsOneWidget);
      await tester.tap(find.byKey(const Key('legend-colour-by-noise')));
      await tester.pumpAndSettle();
      expect(find.text('Strong: +5 dB or better'), findsNothing);
      expect(find.text('Strong: quiet, under -125 dBm'), findsOneWidget);
    });

    testWidgets('repeaters: the four advert ages, the amber tower and room-server ring', (tester) async {
      await pumpLegend(tester);
      expect(find.text('Within the last 24 hours'), findsOneWidget);
      expect(find.text('Within the last 7 days'), findsOneWidget);
      expect(find.text('Within the last 30 days'), findsOneWidget);
      expect(find.text('Older than 30 days'), findsOneWidget);
      final ctx = tester.element(find.byKey(const Key('legend-sheet')));
      for (final (level, _) in NetworkAgeLegend.steps) {
        expect(swatchColor(tester, 'age-${level.name}'), networkLevelColor(ctx, level));
      }
      expect(find.textContaining('room servers'), findsOneWidget);
    });

    testWidgets('link lines: orange and solid in the standard palette; the label is the best SNR', (tester) async {
      await pumpLegend(tester);
      expect(find.text('Orange line: who heard what'), findsOneWidget);
      expect(find.textContaining('best signal (SNR)'), findsOneWidget);
      final p = tester.widget<CustomPaint>(find.descendant(of: find.byKey(const Key('legend-link-sample')), matching: find.byType(CustomPaint))).painter! as LinkSamplePainter;
      expect(p.line, const Color(0xFFFF6D00));
      expect(p.dashed, isFalse);
    });

    for (final pal in [ColourPalette.colourBlind, ColourPalette.highContrast]) {
      testWidgets('link lines in ${pal.id}: dashed, not orange', (tester) async {
        await pumpLegend(tester, palette: pal);
        expect(find.text('Dashed line: who heard what'), findsOneWidget);
        final p = tester.widget<CustomPaint>(find.descendant(of: find.byKey(const Key('legend-link-sample')), matching: find.byType(CustomPaint))).painter! as LinkSamplePainter;
        expect(p.dashed, isTrue);
        expect(p.line, colours(tester).linkLine);
        expect(p.line, isNot(const Color(0xFFFF6D00)));
      });
    }

    testWidgets('observers: filled when online, hollow grey when offline', (tester) async {
      await pumpLegend(tester);
      expect(find.text('Filled triangle: observer online'), findsOneWidget);
      expect(find.text('Hollow grey triangle: offline'), findsOneWidget);
      final tri = tester.widgetList<CustomPaint>(find.descendant(of: find.byKey(const Key('legend-section-observers')), matching: find.byType(CustomPaint))).map((c) => c.painter.runtimeType.toString());
      expect(tri.where((n) => n == '_TriPainter'), hasLength(2));
    });

    testWidgets('heard box: bright, dimmer and faint bars', (tester) async {
      await pumpLegend(tester);
      expect(find.text('Bright bar: heard recently'), findsOneWidget);
      expect(find.text('Dimmer bar: missed a ping or two'), findsOneWidget);
      expect(find.text('Faint grey bar: not heard for a while'), findsOneWidget);
      expect(swatchColor(tester, 'heard-fresh'), colours(tester).forPing(heard: true, snr: 5));
    });

    testWidgets('owned by you: the real chip and what it means', (tester) async {
      await pumpLegend(tester);
      expect(find.descendant(of: find.byKey(const Key('legend-section-owned')), matching: find.byType(OwnedByYouChip)), findsOneWidget);
      expect(find.textContaining('claimed with this phone'), findsOneWidget);
    });

    testWidgets('why lines open: hexagon, grey cell, SNR, faded', (tester) async {
      await pumpLegend(tester);
      for (final (id, snippet) in [('hexagon', 'small hexagonal cells'), ('grey', 'it marks a gap'), ('snr', 'Signal-to-noise ratio'), ('faded', 'fewer than 3 pings is drawn fainter')]) {
        await tester.ensureVisible(find.byKey(Key('legend-why-$id')));
        await tester.tap(find.byKey(Key('legend-why-$id')));
        await tester.pumpAndSettle();
        expect(find.textContaining(snippet), findsOneWidget, reason: id);
      }
    });
  });

  group('accessibility', () {
    testWidgets('every row is one spoken item that says what the colour means', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLegend(tester);
      expect(tester.getSemantics(find.byKey(const Key('legend-row-ping-silent'))).label, contains('Grey: nothing heard'));
      expect(tester.getSemantics(find.byKey(const Key('legend-row-cell-unknown'))).label, contains('Purple: heard, signal unknown'));
      expect(tester.getSemantics(find.byKey(const Key('legend-row-cell-faded'))).label, contains('fewer than 3 pings'));
      handle.dispose();
    });

    testWidgets('rows and why tiles are at least 48 px tall, swatches are not read aloud', (tester) async {
      await pumpLegend(tester);
      for (final k in tester.widgetList(find.byWidgetPredicate((w) => w.key is Key && (w.key.toString().contains('legend-row-'))))) {
        final r = tester.getSize(find.byWidget(k));
        expect(r.height, greaterThanOrEqualTo(48), reason: '${k.key}');
      }
      for (final id in ['hexagon', 'grey', 'snr', 'faded']) {
        expect(tester.getSize(find.byKey(Key('legend-why-$id'))).height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('largest Dynamic Type: nothing overflows, text wraps', (tester) async {
      await pumpLegend(tester, textScale: 2.5, size: const Size(360, 6000));
      expect(tester.takeException(), isNull);
      expect(find.text('Grey: mapped, nothing heard'), findsOneWidget);
    });

    testWidgets('section headers are headers', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpLegend(tester);
      expect(find.bySemanticsLabel('Your pings'), findsWidgets);
      handle.dispose();
    });
  });

  group('swatches are the colours the map uses', () {
    for (final b in Brightness.values) {
      for (final pal in ColourPalette.values) {
        testWidgets('${pal.id} ${b.name}', (tester) async {
          await pumpLegend(tester, brightness: b, palette: pal);
          final ctx = tester.element(find.byKey(const Key('legend-sheet')));
          final mc = MeshSonarColors.of(ctx);
          expect(mc.palette, pal);
          for (final (level, _) in coverageLegend(CoverageColorBy.snr)) {
            expect(swatchColor(tester, 'cell-${level.name}'), networkLevelColor(ctx, level), reason: level.name);
          }
          expect(swatchColor(tester, 'cell-none'), mc.silent);
          expect(swatchColor(tester, 'cell-unknown'), mc.heardUnknown);
          expect(swatchColor(tester, 'ping-strong'), mc.forPing(heard: true, snr: 25));
          expect(swatchColor(tester, 'ping-weak'), mc.forPing(heard: true, snr: -25));
        });
      }
    }

    // The real map: put cells on the Drive map, read the polygons it draws, and compare with the legend opened from the
    // layers sheet in the same app, under each palette.
    for (final pal in ColourPalette.values) {
      testWidgets('on the real map, palette ${pal.id}: polygon colours == legend swatches', (tester) async {
        useTallScreen(tester);
        final h = Harness();
        h.settings.saved = Settings(colourPalette: pal);
        h.client.publicCoverageResult = PublicCoverage(
          asOf: '2026-10-20T12:00:00Z',
          grid: const CoverageGrid.square(cellDeg: 0.005),
          cells: const [
            CoverageCell(lat: 39.9612, lon: -82.9988, pings: 10, heard: 8, bestSnr: 6.0, medianSnr: 4.0, repeaters: 2, lastAt: '2026-10-20T11:00:00Z'),
            CoverageCell(lat: 39.97, lon: -83.01, pings: 5, heard: 1, bestSnr: -8.0, medianSnr: -8.0, repeaters: 1, lastAt: '2026-10-20T10:00:00Z'),
          ],
        );
        await h.pumpApp(tester);
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final polys = [
          for (final w in tester.widgetList(find.byType(PolygonLayer))) ...(w as PolygonLayer).polygons,
        ];
        expect(polys, hasLength(2));
        Color solid(Color c) => c.withValues(alpha: 1);
        final onMap = {solid(polys[0].borderColor), solid(polys[1].borderColor)};

        await tester.tap(find.byKey(const Key('drive-map-layers')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('layers-legend')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('legend-sheet')), findsOneWidget);
        expect(onMap, {swatchColor(tester, 'cell-strong'), swatchColor(tester, 'cell-weak')});
        // and the palette note names the palette in use
        expect(find.textContaining(pal.label), findsWidgets);
      });
    }
  });

  group('reachable', () {
    testWidgets('from the info icon in the layers sheet header; opens on the map\'s current colour mode', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tester.tap(find.byKey(const Key('drive-map-layers')));
      await tester.pumpAndSettle();
      final icon = find.byKey(const Key('layers-legend'));
      expect(icon, findsOneWidget);
      expect(tester.getSize(icon).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(icon).height, greaterThanOrEqualTo(48));
      await tester.tap(icon);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legend-sheet')), findsOneWidget);
      expect(find.text('Strong: +5 dB or better'), findsOneWidget);
    });

    testWidgets('from Settings > About > Map legend', (tester) async {
      useTallScreen(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await openSettingsTab(tester);
      await tester.pumpAndSettle();
      final list = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
      await tester.scrollUntilVisible(find.byKey(const Key('map-legend')), 200, scrollable: list);
      await tester.ensureVisible(find.byKey(const Key('map-legend')));
      await tester.pumpAndSettle();
      expect(tester.getSize(find.byKey(const Key('map-legend'))).height, greaterThanOrEqualTo(48));
      await tester.tap(find.byKey(const Key('map-legend')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legend-sheet')), findsOneWidget);
    });
  });
}
