// MAP slices 2 and 3 (app half): what the app reads from Map Definition `?v=2` (the live answer of Nov 22 2026, saved in
// test/fixtures/map_v2/definition-v2-cmh.json): the label spec, the one symbol set, colour-by, the packet-type colours; and that a
// definition without them (the bundled copy, a version 1 answer) gives exactly what build 72 drew.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_v2.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/map/active_map_definition.dart';
import 'package:meshsonar/ui/map/layers/repeater_name_labels.dart';
import 'package:meshsonar/ui/map/node_symbol.dart';
import 'package:meshsonar/ui/network/live/packet_type_colors.dart';

MapDefinition _v2() => MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-cmh.json').readAsStringSync());

void main() {
  tearDown(() => ActiveMapDefinition.debugSet());

  group('labels.spec', () {
    test('the live spec: 12 / 13 / 14 by zoom, budget 12 / 24 / 40 / 56 / 80, halo 3, stale 70%, pill on Topo and Satellite', () {
      final s = _v2().labelSpec;
      expect(_v2().hasLabelSpec, isTrue);
      expect([for (final z in [3.0, 11.9, 12.0, 13.9, 14.0, 18.0]) s.sizeAt(z)], [12, 12, 13, 13, 14, 14]);
      expect([for (final z in [8.9, 9.0, 10.9, 11.0, 12.0, 13.0, 14.0, 17.0]) s.budgetAt(z)], [0, 12, 12, 24, 40, 56, 80, 80]);
      expect(s.minZoom, 9);
      expect(s.maxWidthPx, 150);
      expect(s.haloPx, 3);
      expect(s.staleOpacity, 0.7);
      expect(s.pillOn, {'topo', 'satellite'});
      expect(s.pillRadius, 8);
      expect(s.holdMs, 300);
      expect(s.fadeMs, 120);
      expect(s.inkFor(false), 0xFF1B1F24);
      expect(s.inkFor(true), 0xFFF4F6F8);
      expect(s.haloFor(false), 0xFFFFFFFF);
    });

    test('what gets a name, from which zoom: a repeater that matters from 9, the rest from 11; observers 12; companions 13', () {
      final s = _v2().labelSpec;
      expect(s.names('repeater', 9, important: true), isTrue);
      expect(s.names('repeater', 9), isFalse);
      expect(s.names('repeater', 11), isTrue);
      expect(s.names('observer', 11.9), isFalse);
      expect(s.names('observer', 12), isTrue);
      expect(s.names('companion', 12.9), isFalse);
      expect(s.names('companion', 13), isTrue);
      expect(s.names('plan', 9), isTrue);
      expect(s.names('selected', 0), isTrue);
      expect(s.thing('estimated').italic, isTrue);
      expect(s.thing('estimated').opacity, 0.7);
    });

    test('without the block (bundled copy, version 1): the Drive numbers build 72 used', () {
      final s = MapDefinition.bundled.labelSpec;
      expect(MapDefinition.bundled.hasLabelSpec, isFalse);
      expect(identical(s, MapLabelSpec.drive), isTrue);
      expect([for (final z in [8.9, 9.0, 11.0, 12.0, 13.0, 14.0]) s.budgetAt(z)], [0, 12, 24, 40, 56, 80]);
      expect([for (final z in [9.0, 11.9, 12.0, 13.9, 14.0]) s.sizeAt(z)], [12, 12, 13, 13, 14]);
      // and the live spec says the very same numbers (the app's Drive map does not change)
      final live = _v2().labelSpec;
      for (var z = 0.0; z < 20; z += 0.5) {
        expect(live.budgetAt(z), s.budgetAt(z), reason: 'zoom $z');
        expect(live.sizeAt(z), s.sizeAt(z), reason: 'zoom $z');
      }
    });

    test('the engine reads the active definition: labelBudgetForZoom / labelFontSizeForZoom follow it', () {
      ActiveMapDefinition.debugSet(_v2());
      expect(labelBudgetForZoom(12), 40);
      expect(labelFontSizeForZoom(14), 14);
      ActiveMapDefinition.debugSet();
      expect(labelBudgetForZoom(8.9), 0);
    });

    test('names follow the basemap that is showing: Light is always the light map, Dark the dark map, Chart the theme, Satellite dark; only Topo and Satellite use a pill', () {
      ActiveMapDefinition.debugSet(_v2());
      LabelTone t(BaseMapStyle s, Brightness b) => labelToneFor(s, b);
      expect(t(BaseMapStyle.street, Brightness.dark), const LabelTone(false, false), reason: 'Light basemap under a dark app: dark ink, a halo, no pill');
      expect(t(BaseMapStyle.dark, Brightness.light), const LabelTone(true, false));
      expect(t(BaseMapStyle.chart, Brightness.dark), const LabelTone(true, false));
      expect(t(BaseMapStyle.chart, Brightness.light), const LabelTone(false, false));
      expect(t(BaseMapStyle.topo, Brightness.light), const LabelTone(false, true));
      expect(t(BaseMapStyle.topo, Brightness.dark), const LabelTone(true, true));
      expect(t(BaseMapStyle.satellite, Brightness.light), const LabelTone(true, true));
    });
  });

  group('symbols.set', () {
    test('seven roles, three freshness rows, tints for status, hash and role', () {
      final s = _v2().symbolSet!;
      expect([for (final r in s.roles) r.id], ['repeater', 'room', 'companion', 'sensor', 'unknown', 'observer', 'phone']);
      expect([for (final f in s.freshness) '${f.id}:${f.ring}:${f.opacity}'], ['fresh:solid:1.0', 'recent:dashed:1.0', 'stale:none:0.45']);
      expect(s.tints.keys, containsAll(['status', 'hash', 'role']));
      expect([for (final t in s.tints['status']!) t.id], ['active', 'degraded', 'silent', 'unknown']);
      expect(s.sizePx, 24);
      expect(s.role('observer')!.label, contains('eye on a mast'));
      expect(s.neutral(true).fill, 0xFF12161B);
    });

    test('a definition without it still has the set (the one the app carries equals the live one)', () {
      expect(MapDefinition.bundled.symbolSet, isNull);
      final carried = MapDefinition.bundled.nodeSymbols;
      final live = _v2().symbolSet!;
      expect([for (final r in carried.roles) r.badge], [for (final r in live.roles) r.badge]);
      expect([for (final r in carried.roles) r.glyph.map((g) => g.d).join('|')], [for (final r in live.roles) r.glyph.map((g) => g.d).join('|')]);
    });

    test('every badge and glyph parses into a path inside the 24 x 24 box', () {
      for (final r in _v2().symbolSet!.roles) {
        final b = SvgPath.parse(r.badge).getBounds();
        expect(b.width, greaterThan(4), reason: r.id);
        expect(b.left, greaterThanOrEqualTo(0));
        expect(b.right, lessThanOrEqualTo(24.01));
        expect(b.top, greaterThanOrEqualTo(0));
        expect(b.bottom, lessThanOrEqualTo(24.01));
        for (final g in r.glyph) {
          final gb = SvgPath.parse(g.d).getBounds();
          expect(gb.isEmpty && gb.width + gb.height == 0, isFalse, reason: '${r.id} glyph ${g.d}');
          expect(gb.right, lessThanOrEqualTo(24.01));
        }
      }
    });

    test('the path reader: relative and absolute commands, arcs, implicit repeats, junk is survivable', () {
      expect(SvgPath.parse('M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0Z').getBounds().width, closeTo(18, 0.01));
      expect(SvgPath.parse('M2 2h4v4h-4Z').getBounds(), const Rect.fromLTRB(2, 2, 6, 6));
      expect(SvgPath.parse('M0 0 L10 0 10 10').getBounds(), const Rect.fromLTRB(0, 0, 10, 10));
      expect(SvgPath.parse('M1 1Q5 5 9 1').getBounds().right, 9);
      expect(SvgPath.parse('M1 1 Z nonsense 12').getBounds().isEmpty || true, isTrue);
      expect(SvgPath.parse('').getBounds(), Rect.zero);
    });
  });

  group('variables.colourBy and packetTypes', () {
    test('colour by: none by default, Status / Hash / Role pickable, Scope listed but unavailable; the Network Map page starts with Status', () {
      final c = _v2().colourBy!;
      expect(c.urlKey, 'cb');
      expect(c.defaultId, 'none');
      expect(c.pickable, ['none', 'status', 'hash', 'role']);
      expect(c.options.last.id, 'scope');
      expect(c.options.last.available, isFalse);
      expect(c.pageDefaults['map'], 'status');
      expect(MapDefinition.bundled.colourBy, isNull);
    });

    test('packet types: the definition list equals the colours Live, the feed and the table always used, light and dark', () {
      final def = _v2().packetTypes!;
      expect(def.byType.keys.toSet(), {0, 1, 2, 3, 4, 5, 8, 9});
      for (final type in [0, 1, 2, 3, 4, 5, 8, 9, 6, 7, 10, 99]) {
        for (final b in [Brightness.light, Brightness.dark]) {
          ActiveMapDefinition.debugSet(); // the built-in list
          final builtin = packetTypeColorFor(type, b);
          ActiveMapDefinition.debugSet(_v2()); // the definition's list
          expect(packetTypeColorFor(type, b), builtin, reason: 'type $type $b');
        }
      }
    });
  });

  group('size choices (app-next-pass item 7)', () {
    test('Small 0.85, Normal 1.0, Large 1.25; default Normal; unknown words read as Normal', () {
      expect([for (final c in MapSizeChoice.values) c.scale], [0.85, 1.0, 1.25]);
      final p = MapPrefs();
      expect(p.labelSize, MapSizeChoice.normal);
      expect(p.iconSize, MapSizeChoice.normal);
      expect(p.labelScale, 1.0);
      expect(MapSizeChoice.parse('huge'), MapSizeChoice.normal);
      expect(MapSizeChoice.parse(null), MapSizeChoice.normal);
    });

    test('saved on the device: written only when changed, read back, and each map listens', () async {
      String? saved;
      final p = MapPrefs(read: () async => saved, write: (j) async => saved = j);
      var notes = 0;
      p.addListener(() => notes++);
      expect(p.toJson().containsKey('label_size'), isFalse, reason: 'Normal is not written');
      p.labelSize = MapSizeChoice.large;
      p.iconSize = MapSizeChoice.small;
      p.colourBy = 'status';
      await Future<void>.delayed(Duration.zero);
      expect(notes, 3);
      expect(saved, allOf(contains('"label_size":"large"'), contains('"icon_size":"small"'), contains('"colour_by":"status"')));
      final q = MapPrefs(read: () async => saved);
      await q.load();
      expect(q.labelScale, 1.25);
      expect(q.iconScale, 0.85);
      expect(q.colourBy, 'status');
      p.labelSize = MapSizeChoice.large; // no change: no notice
      expect(notes, 3);
    });
  });
}
