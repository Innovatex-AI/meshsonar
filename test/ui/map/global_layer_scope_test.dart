// "All MeshCore repeaters" (stream-1 §15, Andy Oct 24 2026): default ON, limited to the detected/selected region's box
// grown by 40 km, the whole list as count clusters when no region is known; the edge of the margin, and a delta
// refresh flowing through to the layer (changed rows rebuild it, an empty delta does not).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/ui/map/layers/app_repeater_feed.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show kNetworkLayerId;

import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
String hexKey(int i) => i.toRadixString(16).padLeft(4, '0') * 16;

void main() {
  late DateTime clock;
  late int deltaMode; // 0 = 404 (no delta), 1 = one new row, 2 = nothing changed
  setUp(() {
    clock = DateTime.utc(2026, 10, 24, 12);
    deltaMode = 0;
  });

  // North edge of the CMH box is lat 40.65; the margin is 40 km = 0.3593 degrees of latitude.
  final rows = [
    [hexKey(1), 'inside', 40.2, -83.0, 2, 1792850000],
    [hexKey(2), 'north 39 km', 40.65 + 39 / 111.32, -83.0, 2, 1792850000],
    [hexKey(3), 'north 41 km', 40.65 + 41 / 111.32, -83.0, 2, 1792850000],
    [hexKey(4), 'seattle', 47.6, -122.3, 2, 1792850000],
    [hexKey(5), 'west 60 km', 40.2, -83.5 - 60 / (111.32 * 0.9), 2, 1792850000],
  ];

  http.Client server() => MockClient((req) async {
    if (req.url.path != '/api/cmh/network-repeaters') return http.Response('nope', 404);
    final since = req.url.queryParameters['updated_since'];
    if (since != null) {
      if (deltaMode == 0) return http.Response('{"code":"since_too_old"}', 410);
      final add = deltaMode == 1 ? [[hexKey(6), 'new inside', 40.3, -83.1, 2, 1792850000]] : <List<Object?>>[];
      return http.Response(
        jsonEncode({'v': 1, 'asOfS': clock.millisecondsSinceEpoch ~/ 1000 - 120, 'count': add.length, 'removedCount': 0, 'rows': add, 'removed': <String>[]}),
        200,
      );
    }
    return http.Response(jsonEncode({'v': 1, 'asOf': '2026-10-24T11:00:00Z', 'count': rows.length, 'hidden': 0, 'rows': rows}), 200);
  });

  Future<Harness> boot({required bool regionKnown, bool delta = false}) async {
    final c = server();
    final h = Harness();
    h.repeaterSync = RepeaterSync(rosterClient: () => c, networkClient: () => c, clock: () => clock, parseInIsolate: false);
    h.client.regionsIndexResult = regionKnown ? const [cmh] : const [];
    if (delta) h.client.siteConfigResult = const SiteConfig(region: RegionInfo(slug: 'cmh', url: 'https://cmh.meshsonar.com'), capabilities: {'networkRepeatersDelta'});
    await h.state.init();
    await h.state.launchSettled.timeout(const Duration(seconds: 20));
    return h;
  }

  test('the registry has the layer on by default', () {
    final spec = kMapLayers.firstWhere((l) => l.id == kNetworkLayerId);
    expect(spec.label, 'All MeshCore repeaters');
    expect(spec.defaultOn, isTrue);
    expect(kDefaultLayerState.on, contains(kNetworkLayerId));
  });

  test('a detected region: the box grown by 40 km, nothing beyond (39 km in, 41 km out, other cities out)', () async {
    final h = await boot(regionKnown: true);
    expect(h.state.currentRegion?.code, 'CMH');
    final feed = AppStateRepeaterFeed(h.state);
    addTearDown(feed.dispose);
    expect(feed.global.rows.map((r) => r.name).toSet(), {'inside', 'north 39 km'}, reason: 'west 60 km is past the margin too');
    expect(feed.global.scope, 'Columbus, US');
    expect(feed.global.state.name, 'ready');
    expect(h.state.globalRepeaterSet.rows, hasLength(5), reason: 'the stored list itself stays whole');
  });

  test('a picked region scopes the layer even when the phone is elsewhere', () async {
    final h = await boot(regionKnown: true);
    await h.state.setViewingRegion('CMH');
    expect(AppStateRepeaterFeed.scopeRegion(h.state)?.code, 'CMH');
  });

  test('no region known (world view): the whole list, unscoped', () async {
    final h = await boot(regionKnown: false);
    expect(AppStateRepeaterFeed.scopeRegion(h.state), isNull);
    final feed = AppStateRepeaterFeed(h.state);
    addTearDown(feed.dispose);
    expect(feed.global.rows, hasLength(5));
    expect(feed.global.scope, isNull);
  });

  test('a delta refresh reaches the layer: new rows rebuild it (scoped), an empty delta keeps the same rows list', () async {
    final h = await boot(regionKnown: true, delta: true);
    final feed = AppStateRepeaterFeed(h.state);
    addTearDown(feed.dispose);
    final first = feed.global.rows;
    expect(first, hasLength(2));
    final sync = h.state.repeaterSync!;
    await sync.writesDone;

    deltaMode = 1;
    clock = clock.add(const Duration(hours: 7));
    await sync.syncNetwork(server: Uri.parse(h.state.settings.serverUrl), trigger: SyncTrigger.resume);
    expect(sync.network!.data.rows, hasLength(6));
    expect(feed.global.rows.map((r) => r.name).toSet(), {'inside', 'north 39 km', 'new inside'});

    final second = feed.global.rows;
    deltaMode = 2;
    clock = clock.add(const Duration(hours: 7));
    await sync.syncNetwork(server: Uri.parse(h.state.settings.serverUrl), trigger: SyncTrigger.resume);
    expect(identical(feed.global.rows, second), isTrue, reason: 'nothing changed: the map layer is not rebuilt');
  });
}
