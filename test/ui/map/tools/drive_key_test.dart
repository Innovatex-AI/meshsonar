// The drive key (MAP slice 6, app half): the five band discs of the ACTIVE palette read from the definition, No reply, "outlined", and
// the hidden-part / zone swatches that exist only when `symbols.tools` does; light and dark.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/colour_palette.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/ui/map/coverage_bands.dart';
import 'package:meshsonar/ui/map/tools/drive_key.dart';

import '../../../support/tool_definition.dart';

Future<void> pump(WidgetTester t, Widget w, Brightness b) => t.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: b),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: 320, child: w))),
    ));

List<Color> discs(WidgetTester t, String key) => [
      for (final c in t.widgetList<Container>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Container))))
        if ((c.decoration as BoxDecoration?)?.shape == BoxShape.circle) (c.decoration as BoxDecoration).color!,
    ];

void main() {
  for (final b in [Brightness.light, Brightness.dark]) {
    testWidgets('${b.name}: five band discs, No reply, outlined, hidden part and zone from the definition', (t) async {
      final def = liveToolDefinition();
      await pump(t, DriveKey(hiddenPart: true, zones: 1, definition: def), b);
      final c = CoverageBandColors.of(ColourPalette.standard, b, definition: def);
      expect(discs(t, 'drive-key-bands'), [for (var i = 1; i <= 5; i++) c[i]]);
      expect(discs(t, 'drive-key-noreply'), [c.noReplyPoint]);
      expect(find.text('Ping a repeater answered: its colour is the SNR band, the same as the cells'), findsOneWidget);
      expect(find.text('Ping nobody answered'), findsOneWidget);
      expect(find.text('Outlined: this drive'), findsOneWidget);
      expect(find.text('Hidden from the public: faded and dashed'), findsOneWidget);
      expect(find.text('Privacy zone'), findsOneWidget);
      expect(find.byKey(const Key('drive-key-hidden')), findsOneWidget);
      expect(find.byKey(const Key('drive-key-zone')), findsOneWidget);
    });
  }

  testWidgets('more than one zone is plural; no hidden part and no zones draw neither item', (t) async {
    final def = liveToolDefinition();
    await pump(t, DriveKey(zones: 3, definition: def), Brightness.light);
    expect(find.text('Privacy zones'), findsOneWidget);
    expect(find.byKey(const Key('drive-key-hidden')), findsNothing);
    await pump(t, DriveKey(definition: def), Brightness.light);
    expect(find.byKey(const Key('drive-key-zone')), findsNothing);
  });

  testWidgets('a definition without symbols.tools keeps the ping discs and drops the two tool swatches', (t) async {
    await pump(t, DriveKey(hiddenPart: true, zones: 2, definition: MapDefinition.bundled), Brightness.light);
    expect(find.byKey(const Key('drive-key-bands')), findsOneWidget);
    expect(find.byKey(const Key('drive-key-hidden')), findsNothing);
    expect(find.byKey(const Key('drive-key-zone')), findsNothing);
  });

  testWidgets('zones only (the editor): no ping discs', (t) async {
    await pump(t, DriveKey(dots: false, zones: 1, definition: liveToolDefinition()), Brightness.dark);
    expect(find.byKey(const Key('drive-key-bands')), findsNothing);
    expect(find.byKey(const Key('drive-key-zone')), findsOneWidget);
  });

  testWidgets('nothing to say draws nothing', (t) async {
    await pump(t, DriveKey(dots: false, zones: 1, definition: MapDefinition.bundled), Brightness.light);
    expect(find.byKey(const Key('drive-key')), findsNothing);
  });
}
