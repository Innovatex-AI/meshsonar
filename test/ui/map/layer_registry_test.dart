// The layer registry, MapLayerState <-> ?show=, and every layer's availability text.
import 'package:flutter_test/flutter_test.dart';
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
      expect(kMapLayers.map((l) => l.id).toSet(),
          {'predicted', 'heardcells', 'measured', 'hexes', 'pings', 'links', 'heard', 'repeaters', 'network', 'observers', 'labels'});
      expect(kMapLayers, hasLength(11));
      expect(layerSpec('heardcells')!.z, greaterThan(layerSpec('predicted')!.z));
      expect(layerSpec('heardcells')!.z, lessThan(layerSpec('measured')!.z), reason: 'a pinged cell shows its Measured colour');
      expect(layerSpec('rings'), isNull);
      expect(layerSpec('neighbours'), isNull);
      expect(kAppOnlyShowKeys, isNot(contains('rings')));
      expect(layerSpec('predicted')!.z, lessThan(layerSpec('measured')!.z), reason: 'predicted is drawn UNDER measured (D8)');
    });

    test('defaults: both coverage layers and This drive on; network (56,889 points) and observers off', () {
      expect(kDefaultLayerState.on, {'predicted', 'heardcells', 'measured', 'hexes', 'links', 'heard', 'pings', 'repeaters', 'labels'});
      expect(kDefaultLayerState.mode, {'pings': 'snr'}, reason: 'no colour-by mode any more (D9)');
      expect(layerSpec('network')!.label, 'All MeshCore repeaters');
      expect(layerSpec('network')!.defaultOn, isFalse);
      expect(layerSpec('nope'), isNull);
      expect(LayerGroup.values.map((g) => g.label), ['Coverage', 'Network']);
      // The sheet's rows, website names for the two coverage layers (parity rule).
      expect([for (final r in kSheetRows[LayerGroup.coverage]!) r.id], ['measured', 'predicted', 'heardcells', 'hexes', 'pings']);
      expect([for (final r in kSheetRows[LayerGroup.network]!) r.id], ['repeaters', 'labels', 'observers', 'links']);
      expect([for (final id in ['measured', 'predicted', 'hexes', 'pings', 'repeaters', 'labels', 'links']) layerSpec(id)!.label],
          ['Measured coverage', 'Predicted coverage', 'This drive', 'Ping dots', 'Repeaters', 'Names', 'Lines to repeaters']);
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
      final s = kDefaultLayerState.toggle('observers', true).withMode('pings', 'result');
      expect(s.isOn('observers'), isTrue);
      expect(s.modeOf('pings'), 'result');
      expect(s.toggle('observers', true), same(s));
      expect(s.withMode('pings', 'result'), same(s));
      expect(s.toggle('observers', false).withMode('pings', 'snr'), kDefaultLayerState);
      expect(s.hashCode, kDefaultLayerState.toggle('observers', true).withMode('pings', 'result').hashCode);
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
