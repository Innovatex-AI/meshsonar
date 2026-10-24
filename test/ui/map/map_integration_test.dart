// WP-M2/M3 on screen, with the real AppState (test/ui/fakes.dart Harness) and a memory-only RepeaterSync talking to a
// fake server: the generated layers sheet (sections, legacy keys, honest status per layer), the global "All MeshCore
// repeaters" layer in every state (unsupported 404 / failed / ready / stale offline copy), the roster from the sync,
// cluster tap -> zoom -> repeater sheet on the Drive map, observers from region-observers, and the fullscreen map
// sharing the layer state.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/radio/radio_api.dart' show GeoFix;
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/ui/map/layers/clustered_points_layer.dart' show ClusteredPointsPainter;
import 'package:meshsonar/ui/region/region_common.dart' as region_common;

import '../fakes.dart';

const cmh = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus, US', url: 'https://cmh.meshsonar.com', bbox: [-83.5, 39.75, -82.45, 40.65]);
String k(String c) => c * 64;
final syncNow = DateTime.utc(2026, 10, 16, 18);
final advertEpoch = syncNow.subtract(const Duration(hours: 2)).millisecondsSinceEpoch ~/ 1000;

/// Fake server: the CMH roster and the global network list near the phone (40.126, -82.93).
class FakeMapServer {
  /// The sync's clock (forced refreshes are floored at 10 s: tests move it on).
  DateTime now = syncNow;
  int networkStatus = 200;
  bool offline = false;
  int networkCalls = 0;
  late final http.Client client = MockClient((req) async {
    final p = req.url.path;
    if (p.endsWith('/region-repeaters')) {
      if (offline) throw const SocketException('offline');
      return http.Response(
        jsonEncode({
          'status': {'state': 'ready', 'reason': null, 'computedAt': '2026-10-16T17:00:00Z'},
          'rows': [
            {'key': k('c'), 'hashPrefix': 'cc', 'name': 'Roster-C', 'role': 'repeater', 'lat': 40.13, 'lon': -82.92, 'status': 'active', 'snrMeanDb': 4.5},
          ],
          'counts': {'active': 1},
        }),
        200,
      );
    }
    if (p == '/api/cmh/network-repeaters') {
      networkCalls++;
      if (offline) throw const SocketException('offline');
      if (networkStatus != 200) return http.Response('{"error":"nope"}', networkStatus);
      return http.Response(
        jsonEncode({
          'v': 1,
          'asOf': '2026-10-16T12:00:00Z',
          'count': 4,
          'hidden': 4,
          'attribution': {'name': 'MeshCore Map', 'url': 'https://map.meshcore.io'},
          'rows': [
            // Two repeaters 25 m apart (one cluster at street zoom) and the roster's own key.
            [k('a'), 'Alpha', 40.1265, -82.9305, 2, advertEpoch],
            [k('b'), 'Bravo', 40.12672, -82.93052, 3, advertEpoch],
            [k('c'), 'Roster-C (global)', 40.13, -82.92, 2, null],
            // Seattle: outside Columbus' bbox + 40 km, left out while CMH is the phone's region.
            [k('d'), 'Seattle', 47.61, -122.33, 2, advertEpoch],
          ],
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });
}

Harness make(FakeMapServer srv) {
  final h = Harness();
  h.repeaterSync = RepeaterSync(rosterClient: () => srv.client, networkClient: () => srv.client, clock: () => srv.now, parseInIsolate: false);
  h.client.regionsIndexResult = const [cmh];
  return h;
}

Future<void> openSheet(WidgetTester t) async {
  await t.tap(find.byKey(const Key('drive-map-layers')));
  await t.pumpAndSettle();
  expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
}

Future<void> closeSheet(WidgetTester t) async {
  await t.tapAt(const Offset(200, 40));
  await t.pumpAndSettle();
  expect(find.byKey(const Key('layers-sheet')), findsNothing);
}

SwitchListTile sw(WidgetTester t, String key) => t.widget<SwitchListTile>(find.byKey(Key(key)));
String statusText(WidgetTester t, String id) => t.widget<Text>(find.byKey(Key('layer-$id-status'))).data!;

Future<void> toggle(WidgetTester t, String key) async {
  await t.ensureVisible(find.byKey(Key(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle();
}

void main() {
  late RegionOverviewApi Function(String) savedFactory;
  setUp(() => savedFactory = region_common.regionApiFactory);
  tearDown(() => region_common.regionApiFactory = savedFactory);

  group('generated layers sheet', () {
    testWidgets('sections in registry order, one switch per drawn layer, legacy keys kept, no switch for undrawn layers', (t) async {
      useTallScreen(t);
      final h = Harness(); // no repeater sync, no region index
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      final ys = [
        for (final g in ['drive', 'coverage', 'network', 'context']) t.getTopLeft(find.byKey(Key('layers-group-$g'), skipOffstage: false)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'This drive, Coverage, Network, Around you');
      for (final key in [
        'layer-hexes', 'layer-links', 'layer-repeaters', 'layer-pings', 'layer-network-coverage', //
        'layer-network', 'layer-region-repeaters', 'layer-observers', 'layer-rings',
      ]) {
        expect(find.byKey(Key(key), skipOffstage: false), findsOneWidget, reason: key);
      }
      expect(find.byKey(const Key('layer-neighbours'), skipOffstage: false), findsNothing, reason: 'no renderer yet (WP-M4)');
      // Defaults: drive layers + coverage + the global layer on (D3); it shows off here because this build cannot
      // offer it (no sync), and its switch is disabled.
      expect(sw(t, 'layer-repeaters').value, isTrue);
      expect(sw(t, 'layer-network-coverage').value, isTrue);
      expect(h.state.services.repeaterSync, isNull);
      expect(sw(t, 'layer-network').value, isFalse);
      expect(sw(t, 'layer-region-repeaters').value, isFalse);
      // No sync in this build and no region: honest reasons, switches that cannot work are disabled.
      expect(sw(t, 'layer-network').onChanged, isNull);
      expect(statusText(t, 'network'), 'Not available on this server yet');
      expect(sw(t, 'layer-observers').onChanged, isNull);
      expect(statusText(t, 'observers'), 'Pick a region to see its observers');
      expect(sw(t, 'layer-region-repeaters').onChanged, isNull);
      expect(statusText(t, 'repeaters'), 'Pick a region to see its repeaters');
    });

    testWidgets('measured coverage says how many cells, or that it failed with Retry', (t) async {
      useTallScreen(t);
      final h = Harness();
      h.client.publicCoverageError = const CmatException('server error', status: 500);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      await t.ensureVisible(find.byKey(const Key('layer-measured-status')));
      expect(statusText(t, 'measured'), "Couldn't load. Check the connection and retry.");
      h.client.publicCoverageError = null;
      h.client.publicCoverageResult = const PublicCoverage(
        asOf: '2026-10-20T12:00:00Z',
        grid: CoverageGrid.square(cellDeg: 0.005),
        cells: [CoverageCell(lat: 40.12, lon: -82.93, pings: 3, heard: 2, bestSnr: 4, medianSnr: 3, repeaters: 1, lastAt: '2026-10-20T11:00:00Z')],
      );
      await t.ensureVisible(find.byKey(const Key('layer-measured-retry')));
      await t.tap(find.byKey(const Key('layer-measured-retry')));
      await t.pumpAndSettle();
      expect(statusText(t, 'measured'), '1 cell measured');
      expect(find.byKey(const Key('layer-measured-retry')), findsNothing);
    });
  });

  group('global "All MeshCore repeaters" layer', () {
    testWidgets('server answers 404: switch disabled with "Not available on this server yet", nothing drawn', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer()..networkStatus = 404;
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.globalRepeaterSet.state, SyncState.unsupported);
      await openSheet(t);
      expect(sw(t, 'layer-network').onChanged, isNull);
      expect(sw(t, 'layer-network').value, isFalse, reason: 'default on, but shown off: the server cannot offer it');
      expect(statusText(t, 'network'), 'Not available on this server yet');
      expect(find.byKey(const ValueKey('layer-network-paint')), findsNothing);
    });

    testWidgets('server error with nothing stored: failed + Retry; the switch still works', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer()..networkStatus = 503;
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      expect(statusText(t, 'network'), "Couldn't load. Check the connection and retry.");
      expect(sw(t, 'layer-network').onChanged, isNotNull);
      final calls = srv.networkCalls;
      srv.networkStatus = 200;
      srv.now = srv.now.add(const Duration(seconds: 11));
      await t.ensureVisible(find.byKey(const Key('layer-network-retry')));
      await t.tap(find.byKey(const Key('layer-network-retry')));
      await t.pumpAndSettle();
      expect(srv.networkCalls, calls + 1);
      expect(statusText(t, 'network'), startsWith('3 repeaters in and around Columbus, US'));
    });

    testWidgets('ready: ON by default, limited to the phone\'s region + margin, legend + credit; the fullscreen map shares it', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.currentRegion?.code, 'CMH');
      expect(find.byKey(const ValueKey('layer-network-paint')), findsOneWidget, reason: 'on by default (D3, Andy Oct 24)');
      final painter = t.widget<CustomPaint>(find.byKey(const ValueKey('layer-network-paint'))).painter! as ClusteredPointsPainter;
      expect(painter.index.indexedCount, 3, reason: 'the Seattle repeater is outside CMH + 40 km');
      await openSheet(t);
      expect(sw(t, 'layer-network').value, isTrue);
      expect(statusText(t, 'network'), '3 repeaters in and around Columbus, US · 4 hidden by their owners · Data: MeshCore Map (map.meshcore.io)');
      expect(find.byKey(const Key('network-legend')), findsOneWidget);
      expect(find.textContaining('MeshCore Map data as of '), findsOneWidget);
      for (final l in ['24 h', '7 d', '30 d', 'Older']) {
        expect(find.descendant(of: find.byKey(const Key('network-legend')), matching: find.text(l)), findsOneWidget);
      }
      await closeSheet(t);
      expect(find.byKey(const ValueKey('layer-network-paint')), findsOneWidget);
      expect(find.byKey(const Key('map-network-attribution')), findsOneWidget);
      expect(find.byKey(const Key('map-network-legend')), findsOneWidget);

      await t.tap(find.byKey(const Key('map-fullscreen')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const ValueKey('layer-network-paint'), skipOffstage: false), findsNWidgets(2), reason: 'both maps draw it (layer state is shared)');
    });

    testWidgets('stale: the stored list stays on, the sheet says it is an offline copy with Retry', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      srv.offline = true;
      srv.now = srv.now.add(const Duration(minutes: 5));
      await h.state.syncRepeaterLists(SyncTrigger.force);
      await t.pumpAndSettle();
      expect(h.state.globalRepeaterSet.state, SyncState.stale);
      await openSheet(t);
      expect(statusText(t, 'network'), startsWith('3 repeaters in and around Columbus, US · 4 hidden by their owners · Data: MeshCore Map (map.meshcore.io) · Offline'));
      expect(find.byKey(const Key('layer-network-retry')), findsOneWidget);
      await closeSheet(t);
      expect(find.byKey(const ValueKey('layer-network-paint')), findsOneWidget, reason: 'offline copy still drawn');
    });

    testWidgets('roster on too: the roster key is drawn once (by the roster layer), the global count drops by one', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      expect(statusText(t, 'repeaters'), '1 repeater with a position');
      await toggle(t, 'layer-region-repeaters');
      expect(find.byKey(const Key('roster-legend')), findsOneWidget);
      await closeSheet(t);
      final painters = [
        for (final key in ['layer-network-paint', 'layer-repeaters-paint'])
          t.widget<CustomPaint>(find.byKey(ValueKey(key))).painter! as ClusteredPointsPainter,
      ];
      expect(painters[0].index.indexedCount, 2, reason: 'global without the roster key');
      expect(painters[1].index.indexedCount, 1);
    });

    testWidgets('cluster tap zooms in to its members; then a tap on one opens its sheet with the roster-free fields', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      final paint = find.byKey(const ValueKey('layer-network-paint'));
      ClusteredPointsPainter painter() => t.widget<CustomPaint>(paint).painter! as ClusteredPointsPainter;
      Offset screenOf(LatLng p) => t.getTopLeft(paint) + painter().camera.latLngToScreenOffset(p);
      final zoom0 = painter().camera.zoom;
      await t.tapAt(screenOf(const LatLng(40.12661, -82.93051)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsNothing, reason: 'a cluster zooms, it opens no sheet');
      expect(painter().camera.zoom, greaterThan(zoom0 + 1));
      expect(find.byKey(const Key('map-recenter')), findsOneWidget, reason: 'following stopped: the camera moved to the cluster');

      await t.tapAt(screenOf(const LatLng(40.1265, -82.9305)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('repeater-sheet')), matching: find.text('Data: MeshCore Map (map.meshcore.io)')), findsOneWidget);
      expect(find.byKey(const Key('repeater-sheet-status')), findsNothing, reason: 'not in the roster');
    });
  });

