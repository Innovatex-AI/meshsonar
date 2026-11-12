import 'dart:convert';

// The layer registry, MapLayerState <-> ?show=, and every layer's availability text.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_definition_bundled.g.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/map_view_state.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';

final now = DateTime.utc(2026, 10, 24, 12);
const cmh = RosterRegion(slug: 'cmh', name: 'CMH', baseUrl: 'https://cmh.meshsonar.com');
String k(String c) => c * 64;

void main() {
  group('registry', () {
    test('ids are unique and z strictly increases', () {
      expect(kMapLayerIds.length, kMapLayers.length);
      for (var i = 1; i < kMapLayers.length; i++) {
        expect(kMapLayers[i].z, greaterThan(kMapLayers[i - 1].z), reason: kMapLayers[i].id);
      }
    });

    test('website ids are the website\'s ?show= keys; app-only ids are the URL code\'s app keys', () {
      final web = {for (final l in kMapLayers) if (l.onWebsite) l.id};
      expect(web, kWebsiteKeysDrawn);
      expect(web.every(kWebsiteShowKeys.contains), isTrue);
      final app = {for (final l in kMapLayers) if (!l.onWebsite) l.id};
      expect(app, kAppOnlyShowKeys.toSet());
      expect(kWebsiteKeysNotDrawn, {'model', 'reach', 'regions'}, reason: 'the app dropped the neighbouring-regions pointers (0.26.1)');
    });

    test('coverage redesign layers (plan section 5): rings gone, predicted added, under measured', () {
      // Nov 9 2026: + 'heardcells', the Heard (no ping) layer (phone observer contract section 8.5), between predicted and measured.
      // Nov 12 2026 (M3-2): + 'redundancy', 'snrlinks' and 'estimated' (Map Definition capabilities layer.redundancy / layer.snrlinks / layer.estimated).
      expect(kMapLayers.map((l) => l.id).toSet(), {
        'borders', 'predicted', 'heardcells', 'measured', 'redundancy', 'hexes', 'pings', 'snrlinks', 'links', 'heard', 'repeaters', 'network', 'estimated', 'observers', 'phones', 'labels',
      });
      expect(kMapLayers, hasLength(16));
      expect(layerSpec('heardcells')!.z, greaterThan(layerSpec('predicted')!.z));
      expect(layerSpec('heardcells')!.z, lessThan(layerSpec('measured')!.z), reason: 'a pinged cell shows its Measured colour');
      expect(layerSpec('rings'), isNull);
      expect(layerSpec('neighbours'), isNull);
      expect(kAppOnlyShowKeys, isNot(contains('rings')));
      expect(layerSpec('predicted')!.z, lessThan(layerSpec('measured')!.z), reason: 'predicted is drawn UNDER measured (D8)');
    });

    test('defaults come from the Map Definition: every defaultOn layer, plus the drive extras; All MeshCore repeaters off', () {
      expect(kDefaultLayerState.on,
          {'borders', 'predicted', 'heardcells', 'measured', 'hexes', 'links', 'repeaters', 'estimated', 'observers', 'phones', 'heard', 'pings', 'labels'});
      expect(kDefaultLayerState.isOn('redundancy'), isFalse, reason: 'Redundancy is off by default (the definition)');
      expect(kDefaultLayerState.isOn('snrlinks'), isFalse, reason: 'Links by SNR is off by default (the definition)');
      expect(kDefaultLayerState.mode, {'pings': 'snr'}, reason: 'no colour-by mode any more (D9)');
      expect(layerLabel('network'), 'All MeshCore repeaters');
      expect(kDefaultLayerState.isOn('network'), isFalse);
      expect(layerSpec('nope'), isNull);
      expect(LayerGroup.values.map((g) => g.label), ['Coverage', 'Network', 'Context']);
    });

    test('the sheet is the website Layers panel: groups and rows from the definition, top of the map first', () {
      final rows = sheetRows(MapDefinition.bundled);
      expect([for (final (g, _) in rows) g.name], ['Coverage', 'Network', 'Context']);
      expect([for (final r in rows[0].$2) r.id], ['hexes', 'pings', 'redundancy', 'measured', 'heardcells', 'predicted'],
          reason: 'This drive (the panel-only drive layer, the app drive panel) then the website rows');
      expect([for (final r in rows[1].$2) r.id], ['phones', 'observers', 'estimated', 'repeaters', 'labels', 'network', 'links', 'snrlinks']);
      expect([for (final r in rows[2].$2) r.id], ['borders']);
      expect([for (final id in ['measured', 'heardcells', 'predicted', 'redundancy', 'snrlinks', 'estimated', 'phones', 'observers', 'repeaters', 'network', 'links', 'borders']) layerLabel(id, MapDefinition.bundled)], [
        'Measured coverage',
        'Heard by phones',
        'Predicted coverage',
        'Redundancy',
        'Links by SNR',
        'Estimated positions',
        'Moving phones',
        'Observers',
        'Repeaters',
        'All MeshCore repeaters',
        'Link lines',
        'Region borders',
      ]);
    });

    test('the hub definition: no observers, phones, links or network rows', () {
      final j = jsonDecode(kBundledMapDefinitionJson) as Map<String, dynamic>;
      j['layers'] = [for (final l in j['layers'] as List) if (const {'borders', 'predicted', 'heard', 'measured', 'drive', 'repeaters'}.contains((l as Map)['id'])) l];
      final hub = MapDefinition.parse(jsonEncode(j));
      final ids = [for (final (_, rs) in sheetRows(hub)) for (final r in rs) r.id];
      expect(ids, isNot(contains('observers')));
      expect(ids, isNot(contains('links')));
      expect(ids, containsAll(['repeaters', 'measured', 'borders']));
    });

    test('paint order follows the definition', () {
      expect(definitionLayerIds(MapDefinition.bundled),
          ['borders', 'predicted', 'heardcells', 'measured', 'redundancy', 'hexes', 'snrlinks', 'links', 'network', 'repeaters', 'estimated', 'observers', 'phones']);
    });

    test('one Repeaters switch with a scope: region by default, All MeshCore remembered while off', () {
      var s = kDefaultLayerState;
      expect(repeatersOn(s), isTrue);
      expect(repeatersAllScope(s), isFalse);
      s = withRepeaterScope(s, all: true);
      expect(s.isOn('network'), isTrue);
      expect(s.isOn('repeaters'), isFalse);
      s = withRepeaters(s, false);
      expect(repeatersOn(s), isFalse);
      expect(s.isOn('heard'), isFalse);
      expect(repeatersAllScope(s), isTrue, reason: 'the scope survives the switch being off');
      s = withRepeaters(s, true);
      expect(s.isOn('network'), isTrue);
      expect(s.isOn('heard'), isTrue);
      s = withRepeaterScope(s, all: false);
      expect(s.isOn('repeaters'), isTrue);
      expect(s.isOn('network'), isFalse);
      expect(layerStateFromPrefs(const LayerPrefs(modes: {'repeaters': 'all'})).modeOf('repeaters'), 'all');
    });

    test('LayerPrefs: only the person\'s choices are applied on top of the defaults; unknown ids and modes are ignored', () {
      final s = layerStateFromPrefs(const LayerPrefs(toggles: {'network': true, 'pings': false, 'nope': true}, modes: {'pings': 'result'}));
      expect(s.isOn('network'), isTrue);
      expect(s.isOn('pings'), isFalse);
      expect(s.isOn('hexes'), isTrue, reason: 'untouched layers keep their default');
      expect(s.modeOf('pings'), 'result');
      expect(layerStateFromPrefs(const LayerPrefs(modes: {'pings': 'wat'})).modeOf('pings'), 'snr');
      expect(layerStateFromPrefs(LayerPrefs.empty), kDefaultLayerState);
      // The old Settings.mapRepeaterLabels key is the fallback until a choice is made here.
      expect(layerStateFromPrefs(LayerPrefs.empty, labelsFallback: false).isOn('labels'), isFalse);
      expect(layerStateFromPrefs(const LayerPrefs(toggles: {'labels': true}), labelsFallback: false).isOn('labels'), isTrue);
    });
  });

  group('MapLayerState', () {
    test('toggle, mode, equality', () {
      final s = kDefaultLayerState.toggle('network', true).withMode('pings', 'result');
      expect(s.isOn('network'), isTrue);
      expect(s.modeOf('pings'), 'result');
      expect(s.toggle('network', true), same(s));
      expect(s.withMode('pings', 'result'), same(s));
      expect(s.toggle('network', false).withMode('pings', 'snr'), kDefaultLayerState);
      expect(s.hashCode, kDefaultLayerState.toggle('network', true).withMode('pings', 'result').hashCode);
    });

    test('toShow: website keys only and in the website order for web; app keys after for app links', () {
      final s = const MapLayerState(on: {'observers', 'pings', 'network', 'measured'});
      expect(s.toShow(), 'measured,observers,network');
      expect(s.toShow(web: false), 'measured,observers,network,pings');
    });

    test('fromShow: null = defaults; website link keeps the drive layers; app link sets them', () {
      expect(MapLayerState.fromShow(null, defaults: kDefaultLayerState, known: kMapLayerIds), kDefaultLayerState);
      final web = MapLayerState.fromShow(const ['repeaters', 'network'], defaults: kDefaultLayerState, known: kMapLayerIds);
      expect(web.on, {'repeaters', 'network', 'hexes', 'links', 'heard', 'pings', 'labels'}, reason: 'measured and predicted off: not listed');
      final app = MapLayerState.fromShow(const ['measured', 'pings'], defaults: kDefaultLayerState, known: kMapLayerIds, appLink: true);
      expect(app.on, {'measured', 'pings'});
      final none = MapLayerState.fromShow(const [], defaults: kDefaultLayerState, known: kMapLayerIds);
      expect(none.on, {'hexes', 'links', 'heard', 'pings', 'labels'});
    });

    test('layerStateForLink applies show; an old link\'s color= is ignored (one colour metric, D9)', () {
      final link = MapViewState.fromUri(Uri.parse('https://cmh.meshsonar.com/coverage?show=measured,predicted,network&color=noise'))!;
      final s = layerStateForLink(link);
      expect(s.isOn('network'), isTrue);
      expect(s.isOn('predicted'), isTrue);
      expect(s.isOn('repeaters'), isFalse);
      expect(s.modeOf('measured'), isNull);
      expect(layerStateForLink(MapViewState.empty), kDefaultLayerState);
    });
  });

  group('availability', () {
    test('measured coverage in every feed state', () {
      LayerStatus st(MapFeedState s, int n) => layerStatus('measured', MapLayerInputs(coverageState: s, coverageCells: n));
      expect(st(MapFeedState.ready, 753), const LayerStatus(LayerAvailability.ready, detail: '753 cells measured'));
      expect(st(MapFeedState.ready, 1).detail, '1 cell measured');
      expect(st(MapFeedState.ready, 0), const LayerStatus(LayerAvailability.empty, detail: 'Nothing measured here yet'));
      expect(st(MapFeedState.loading, 0).availability, LayerAvailability.loading);
      expect(st(MapFeedState.idle, 0).availability, LayerAvailability.loading);
      expect(st(MapFeedState.failed, 0), const LayerStatus(LayerAvailability.failed, detail: "Couldn't load. Check the connection and retry.", canRetry: true));
      expect(st(MapFeedState.stale, 10), const LayerStatus(LayerAvailability.stale, detail: '10 cells measured · Offline copy', canRetry: true));
      expect(st(MapFeedState.unsupported, 0), const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet'));
      expect(st(MapFeedState.unsupported, 0).enabled, isFalse);
      expect(st(MapFeedState.ready, 0).enabled, isFalse);
      expect(st(MapFeedState.failed, 0).enabled, isTrue);
      expect(st(MapFeedState.loading, 0).enabled, isTrue);
    });

    test('predicted: not on an old server; failed offline; hidden while looking back; ready', () {
      expect(layerStatus('predicted', const MapLayerInputs()), const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet'));
      final off = layerStatus('predicted', const MapLayerInputs(coverageV2: true, tilesOffline: true));
      expect(off.availability, LayerAvailability.failed);
      expect(off.canRetry, isTrue);
      expect(layerStatus('predicted', const MapLayerInputs(coverageV2: true, coverageFiltered: true)).detail, 'Hidden while looking back: the estimate is for today');
      expect(layerStatus('predicted', const MapLayerInputs(coverageV2: true)).detail, 'Estimated from nearby measured cells');
    });

    test('observers: no region, none with a position, some', () {
      expect(layerStatus('observers', const MapLayerInputs()).detail, 'Pick a region to see its observers');
      expect(
        layerStatus('observers', const MapLayerInputs(regionName: 'CMH', observersState: MapFeedState.ready)).detail,
        'No observers with a public position in CMH',
      );
      expect(
        layerStatus('observers', const MapLayerInputs(regionName: 'CMH', observersState: MapFeedState.ready, observersWithPosition: 3)).detail,
        '3 observers with a public position',
      );
    });

    test('F5: a saved copy says when it was fetched; drive layers are always ready', () {
      final saved = layerStatus('measured', MapLayerInputs(coverageState: MapFeedState.stale, coverageCells: 10, coverageSavedAt: DateTime(2026, 11, 1, 9)));
      expect(saved.detail, '10 cells measured · Saved copy from Nov 1');
      expect(saved.canRetry, isTrue);
      for (final id in ['hexes', 'links', 'heard', 'pings', 'labels']) {
        expect(layerStatus(id, const MapLayerInputs()), const LayerStatus(LayerAvailability.ready), reason: id);
      }
      expect(layerStatus('network', const MapLayerInputs()).availability, LayerAvailability.loading, reason: 'no source yet');
    });

    testWidgets('network layer: unsupported (404), loading, failed (503), empty, ready, stale', (t) async {
      final feed = StaticRepeaterMapFeed();
      final src = RepeaterMapSource(feed, clock: () => now);
      await t.pump();
      LayerStatus st() => layerStatus('network', const MapLayerInputs(), repeaters: src);
      expect(st().availability, LayerAvailability.loading);
      expect(st().detail, 'Loading repeaters…');

      feed.global = const MapRepeaterSet(rows: [], state: MapFeedState.unsupported);
      await t.pump();
      expect(st(), const LayerStatus(LayerAvailability.unsupported, detail: 'Not available on this server yet'));

      feed.global = const MapRepeaterSet(rows: [], state: MapFeedState.failed);
      await t.pump();
      expect(st().availability, LayerAvailability.failed);
      expect(st().canRetry, isTrue);

      feed.global = const MapRepeaterSet(rows: [], state: MapFeedState.ready);
      await t.pump();
      expect(st(), const LayerStatus(LayerAvailability.empty, detail: 'No repeaters reported yet'));

      final rows = [
        MapRepeaterRow(key: k('a'), lat: 40, lon: -83, lastSeen: now),
        MapRepeaterRow(key: k('b'), lat: 41, lon: -83),
      ];
      feed.global = MapRepeaterSet(rows: rows, state: MapFeedState.ready, attribution: 'Data: MeshCore Map (map.meshcore.io)', hidden: 4);
      await t.pump();
      await src.settled;
      await t.pump();
      expect(st(), const LayerStatus(LayerAvailability.ready, detail: '2 repeaters · 4 hidden by their owners · Data: MeshCore Map (map.meshcore.io)'));

      feed.global = MapRepeaterSet(rows: rows, state: MapFeedState.stale, attribution: 'Data: MeshCore Map (map.meshcore.io)', freshnessLabel: 'Offline - as of 3h ago');
      await t.pump();
      expect(st().availability, LayerAvailability.stale);
      expect(st().detail, '2 repeaters · Data: MeshCore Map (map.meshcore.io) · Offline - as of 3h ago');
      src.dispose();
    });

    testWidgets('roster layer: no region, loading, empty region, ready', (t) async {
      final feed = StaticRepeaterMapFeed();
      final src = RepeaterMapSource(feed, clock: () => now);
      await t.pump();
      expect(src.statusOf('repeaters').detail, 'Pick a region to see its repeaters');
      expect(src.statusOf('repeaters').enabled, isFalse);
      feed.setRoster(cmh, const [], state: MapFeedState.loading);
      await t.pump();
      expect(src.statusOf('repeaters').detail, 'Loading CMH repeaters…');
      feed.setRoster(cmh, const [RegionRepeater(key: 'aa', hashPrefix: 'aa')]);
      await t.pump();
      expect(src.statusOf('repeaters'), const LayerStatus(LayerAvailability.empty, detail: 'No repeaters with a position in CMH'));
      feed.setRoster(cmh, [RegionRepeater(key: k('c'), hashPrefix: 'cc', lat: 40, lon: -83)]);
      await t.pump();
      await src.settled;
      expect(src.statusOf('repeaters'), const LayerStatus(LayerAvailability.ready, detail: '1 repeater with a position'));
      src.dispose();
    });
  });
}
