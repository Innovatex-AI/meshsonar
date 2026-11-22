// MAP slices 4 to 6 (app half, build 74): the page presets and variables the app reads from Map Definition `?v=2` at
// schemaMinor 7 (the live answer of Nov 22 2026, saved in test/fixtures/map_v2/definition-v2-minor7-cmh.json), and that a
// definition without them (the bundled copy, the minor 6 answer) answers null everywhere.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_pages.dart';

MapDefinition _minor7() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
MapDefinition _minor6() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync());

void main() {
  test('the live definition presets 16 pages and has no drive or plan page', () {
    final d = _minor7();
    expect(d.hasPages, isTrue);
    expect(d.pageIds, containsAll(['map', 'live', 'drive-detail', 'path', 'node', 'observer', 'zones']));
    expect(d.pageIds, hasLength(16));
    expect(d.pagePreset('drive'), isNull);
    expect(d.pagePreset('plan'), isNull);
  });

  test('the map preset: full mode, road, names on, colour by status, its layers', () {
    final p = _minor7().pagePreset('map')!;
    expect(p.mode, 'full');
    expect(p.isStill, isFalse);
    expect(p.basemap, 'road');
    expect(p.names, isTrue);
    expect(p.colourBy, 'status');
    expect(p.panels, ['layers']);
    expect(p.layers, ['borders', 'measured', 'predicted', 'heard', 'repeaters', 'estimated', 'observers', 'phones', 'links']);
    expect(p.has('measured'), isTrue);
    expect(p.has('track'), isFalse);
  });

  test('aliases turn the old layer words into layer ids', () {
    final d = _minor7();
    expect(d.layerAliases, {'nodes': 'repeaters', 'heardcells': 'heard'});
    expect(d.layerIdOf('nodes'), 'repeaters');
    expect(d.layerIdOf('measured'), 'measured');
  });

  test('breakpoints, map heights and variables', () {
    final d = _minor7();
    expect(d.tabletBreakpoint, 768);
    expect(d.desktopBreakpoint, 1100);
    expect(d.stillMapHeight('short'), 200);
    expect(d.stillMapHeight('standard'), 280);
    expect(d.stillMapHeight('tall'), isNull);
    expect(d.tallMapHeight, (share: 0.5, minPx: 320.0, maxPx: 560.0));
    expect(d.basemapVariableIds, ['road', 'relief', 'plain', 'topo', 'satellite']);
    expect(d.basemapVariableDefault, 'road');
    expect(d.paletteVariableIds, isNotEmpty);
  });

  test('a definition without the blocks answers null or empty everywhere (build 73 behaviour stays)', () {
    for (final d in [MapDefinition.bundled, _minor6()]) {
      expect(d.hasPages, isFalse);
      expect(d.pageIds, isEmpty);
      expect(d.pagePreset('map'), isNull);
      expect(d.layerAliases, isEmpty);
      expect(d.layerIdOf('nodes'), 'nodes');
      expect(d.tabletBreakpoint, isNull);
      expect(d.stillMapHeight('short'), isNull);
      expect(d.tallMapHeight, isNull);
    }
    expect(MapDefinition.bundled.basemapVariableIds, isNull);
    expect(MapDefinition.bundled.nodeFilters, isEmpty);
  });
}
