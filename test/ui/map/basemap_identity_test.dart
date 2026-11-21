// Build 72 (iPad report: tiles of two basemap styles on screen at once, styles not changing, mostly blank maps).
// 1. Every basemap style has its OWN renderer identity (id + version): vector_map_tiles keys its rendered-tile caches, in
//    memory and on disk, and its isolate registries on it. Builds 57 to 71 had none, so all seven were "default / none".
// 2. The renders those builds left on disk are deleted once, and only those.
// 3. Network tiles inside an offline pack's area are skipped only under a style that draws the pack.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/basemap.dart';
import 'package:meshsonar/core/basemap_styles.g.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_styles.dart';
import 'package:meshsonar/ui/map/basemap_cache.dart';
import 'dart:ui' show Size;

import 'package:meshsonar/ui/map/basemap_layer.dart' show BasemapTuning, basemapTheme;
import 'package:meshsonar/ui/map/coverage_map.dart' show skipsNetworkTile, styleDrawsOfflinePack;
import 'package:meshsonar/ui/map/offline_basemap.dart' show offlineMapStyle;
import 'package:meshsonar/ui/map/tile_source.dart' show TileFetchGate;
import 'package:vector_tile_renderer/vector_tile_renderer.dart' as vtr;

/// What vector_map_tiles caches a theme's tiles under (raster/tile_loader.dart `themeIdentity`, storage_image_cache `themeKey`).
String rendererIdentity(vtr.Theme t) => '${t.id}/v${t.version}/${(t.tileSources.toList()..sort()).join(',')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('style identity', () {
    test('every generated style carries an id of its own and the render version', () {
      expect(basemapStyleJsonByName, hasLength(7));
      final ids = <String>{};
      for (final e in basemapStyleJsonByName.entries) {
        final j = jsonDecode(e.value) as Map<String, dynamic>;
        expect(j['id'], isA<String>(), reason: '${e.key} has no id');
        expect(j['id'], 'meshsonar-${e.key}');
        expect(j['id'], isNot('default'));
        expect((j['metadata'] as Map)['version'], '$basemapStylesRenderVersion', reason: e.key);
        expect(ids.add(j['id'] as String), isTrue, reason: '${e.key}: id ${j['id']} is used twice');
      }
      expect(basemapStylesRenderVersion, basemapRenderVersion, reason: 'bumped basemapRenderVersion: re-run tool/basemap/make_basemap_styles.mjs');
    });

    test('a style added to the generated file without an id (or left out of the list) fails here', () {
      final src = File('lib/core/basemap_styles.g.dart').readAsStringSync();
      final consts = RegExp(r'const (\w+StyleJson) = ').allMatches(src).map((m) => m.group(1)!).toSet();
      final listed = RegExp(r"'[\w-]+': (\w+StyleJson),").allMatches(src).map((m) => m.group(1)!).toSet();
      expect(consts, isNotEmpty);
      expect(listed, consts, reason: 'every *StyleJson constant is in basemapStyleJsonByName (so the id test above sees it)');
      final gen = File('tool/basemap/make_basemap_styles.mjs').readAsStringSync();
      final returned = RegExp(r'return \{ version: 8, name: ').allMatches(gen).length;
      final withId = RegExp(r'return \{ version: 8, name: [^,]+, \.\.\.identity\(').allMatches(gen).length;
      expect(returned, greaterThanOrEqualTo(4));
      expect(withId, returned, reason: 'every style the generator returns goes through identity()');
    });

    test('a style with no id and no name is refused; the name stands in for a missing id', () {
      expect(() => withBasemapIdentity({'version': 8, 'layers': const []}), throwsStateError);
      expect(() => withBasemapIdentity({'id': 'default', 'layers': const []}), throwsStateError);
      final s = withBasemapIdentity({'name': 'meshsonar-x', 'layers': const []});
      expect(s['id'], 'meshsonar-x');
      expect((s['metadata'] as Map)['version'], '$basemapRenderVersion');
    });

    test('the nine themes the app can draw have nine distinct renderer identities, none of them the old shared one', () {
      final themes = <String, vtr.Theme>{
        for (final dark in [false, true])
          for (final look in BasemapLook.values)
            if (look != BasemapLook.labels) 'ours-$dark-${look.name}': basemapTheme(BasemapSource.ours, dark: dark, look: look),
        'ours-labels': basemapTheme(BasemapSource.ours, dark: true, look: BasemapLook.labels),
        for (final dark in [false, true]) 'ofm-$dark': basemapTheme(BasemapSource.openFreeMap, dark: dark),
        for (final dark in [false, true]) 'pack-legacy-$dark': vtr.ThemeReader().read(offlineMapStyle(dark: dark)),
      };
      expect(themes, hasLength(9));
      final seen = <String, String>{};
      for (final e in themes.entries) {
        final id = rendererIdentity(e.value);
        expect(e.value.id, isNot('default'), reason: e.key);
        expect(e.value.id, startsWith(BasemapRenderCache.ownPrefix), reason: e.key);
        expect(e.value.version, '$basemapRenderVersion', reason: e.key);
        expect(seen.containsKey(id), isFalse, reason: '${e.key} shares the identity $id with ${seen[id]}');
        seen[id] = e.key;
        // The disk name of one of its renders is not a stale one.
        final key = '${e.value.id}-v${e.value.version}'.replaceAll(RegExp(r'[^a-zA-Z0-9.-]'), '-');
        expect(BasemapRenderCache.isStaleRender('$key-13-2207-3102.png'), isFalse, reason: e.key);
      }
      // The labels look and the OpenFreeMap fallback for a look it does not have are deliberate aliases, nothing else is.
      expect(identical(basemapTheme(BasemapSource.ours, dark: false, look: BasemapLook.labels), basemapTheme(BasemapSource.ours, dark: true, look: BasemapLook.labels)), isFalse);
      expect(rendererIdentity(basemapTheme(BasemapSource.ours, dark: false, look: BasemapLook.labels)), rendererIdentity(basemapTheme(BasemapSource.ours, dark: true, look: BasemapLook.labels)),
          reason: 'one labels style for both themes: the same tiles are correct for both');
      expect(basemapStyleIdentity(basemapStyle(BasemapSource.ours, dark: true)), 'meshsonar-protomaps-dark/v$basemapRenderVersion');
    });
  });

  group('old renders are deleted once', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('b72-basemap-cache');
      BasemapRenderCache.tempDirectory = () async => tmp;
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('which files are stale', () {
      expect(BasemapRenderCache.isStaleRender('default-vnone-13-2207-3102.png'), isTrue);
      expect(BasemapRenderCache.isStaleRender('meshsonar-protomaps-dark-v1-13-2207-3102.png'), isTrue, reason: 'an earlier render version of ours');
      expect(BasemapRenderCache.isStaleRender('meshsonar-protomaps-dark-v$basemapRenderVersion-13-2207-3102.png'), isFalse);
      expect(BasemapRenderCache.isStaleRender('meshsonar-protomaps-topo-light-v$basemapRenderVersion-9-137-193.png'), isFalse);
      expect(BasemapRenderCache.isStaleRender('13_2207_3102_protomaps.pbf'), isFalse, reason: 'downloaded tiles are style-free: kept');
    });

    test('the purge removes the old shared renders, keeps the rest, runs once, and is retried after a failure', () async {
      final dir = Directory('${tmp.path}/${BasemapRenderCache.folderName}')..createSync();
      File f(String n) => File('${dir.path}/$n');
      for (var i = 0; i < 40; i++) {
        f('default-vnone-13-${2200 + i}-3102.png').writeAsBytesSync(List.filled(64, i));
      }
      f('meshsonar-protomaps-light-v1-12-1103-1551.png').writeAsBytesSync([1]);
      f('meshsonar-protomaps-light-v$basemapRenderVersion-12-1103-1551.png').writeAsBytesSync([2]);
      f('12_1103_1551_protomaps.pbf').writeAsBytesSync([3]);

      // A prefs file that cannot be written: the flag does not stick, so the next launch tries again.
      String? saved;
      final prefs = MapPrefs(read: () async => saved, write: (s) async => saved = s);
      expect(prefs.basemapCachePurged, 0);
      expect(await BasemapRenderCache.purgeOld(prefs), 41);
      expect(dir.listSync().map((e) => e.uri.pathSegments.last).toSet(), {'meshsonar-protomaps-light-v$basemapRenderVersion-12-1103-1551.png', '12_1103_1551_protomaps.pbf'});
      expect(prefs.basemapCachePurged, basemapRenderVersion);
      await Future<void>.delayed(Duration.zero);
      expect(jsonDecode(saved!)['basemap_cache_purged'], basemapRenderVersion, reason: 'remembered on disk');

      // Second launch: nothing to do, nothing listed.
      f('default-vnone-1-0-0.png').writeAsBytesSync([9]);
      final again = MapPrefs(read: () async => saved, write: (s) async => saved = s);
      expect(await BasemapRenderCache.purgeOld(again), isNull, reason: 'once per render version');
      expect(f('default-vnone-1-0-0.png').existsSync(), isTrue);

      // A launch whose delete fails (the folder is unreadable) leaves the flag unset and does not throw.
      BasemapRenderCache.tempDirectory = () async => throw const FileSystemException('no temp dir');
      final fresh = MapPrefs();
      expect(await BasemapRenderCache.purgeOld(fresh), isNull);
      expect(fresh.basemapCachePurged, 0, reason: 'retried next launch');
      BasemapRenderCache.tempDirectory = () async => tmp;
      expect(await BasemapRenderCache.purgeOld(fresh), 1);
      expect(fresh.basemapCachePurged, basemapRenderVersion);
    });

    test('no cache folder yet (fresh install): done, flag set', () async {
      final prefs = MapPrefs();
      expect(await BasemapRenderCache.purgeOld(prefs), 0);
      expect(prefs.basemapCachePurged, basemapRenderVersion);
    });
  });

  group('offline pack and network tiles', () {
    test('only Chart, Light and Dark draw a pack', () {
      expect({for (final s in BaseMapStyle.values) s.id: styleDrawsOfflinePack(s)}, {'chart': true, 'street': true, 'dark': true, 'topo': false, 'satellite': false});
    });

    test('a network tile is skipped only where a pack covers it AND the style draws the pack', () {
      for (final s in BaseMapStyle.values) {
        expect(skipsNetworkTile(style: s, packCovers: false), isFalse, reason: '${s.id}: no pack there, always fetched');
        expect(skipsNetworkTile(style: s, packCovers: true), s == BaseMapStyle.topo || s == BaseMapStyle.satellite ? isFalse : isTrue,
            reason: '${s.id} inside a pack area');
      }
    });
  });

  group('tile request queue sized for the screen', () {
    test('one iPad screen of one layer is more than the phone queue holds: requests were dropped, tiles stayed blank', () async {
      const pad = Size(834, 1194);
      final oneLayer = ((pad.width / 256).ceil() + 3) * ((pad.height / 256).ceil() + 3); // tiles in view plus the pan buffer
      expect(oneLayer, 56);
      final never = Completer<void>().future;
      // The phone default: 6 running + 48 waiting.
      final phone = TileFetchGate();
      final asked = [for (var i = 0; i < oneLayer * 3; i++) phone.acquire(never)]; // Satellite: two imagery layers and the names
      expect(phone.dropped, oneLayer * 3 - 6 - 48, reason: '114 of 168 requests dropped');
      expect(await asked[6], isNull, reason: 'a dropped request gets no permit: its tile is never fetched');

      // Sized for the screen: nothing is dropped.
      final gate = TileFetchGate()..ensureRoom(waiting: BasemapTuning.requestsFor(pad), concurrent: BasemapTuning.requestConcurrencyFor(pad));
      expect((gate.maxWaiting, gate.maxConcurrent), (336, 10));
      for (var i = 0; i < oneLayer * 3; i++) {
        gate.acquire(never);
      }
      expect(gate.dropped, 0);
      expect(gate.running, 10);
      expect(gate.waiting, oneLayer * 3 - 10);
      // A phone opened afterwards never shrinks it; a phone's own numbers stay the defaults or more.
      gate.ensureRoom(waiting: BasemapTuning.requestsFor(const Size(402, 874)), concurrent: BasemapTuning.requestConcurrencyFor(const Size(402, 874)));
      expect((gate.maxWaiting, gate.maxConcurrent), (336, 10));
      expect(BasemapTuning.requestsFor(const Size(402, 874)), greaterThanOrEqualTo(48));
      expect(BasemapTuning.requestConcurrencyFor(const Size(402, 874)), 6);
    });
  });
}
