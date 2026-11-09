// Every map in the app shows its tile credit without interaction (OSM Attribution Guidelines; unified map plan M0, audit 03
// table 1.0 found 11 mini maps without one). Source-level: each file that builds a FlutterMap must also draw a credit
// (MiniMapCredit, the Drive map's AttributionLine, flutter_map's RichAttributionWidget or a visible "OpenStreetMap" line).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every FlutterMap in lib/ draws a map credit', () {
    final credit = RegExp(r'MiniMapCredit\(|AttributionLine\(|RichAttributionWidget\(|OpenStreetMap contributors');
    final missing = <String>[];
    var maps = 0;
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (!src.contains('FlutterMap(')) continue;
      maps++;
      if (!credit.hasMatch(src)) missing.add(f.path);
    }
    expect(maps, greaterThan(5), reason: 'the scan found the maps');
    expect(missing, isEmpty, reason: 'maps without a visible credit');
  });

  test('the mini map credit is the OSM line of the base maps', () {
    final src = File('lib/ui/map/overlays/mini_map_credit.dart').readAsStringSync();
    expect(src, contains('BaseMapStyle.chart.attribution'));
  });
}
