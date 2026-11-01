// The layer registry, MapLayerState <-> ?show=, the MapLayers adapter, and every layer's availability text.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/map_view_state.dart';
import 'package:meshsonar/core/region_repeaters_api.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/map_layers_adapter.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/map_layers.dart';

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

    test('defaults: the drive layers, measured and the global repeater layer on (D3, Andy Oct 24); roster/observers off', () {
      expect(kDefaultLayerState.on, {'measured', 'hexes', 'links', 'heard', 'pings', 'rings', 'network', 'labels'});
      // MapLayers has no field for `network`: its defaults are the registry defaults minus the global layer.
      expect(kDefaultLayerState.toggle('network', false).toggle('labels', false), const MapLayers().toLayerState(mode: const {'measured': 'snr'}));
      expect(layerSpec('network')!.label, 'All MeshCore repeaters');
      expect(layerSpec('nope'), isNull);
      final groups = layersByGroup();
      expect(groups[LayerGroup.network]!.map((l) => l.id), ['network', 'repeaters', 'observers', 'neighbours', 'labels']);
      expect(groups[LayerGroup.coverage]!.map((l) => l.id), ['measured']);
      expect(LayerGroup.values.map((g) => g.label).toSet(), hasLength(4));
    });
  });

  group('MapLayerState', () {
    test('toggle, mode, equality', () {
      final s = kDefaultLayerState.toggle('network', true).withMode('measured', 'noise');
      expect(s.isOn('network'), isTrue);
      expect(s.modeOf('measured'), 'noise');
      expect(s.toggle('network', true), same(s));
      expect(s.withMode('measured', 'noise'), same(s));
      expect(s.withMode('measured', 'snr'), kDefaultLayerState, reason: 'network is a default layer');
      expect(s.toggle('network', false).withMode('measured', 'snr'), isNot(kDefaultLayerState));
      expect(s.hashCode, kDefaultLayerState.toggle('network', true).withMode('measured', 'noise').hashCode);
    });

    test('toShow: website keys only and in the website order for web; app keys after for app links', () {
      final s = const MapLayerState(on: {'observers', 'pings', 'network', 'measured'});
      expect(s.toShow(), 'measured,observers,network');
      expect(s.toShow(web: false), 'measured,observers,network,pings');
    });

    test('fromShow: null = defaults; website link keeps the drive layers; app link sets them', () {
      expect(MapLayerState.fromShow(null, defaults: kDefaultLayerState, known: kMapLayerIds), kDefaultLayerState);
      final web = MapLayerState.fromShow(const ['repeaters', 'network'], defaults: kDefaultLayerState, known: kMapLayerIds);
      expect(web.on, {'repeaters', 'network', 'hexes', 'links', 'heard', 'pings', 'rings', 'labels'}, reason: 'measured off: not listed');
      final app = MapLayerState.fromShow(const ['measured', 'pings'], defaults: kDefaultLayerState, known: kMapLayerIds, appLink: true);
      expect(app.on, {'measured', 'pings'});
      final none = MapLayerState.fromShow(const [], defaults: kDefaultLayerState, known: kMapLayerIds);
      expect(none.on, {'hexes', 'links', 'heard', 'pings', 'rings', 'labels'});
    });

    test('layerStateForLink applies show and color from a parsed link', () {
      final link = MapViewState.fromUri(Uri.parse('https://cmh.meshsonar.com/coverage?show=measured,network&color=noise'))!;
      final s = layerStateForLink(link);
      expect(s.isOn('network'), isTrue);
      expect(s.isOn('repeaters'), isFalse);
      expect(s.modeOf('measured'), 'noise');
      expect(layerStateForLink(MapViewState.empty), kDefaultLayerState);
    });
  });

  group('MapLayers adapter', () {
    test('round trip for every bool and the ping colour mode', () {
      const variants = [
        MapLayers(),
        MapLayers(pings: false, hexes: false, repeaters: false, links: false, rings: false, networkCoverage: false),
        MapLayers(regionRepeaters: true, pingColors: PingColorMode.result),
      ];
      for (final m in variants) {
        expect(mapLayersFromState(m.toLayerState()), m);
      }
      final s = const MapLayers(regionRepeaters: true, repeaters: false).toLayerState();
      expect(s.isOn('repeaters'), isTrue, reason: 'regionRepeaters is the website\'s repeaters');
      expect(s.isOn('heard'), isFalse, reason: 'MapLayers.repeaters is the heard beacons');
      expect(const MapLayers(pingColors: PingColorMode.result).toLayerState().modeOf('pings'), 'result');
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

    test('neighbours need a selected repeater; drive layers are always ready', () {
      expect(layerStatus('neighbours', const MapLayerInputs()).enabled, isFalse);
      expect(layerStatus('neighbours', const MapLayerInputs(repeaterSelected: true)).enabled, isTrue);
      for (final id in ['hexes', 'links', 'heard', 'pings', 'rings', 'labels']) {
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
