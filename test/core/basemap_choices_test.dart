// Build 77 (redesign Round 1 N3 / F2): the base map choices of the picker (Road, Light, Dark, Topo, Satellite), their real
// thumbnails, what each choice draws with coverage off and on (BaseMapStyle.resolve), and how every saved setting of an older
// build maps onto them. core/map_styles.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_pages.dart';
import 'package:meshsonar/core/map_styles.dart';

void main() {
  final def = MapDefinition.bundled;

  group('the choices', () {
    test('Road (auto), Light, Dark, Topo, Satellite, in that order, in plain words', () {
      final offered = BaseMapStyle.availableFor(def);
      expect(offered, [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark, BaseMapStyle.topo, BaseMapStyle.satellite]);
      expect([for (final s in offered) s.label], ['Road', 'Light', 'Dark', 'Topo', 'Satellite']);
      expect([for (final s in offered) s.labelIn(def)], ['Road', 'Light', 'Dark', 'Topo', 'Satellite']);
      expect([for (final s in offered) s.id], ['chart', 'street', 'dark', 'topo', 'satellite'], reason: 'the saved ids never change');
      for (final s in offered) {
        expect(s.blurb, isNotEmpty);
        expect(s.blurb.length, lessThan(45), reason: s.id);
      }
      expect(BaseMapStyle.chart.blurb, contains('theme'), reason: 'Road says it follows the theme');
    });

    test('a dark-theme user has a light road map: Light is always offered and always light; Dark always dark; Road follows', () {
      expect(BaseMapStyle.street.isDark(appDark: true), isFalse);
      expect(BaseMapStyle.street.isDark(appDark: false), isFalse);
      expect(BaseMapStyle.dark.isDark(appDark: false), isTrue);
      expect(BaseMapStyle.chart.isDark(appDark: true), isTrue);
      expect(BaseMapStyle.chart.isDark(appDark: false), isFalse);
      expect(BaseMapStyle.topo.isDark(appDark: true), isTrue);
      expect(BaseMapStyle.topo.isDark(appDark: false), isFalse);
      expect(BaseMapStyle.satellite.isDark(appDark: false), isTrue, reason: 'imagery is a dark picture: light names');
    });

    test('an older definition (no Topo / Satellite capability) still offers Road, Light and Dark', () {
      final j = jsonDecode(File('assets/map/map-definition.json').readAsStringSync()) as Map<String, dynamic>
        ..remove('schemaMinor')
        ..remove('capabilities');
      final old = MapDefinition.parse(jsonEncode(j));
      expect(BaseMapStyle.availableFor(old), [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]);
      expect(BaseMapStyle.effective(BaseMapStyle.satellite, old), BaseMapStyle.chart);
      expect(BaseMapStyle.effective(BaseMapStyle.street, old), BaseMapStyle.street);
    });
  });

  group('saved settings of older builds', () {
    test('every id a build has saved maps onto a choice; the definition\'s names are read; unknown is Road', () {
      expect(BaseMapStyle.parse('chart'), BaseMapStyle.chart, reason: 'Chart (builds up to 76) is Road');
      expect(BaseMapStyle.parse('street'), BaseMapStyle.street, reason: 'Light');
      expect(BaseMapStyle.parse('dark'), BaseMapStyle.dark);
      expect(BaseMapStyle.parse('topo'), BaseMapStyle.topo);
      expect(BaseMapStyle.parse('satellite'), BaseMapStyle.satellite);
      expect(BaseMapStyle.parse('road'), BaseMapStyle.chart);
      expect(BaseMapStyle.parse('light'), BaseMapStyle.street);
      expect(BaseMapStyle.parse('relief'), BaseMapStyle.chart);
      expect(BaseMapStyle.parse('hybrid'), BaseMapStyle.chart);
      expect(BaseMapStyle.parse(null), BaseMapStyle.chart);
      expect(BaseMapStyle.parse(''), BaseMapStyle.chart);
    });

    test('a saved Light is drawn as Light again (builds 74 to 76 drew it as Road under a merged definition)', () {
      final merged = MapDefinition.parse(File('test/fixtures/map_v2/definition-v2-minor7-cmh.json').readAsStringSync());
      expect(merged.basemapVariableIds, isNotNull);
      expect(BaseMapStyle.availableFor(merged), contains(BaseMapStyle.street));
      expect(BaseMapStyle.effective(BaseMapStyle.parse('street'), merged), BaseMapStyle.street);
    });
  });

  group('thumbnails', () {
    test('each choice has a real picture of its own: 360 x 168 PNG, not a flat colour', () {
      final seen = <String>{};
      for (final s in BaseMapStyle.values) {
        for (final appDark in [false, true]) {
          final path = s.thumbnailAsset(appDark: appDark);
          expect(path, startsWith('${BaseMapStyle.thumbnailFolder}/'));
          seen.add(path);
          final f = File(path);
          expect(f.existsSync(), isTrue, reason: path);
          final b = f.readAsBytesSync();
          expect(b.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: '$path is a PNG');
          final d = ByteData.sublistView(b);
          expect((d.getUint32(16), d.getUint32(20)), (360, 168), reason: path);
          expect(b.length, greaterThan(4000), reason: '$path: a flat colour block would be a few hundred bytes');
          expect(b.length, lessThan(60000), reason: '$path: keep the app small');
        }
      }
      expect(seen, BaseMapStyle.thumbnailAssets.toSet());
      expect(seen, hasLength(6), reason: 'road, light, dark, topo-light, topo-dark, satellite');
      // Every file in the folder is used, and the folder holds nothing else.
      expect(Directory(BaseMapStyle.thumbnailFolder).listSync().map((e) => e.path).toSet(), seen);
    });

    test('Road, Light and Dark are three different pictures in either theme; Topo follows the theme', () {
      for (final appDark in [false, true]) {
        final three = {for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]) s.thumbnailAsset(appDark: appDark)};
        expect(three, hasLength(3));
        final bytes = {for (final p in three) File(p).readAsBytesSync().length};
        expect(bytes, hasLength(3), reason: 'not three copies of one file');
      }
      expect(BaseMapStyle.topo.thumbnailAsset(appDark: true), isNot(BaseMapStyle.topo.thumbnailAsset(appDark: false)));
      expect(BaseMapStyle.chart.thumbnailAsset(appDark: true), BaseMapStyle.chart.thumbnailAsset(appDark: false), reason: 'Road is the light / dark split');
    });
  });

  group('resolve: what a choice draws', () {
    ResolvedBasemap r(BaseMapStyle s, {required bool appDark, required bool coverageOn, bool labelsAbove = true}) =>
        BaseMapStyle.resolve(s, appDark: appDark, coverageOn: coverageOn, labelsAbove: labelsAbove);

    test('coverage off: one layer, names inside it (as build 76)', () {
      for (final appDark in [false, true]) {
        for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]) {
          final got = r(s, appDark: appDark, coverageOn: false);
          expect((got.base, got.labels), (BasemapLook.road, null), reason: s.id);
          expect(got.dark, s.darkLook ?? appDark, reason: s.id);
        }
        expect(r(BaseMapStyle.topo, appDark: appDark, coverageOn: false), ResolvedBasemap(BaseMapStyle.topo, dark: appDark, base: BasemapLook.topo, labels: null));
        final sat = r(BaseMapStyle.satellite, appDark: appDark, coverageOn: false);
        expect((sat.isSatellite, sat.base, sat.labels, sat.dark), (true, null, null, true), reason: 'imagery with its names straight over it');
      }
    });

    test('coverage on: Road / Light / Dark draw the data-first map without names, and the names as a pass above', () {
      for (final appDark in [false, true]) {
        for (final s in [BaseMapStyle.chart, BaseMapStyle.street, BaseMapStyle.dark]) {
          final got = r(s, appDark: appDark, coverageOn: true);
          expect((got.base, got.labels), (BasemapLook.dataBase, BasemapLook.dataLabels), reason: s.id);
          expect(got.dark, s.darkLook ?? appDark, reason: s.id);
          expect(got.base!.labelsPass, got.labels);
        }
      }
      // The light data-first map for a dark-theme user who picked Light (F14), the dark one for a light-theme user on Dark.
      expect(r(BaseMapStyle.street, appDark: true, coverageOn: true).dark, isFalse);
      expect(r(BaseMapStyle.dark, appDark: false, coverageOn: true).dark, isTrue);
    });

    test('coverage on: Topo keeps its palette and Satellite its imagery; both get the names pass above', () {
      expect(r(BaseMapStyle.topo, appDark: false, coverageOn: true), const ResolvedBasemap(BaseMapStyle.topo, dark: false, base: BasemapLook.topoBase, labels: BasemapLook.topoLabels));
      expect(r(BaseMapStyle.satellite, appDark: false, coverageOn: true), const ResolvedBasemap(BaseMapStyle.satellite, dark: true, base: null, labels: BasemapLook.labels));
    });

    test('labelsAbove false (one layer): the data-first map with its names inside; Topo and Satellite as with coverage off', () {
      final road = r(BaseMapStyle.chart, appDark: true, coverageOn: true, labelsAbove: false);
      expect((road.base, road.labels), (BasemapLook.data, null));
      expect(r(BaseMapStyle.topo, appDark: true, coverageOn: true, labelsAbove: false), r(BaseMapStyle.topo, appDark: true, coverageOn: false));
      expect(r(BaseMapStyle.satellite, appDark: true, coverageOn: true, labelsAbove: false).labels, isNull);
    });

    test('every resolved look has a style on our tiles, and the names pass is names only', () {
      for (final s in BaseMapStyle.values) {
        for (final appDark in [false, true]) {
          for (final coverageOn in [false, true]) {
            final got = r(s, appDark: appDark, coverageOn: coverageOn);
            if (got.base != null) {
              final layers = basemapStyle(BasemapSource.ours, dark: got.dark, look: got.base!)['layers'] as List;
              expect(layers.any((l) => l['type'] == 'background'), isTrue, reason: '$got');
              expect(layers.any((l) => l['type'] == 'symbol'), got.labels == null, reason: '$got: names are in exactly one of the two passes');
            }
            if (got.labels != null) {
              final layers = basemapStyle(BasemapSource.ours, dark: got.dark, look: got.labels!)['layers'] as List;
              expect(layers.every((l) => l['type'] == 'symbol'), isTrue, reason: '$got');
            }
          }
        }
      }
    });
  });
}