  group('global layer scope', () {
    testWidgets('phone outside every region: the whole list (world view, count clusters); picking a region limits it', (t) async {
      useTallScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      h.location.currentFix = () => GeoFix(lat: 47.6, lon: -122.3, at: DateTime.utc(2026, 10, 16, 17, 59));
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.currentRegion, isNull);
      ClusteredPointsPainter painter() => t.widget<CustomPaint>(find.byKey(const ValueKey('layer-network-paint'))).painter! as ClusteredPointsPainter;
      expect(painter().index.indexedCount, 4, reason: 'no region detected or picked: every repeater');
      await openSheet(t);
      expect(statusText(t, 'network'), startsWith('4 repeaters · '));
      await closeSheet(t);

      await h.state.setViewingRegion('CMH');
      await t.pumpAndSettle();
      expect(h.state.viewingIsManual, isTrue);
      expect(painter().index.indexedCount, 3, reason: 'picked region: CMH + 40 km only');
    });
  });

  group('region roster layer', () {
    testWidgets('from the sync: tap a roster repeater for its sheet with roster fields and "Open repeater page"', (t) async {
      useTallScreen(t);
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      await toggle(t, 'layer-region-repeaters');
      await closeSheet(t);
      final paint = find.byKey(const ValueKey('layer-repeaters-paint'));
      final painter = t.widget<CustomPaint>(paint).painter! as ClusteredPointsPainter;
      await t.tapAt(t.getTopLeft(paint) + painter.camera.latLngToScreenOffset(const LatLng(40.13, -82.92)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
      expect(find.text('Roster-C'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
      expect(find.text('+4.5 dB'), findsOneWidget);
      expect(find.textContaining('MeshSonar region roster (Columbus, US)'), findsOneWidget);
      expect(find.byKey(const Key('repeater-sheet-open')), findsOneWidget);
    });
  });

  group('observers layer', () {
    void serveObservers({bool fail = false}) {
      region_common.regionApiFactory = (b) => RegionOverviewApi(
        b,
        client: MockClient((req) async {
          if (fail) return http.Response('{"error":"down"}', 500);
          return http.Response(
            jsonEncode({
              'status': {'state': 'ready', 'reason': null},
              'rows': [
                {'key': 'o1' * 32, 'name': 'Hilltop', 'online': true, 'lat': 40.13, 'lon': -82.93, 'noiseFloorDbm': -112.4, 'source': 'corescope'},
                {'key': 'o2' * 32, 'name': 'Private', 'online': true, 'lat': null, 'lon': null, 'source': 'meshsonar'},
                {'key': 'o3' * 32, 'name': 'Zero', 'online': false, 'lat': 0, 'lon': 0},
              ],
            }),
            200,
          );
        }),
      );
    }

    testWidgets('counts only observers with a public position; turning it on draws them', (t) async {
      useTallScreen(t);
      serveObservers();
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      expect(statusText(t, 'observers'), 'Loading…', reason: 'not fetched until the layer is wanted');
      await toggle(t, 'layer-observers');
      expect(statusText(t, 'observers'), '1 observer with a public position');
      await closeSheet(t);
      expect(find.byKey(Key('map-observer-${'o1' * 32}')), findsOneWidget);
      expect(find.byKey(Key('map-observer-${'o2' * 32}')), findsNothing, reason: 'owner keeps the position private');
      expect(find.byKey(Key('map-observer-${'o3' * 32}')), findsNothing, reason: '0/0 is not a position');
      await t.tap(find.byKey(Key('map-observer-${'o1' * 32}')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('observer-sheet')), findsOneWidget);
      expect(find.text('Hilltop'), findsOneWidget);
      expect(find.text('-112 dBm'), findsOneWidget);
      expect(find.textContaining('Observer seen through CoreScope (Columbus, US)'), findsOneWidget);
    });

    testWidgets('the fetch fails: failed with Retry, nothing drawn, the rest of the map unaffected', (t) async {
      useTallScreen(t);
      serveObservers(fail: true);
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      await toggle(t, 'layer-observers');
      expect(statusText(t, 'observers'), "Couldn't load. Check the connection and retry.");
      serveObservers();
      await t.ensureVisible(find.byKey(const Key('layer-observers-retry')));
      await t.tap(find.byKey(const Key('layer-observers-retry')));
      await t.pumpAndSettle();
      expect(statusText(t, 'observers'), '1 observer with a public position');
    });
  });
}
