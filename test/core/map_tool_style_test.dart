// MAP slice 6 (app half): the reader of `symbols.tools` answers the live values, and null for a definition without it.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_tool_style.dart';

Map<String, dynamic> _fixture() => jsonDecode(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync()) as Map<String, dynamic>;
MapDefinition _def(Map<String, dynamic> j) => MapDefinition.parse(jsonEncode(j));

void main() {
  test('the live definition: zone, hidden track and handles', () {
    final t = MapToolStyle.of(_def(_fixture()))!;
    expect(t.zone.label, 'Privacy zone');
    expect(t.zone.fill.light, 0xFF64748B);
    expect(t.zone.fill.dark, 0xFF94A3B8);
    expect(t.zone.edge.of(dark: true), 0xFFE6EDF3);
    expect(t.zone.fillOpacity.of(active: false), 0.16);
    expect(t.zone.fillOpacity.of(active: true), 0.28);
    expect(t.zone.edgeWidthPx.normal, 1);
    expect(t.zone.edgeWidthPx.active, 2);
    expect(t.zone.dash, [2, 2]);
    expect(t.hiddenTrack.label, 'Hidden from the public: faded and dashed');
    expect(t.hiddenTrack.colour.of(dark: false), 0xFF64748B);
    expect(t.hiddenTrack.opacity, 0.6);
    expect(t.hiddenTrack.widthPx, 2);
    expect(t.hiddenTrack.dash, [1, 2]);
    expect(t.handle.fill.light, 0xFFFFFFFF);
    expect(t.handle.fill.dark, 0xFF12161B);
    expect(t.handle.moveFill.light, 0xFF1F2933);
  });

  test('the bundled definition and the minor 6 answer have no tool style: null', () {
    expect(MapToolStyle.of(MapDefinition.bundled), isNull);
    expect(MapToolStyle.of(_def(jsonDecode(File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync()) as Map<String, dynamic>)), isNull);
  });

  test('a damaged part makes the whole block null, never a half style', () {
    for (final part in ['zone', 'hiddenTrack', 'handle']) {
      final j = _fixture();
      ((j['symbols'] as Map)['tools'] as Map).remove(part);
      expect(MapToolStyle.of(_def(j)), isNull, reason: 'missing $part');
    }
    final j = _fixture();
    (((j['symbols'] as Map)['tools'] as Map)['zone'] as Map)['fill'] = {'light': 'nope', 'dark': '#000000'};
    expect(MapToolStyle.of(_def(j)), isNull);
  });

  test('a missing or bad dash means a solid line', () {
    final j = _fixture();
    (((j['symbols'] as Map)['tools'] as Map)['zone'] as Map)['dash'] = 'x';
    expect(MapToolStyle.of(_def(j))!.zone.dash, isNull);
  });
}
