// The layers sheet shows the global repeater layer's credit once, with its age on the same line.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/layers/layers_sheet.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';


Widget _wrap(MapRepeaterSet s) => MaterialApp(home: Scaffold(body: NetworkAgeLegend(set: s)));

void main() {
  testWidgets('credit and as-of are one line', (tester) async {
    await tester.pumpWidget(_wrap(MapRepeaterSet(
      rows: const [],
      state: MapFeedState.ready,
      asOf: DateTime.utc(2026, 10, 30, 12),
      attribution: 'Data: MeshCore Map (map.meshcore.io)',
    )));
    expect(find.textContaining('MeshCore Map'), findsOneWidget);
    expect(find.textContaining('as of'), findsOneWidget);
    expect(find.textContaining('Data: MeshCore Map (map.meshcore.io), as of'), findsOneWidget);
  });

  testWidgets('credit alone, and as-of alone, still show', (tester) async {
    await tester.pumpWidget(_wrap(const MapRepeaterSet(
        rows: [], state: MapFeedState.ready, attribution: 'Data: MeshCore Map (map.meshcore.io)')));
    expect(find.text('Data: MeshCore Map (map.meshcore.io)'), findsOneWidget);
    await tester.pumpWidget(_wrap(MapRepeaterSet(rows: const [], state: MapFeedState.ready, asOf: DateTime.utc(2026, 10, 30))));
    expect(find.textContaining('MeshCore Map data as of'), findsOneWidget);
  });
}
