// MAP slice 5 (app half): the path style the app reads from `symbols.path` of Map Definition v2 (live answer of Nov 22 2026),
// and that a definition without the block answers null (every caller then draws what build 73 drew).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_path_style.dart';

MapDefinition _minor7() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());

void main() {
  test('reads the live symbols.path block', () {
    final s = MapPathStyle.of(_minor7())!;
    expect(s.v, 1);
    expect(s.widthPx, 3.5);
    expect(s.dash, [2, 2]);
    expect(s.discRadiusPx, 9);
    expect(s.numberPx, 11);
    expect(s.label, '{n} · {name}');
    expect(s.observerLabel, 'Observer that heard it');
    expect(s.observerSymbol, 'observer');
    expect(s.unplacedNote, startsWith('Hops with no known position are listed, never drawn'));
  });

  test('certain is solid and likely is dashed', () {
    final s = MapPathStyle.of(_minor7())!;
    expect(s.isDashed(PathCertainty.certain), isFalse);
    expect(s.isDashed(PathCertainty.likely), isTrue);
    expect(s.certaintyLabel[PathCertainty.certain], 'Certain hop: its position is known');
    expect(s.certaintyLabel[PathCertainty.likely], 'Likely hop: the best match, not proven');
  });

  test('colours per theme', () {
    final s = MapPathStyle.of(_minor7())!;
    expect(s.colours(dark: false).line, 0xFF1D4ED8);
    expect(s.colours(dark: false).number, 0xFFFFFFFF);
    expect(s.colours(dark: true).line, 0xFF7FB0FF);
    expect(s.colours(dark: true).halo, 0xFF0D1117);
  });

  test('the label template turns into "N · Name"', () {
    final s = MapPathStyle.of(_minor7())!;
    expect(s.labelFor(2, 'Hilltop'), '2 · Hilltop');
  });

  test('a definition without symbols.path answers null (bundled copy, version 1 answer)', () {
    expect(MapPathStyle.of(MapDefinition.bundled), isNull);
    final json = File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync();
    expect(MapPathStyle.of(MapDefinition.parse(json)), isNull);
  });
}
