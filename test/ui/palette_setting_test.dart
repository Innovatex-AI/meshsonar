// Settings > Units & display > Colour palette: three choices, persisted, applied to the whole app at once (the theme's
// MeshSonarColors changes and the network cells on the real map are redrawn in the new colours without a restart).
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/ui/settings/display_section.dart';
import 'package:meshsonar/ui/theme.dart';

import 'fakes.dart';
import 'settings_controls_test.dart' show openSettings, show;

void main() {
  testWidgets('three options, standard selected by default, strips show the real colours', (tester) async {
    await openSettings(tester);
    await show(tester, 'colour-palette-standard');
    for (final p in ColourPalette.values) {
      expect(find.byKey(Key('colour-palette-${p.id}')), findsOneWidget);
      expect(tester.getSize(find.byKey(Key('colour-palette-${p.id}'))).height, greaterThanOrEqualTo(56));
    }
    expect(find.text('Colour-blind safe'), findsOneWidget);
    expect(find.text('High contrast'), findsOneWidget);
    expect(tester.widget<ListTile>(find.byKey(const Key('colour-palette-standard'))).selected, isTrue);
    expect(find.byType(PaletteStrip), findsNWidgets(3));
  });

  testWidgets('picking a palette is saved and recolours the map cells at once', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    h.client.publicCoverageResult = PublicCoverage(
      asOf: '2026-10-20T12:00:00Z',
      grid: const CoverageGrid.square(cellDeg: 0.005),
      cells: const [
        CoverageCell(lat: 39.9612, lon: -82.9988, pings: 10, heard: 8, bestSnr: 6.0, medianSnr: 4.0, repeaters: 2, lastAt: '2026-10-20T11:00:00Z'),
      ],
    );
    await h.pumpApp(tester);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    Color cell() => [for (final w in tester.widgetList(find.byType(PolygonLayer))) ...(w as PolygonLayer).polygons].single.borderColor;
    MeshSonarColors theme() => Theme.of(tester.element(find.byType(Scaffold).first)).extension<MeshSonarColors>()!;
    final before = cell();
    expect(theme().palette, ColourPalette.standard);

    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    final list = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('colour-palette-colour_blind')), 150, scrollable: list);
    await tester.ensureVisible(find.byKey(const Key('colour-palette-colour_blind')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('colour-palette-colour_blind')));
    await tester.pumpAndSettle();

    expect(h.settings.saved.colourPalette, ColourPalette.colourBlind);
    expect(theme().palette, ColourPalette.colourBlind);
    expect(tester.widget<ListTile>(find.byKey(const Key('colour-palette-colour_blind'))).selected, isTrue);
    // Back on the Drive tab the same cell is drawn in the new strength colour.
    await openDriveTab(tester);
    await tester.pumpAndSettle();
    expect(cell(), isNot(before));
    expect(cell().withValues(alpha: 1), theme().levelStrong);
  });
}
