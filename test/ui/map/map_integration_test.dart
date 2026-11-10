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
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/radio/radio_api.dart' show GeoFix;
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart' show kNetworkLayerId, kRosterLayerId;
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';
import 'package:meshsonar/ui/region/region_common.dart' as region_common;

import '../fakes.dart';
import 'repeater_probe.dart';
import '../../support/huge_screen.dart';

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

/// A few bounded pumps: with cells on a very tall surface the map keeps tile timers alive, so pumpAndSettle never returns.
Future<void> settleShort(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 300));
  }
}

Future<void> openSheet(WidgetTester t) async {
  await t.tap(find.byKey(const Key('drive-map-layers')));
  await t.pumpAndSettle();
  expect(find.byKey(const Key('layers-sheet')), findsOneWidget);
}

Future<void> closeSheet(WidgetTester t) async {
  await t.tap(find.byKey(const Key('layers-done')));
  await t.pumpAndSettle();
  expect(find.byKey(const Key('layers-sheet')), findsNothing);
}

Switch sw(WidgetTester t, String key) => t.widget<Switch>(find.byKey(Key(key)));

/// The person has turned "All MeshCore repeaters" on (it is off by default for a driver, Drive plan 7.1): remembered, as in the app.
void networkOn() => MapPrefs.shared.setLayerPrefs(kDriveLayerPage, const LayerPrefs(toggles: {'network': true}));
String statusText(WidgetTester t, String id) => t.widget<Text>(find.byKey(Key('layer-$id-status'))).data!;

Future<void> toggle(WidgetTester t, String key) async {
  await revealInLayersSheet(t, find.byKey(Key(key)));
  await t.pumpAndSettle();
  await t.tap(find.byKey(Key(key)));
  await t.pumpAndSettle();
}

void main() {
  late RegionOverviewApi Function(String) savedFactory;
  setUp(() => savedFactory = region_common.regionApiFactory);
  tearDown(() => region_common.regionApiFactory = savedFactory);

  group('generated layers sheet', () {
    testWidgets('sections in plan order, one switch per sheet row, legacy keys kept, no switch for undrawn layers', (t) async {
      useHugeScreen(t);
      final h = Harness(); // no repeater sync, no region index
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      final ys = [
        for (final g in ['coverage', 'network', 'context']) t.getTopLeft(find.byKey(Key('layers-group-$g'), skipOffstage: false)).dy,
      ];
      expect(ys, orderedEquals([...ys]..sort()), reason: 'Coverage, Network, Context (the definition groups)');
      for (final key in [
        'layer-network-coverage', 'layer-heardcells', 'layer-predicted', 'layer-hexes', 'layer-pings', //
        'layer-phones', 'layer-observers', 'layer-region-repeaters', 'layer-labels', 'layer-network', 'layer-links', 'layer-borders',
      ]) {
        expect(find.byKey(Key(key), skipOffstage: false), findsOneWidget, reason: key);
      }
      for (final gone in ['layer-neighbours', 'layer-rings', 'layer-repeaters', 'layer-repeaters-scope']) {
        expect(find.byKey(Key(gone), skipOffstage: false), findsNothing, reason: '$gone is not a row (dead or removed)');
      }
      // Defaults: coverage, this drive, region repeaters (with heard lit) on; the global 56,889-point scope is off (D11 revised).
      expect(sw(t, 'layer-network-coverage').value, isTrue);
      expect(h.state.services.repeaterSync, isNull);
      expect(sw(t, 'layer-region-repeaters').value, isTrue);
      expect(h.state.coverageV2, isFalse);
      expect(sw(t, 'layer-predicted').onChanged, isNull, reason: 'no coverageV2 on this server');
      // No region: honest reasons, switches that cannot work are disabled.
      expect(sw(t, 'layer-observers').onChanged, isNotNull, reason: 'on by default (definition), so it can always be switched off');
      expect(statusText(t, 'observers'), 'Pick a region to see its observers');
      expect(sw(t, 'layer-region-repeaters').onChanged, isNotNull, reason: 'on, so it can always be switched off');
      expect(statusText(t, 'repeaters'), 'Pick a region to see its repeaters');
    });

    testWidgets('measured coverage says how many cells, or that it failed with Retry', (t) async {
      useHugeScreen(t);
      final h = Harness();
      h.client.publicCoverageError = const CmatException('server error', status: 500);
      await h.pumpApp(t);
      await settleShort(t);
      await openSheet(t);
      await revealInLayersSheet(t, find.byKey(const Key('layer-measured-status')));
      expect(statusText(t, 'measured'), "Couldn't load. Check the connection and retry.");
      h.client.publicCoverageError = null;
      h.client.publicCoverageResult = const PublicCoverage(
        asOf: '2026-10-20T12:00:00Z',
        grid: CoverageGrid.square(cellDeg: 0.005),
        cells: [CoverageCell(lat: 40.12, lon: -82.93, pings: 3, heard: 2, bestSnr: 4, medianSnr: 3, repeaters: 1, lastAt: '2026-10-20T11:00:00Z')],
      );
      await revealInLayersSheet(t, find.byKey(const Key('layer-measured-retry')));
      await t.tap(find.byKey(const Key('layer-measured-retry')));
      await settleShort(t);
      expect(statusText(t, 'measured'), '1 cell measured');
      expect(find.byKey(const Key('layer-measured-retry')), findsNothing);
    });
  });

  group('global "All MeshCore repeaters" layer', () {
    setUp(networkOn);
    testWidgets('server answers 404: switch disabled with "Not available on this server yet", nothing drawn', (t) async {
      useHugeScreen(t);
      final srv = FakeMapServer()..networkStatus = 404;
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.globalRepeaterSet.state, SyncState.unsupported);
      await openSheet(t);
      expect(sw(t, 'layer-network').value, isFalse, reason: 'the server does not offer it: shown off, with the reason');
      expect(sw(t, 'layer-network').onChanged, isNull);
      expect(sw(t, 'layer-region-repeaters').value, isTrue, reason: 'Repeaters is its own switch');
      expect(statusText(t, 'network'), 'Not available on this server yet');
      expect(indexedCountOf(t, kNetworkLayerId), 0);
    });

    testWidgets('server error with nothing stored: failed + Retry; the switch still works', (t) async {
      useHugeScreen(t);
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
      await revealInLayersSheet(t, find.byKey(const Key('layer-network-retry')));
      await t.tap(find.byKey(const Key('layer-network-retry')));
      await t.pumpAndSettle();
      expect(srv.networkCalls, calls + 1);
      expect(statusText(t, 'network'), startsWith('3 repeaters in and around Columbus, US'));
    });

    testWidgets('ready: switched on, limited to the phone\'s region + margin, legend + credit; the fullscreen map shares it', (t) async {
      useHugeScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.currentRegion?.code, 'CMH');
      expect(find.byKey(RepeaterPainterLayer.paintKey), findsOneWidget, reason: 'on by default (D3, Andy Oct 24)');
      expect(indexedCountOf(t, kNetworkLayerId), 2, reason: 'the Seattle repeater is outside CMH + 40 km; the roster layer (on by default) draws the 3rd one itself');
      await openSheet(t);
      expect(sw(t, 'layer-network').value, isTrue);
      expect(statusText(t, 'network'), '3 repeaters in and around Columbus, US · 4 hidden by their owners · Data: MeshCore Map (map.meshcore.io)');
      expect(find.byKey(const Key('layer-network-key')), findsOneWidget);
      for (final l in ['heard in 24 h (solid ring)', 'heard in 7 d (dashed ring)', 'older (faded)']) {
        expect(find.descendant(of: find.byKey(const Key('layer-network-key')), matching: find.text(l)), findsOneWidget);
      }
      await closeSheet(t);
      expect(find.byKey(RepeaterPainterLayer.paintKey), findsOneWidget);
      expect(find.byKey(const Key('map-network-attribution')), findsNothing, reason: 'no legend stack on the map; the key lives in the Credits sheet');
      expect(find.byKey(const Key('map-attribution-meshcore')), findsOneWidget, reason: 'MeshCore Map is credited in the corner line while its layer draws');
      await t.tap(find.byKey(const Key('map-attribution-info')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('credits-sheet')), findsOneWidget);
      expect(find.byKey(const Key('credits-meshcore')), findsOneWidget);
      expect(find.byKey(const Key('map-network-attribution')), findsOneWidget);
      expect(find.byKey(const Key('map-network-legend')), findsOneWidget);
      await t.tapAt(const Offset(200, 40));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));

      await t.tap(find.byKey(const Key('map-fullscreen')));
      await t.pump();
      await t.pump();
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byKey(RepeaterPainterLayer.paintKey, skipOffstage: false), findsOneWidget, reason: 'one map instance: expanding does not mount a second');
    });

    testWidgets('stale: the stored list stays on, the sheet says it is an offline copy with Retry', (t) async {
      useHugeScreen(t);
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
      expect(find.byKey(RepeaterPainterLayer.paintKey), findsOneWidget, reason: 'offline copy still drawn');
    });

    testWidgets('roster on too: the roster key is drawn once (by the roster layer), the global count drops by one', (t) async {
      useHugeScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      // A remembered "network on" from an older build leaves the roster on too: both draw, the roster key once.
      expect(h.state.services.repeaterSync, isNotNull);
      expect(indexedCountOf(t, kNetworkLayerId), 2, reason: 'global without the roster key');
      expect(indexedCountOf(t, kRosterLayerId), 1);
    });

    testWidgets('cluster tap zooms in to its members; then a tap on one opens its sheet with the roster-free fields', (t) async {
      useHugeScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      await h.pumpApp(t);
      await t.pumpAndSettle();
      final paint = find.byKey(RepeaterPainterLayer.paintKey);
      RepeaterPainter painter() => t.widget<CustomPaint>(paint).painter! as RepeaterPainter;
      Offset screenOf(LatLng p) => t.getTopLeft(paint) + painter().camera.latLngToScreenOffset(p);
      final zoom0 = painter().camera.zoom;
      await t.tapAt(screenOf(const LatLng(40.12661, -82.93051)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsNothing, reason: 'a cluster zooms, it opens no sheet');
      expect(painter().camera.zoom, greaterThan(zoom0 + 1));
      expect(find.byKey(const Key('map-recenter')), findsOneWidget, reason: 'following stopped: the camera moved to the cluster');

      await t.tapAt(screenOf(const LatLng(40.1265, -82.9305)));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('info-panel-header')), findsOneWidget);
      expect(find.byKey(const Key('repeater-sheet')), findsNothing, reason: 'the panel opens collapsed: the map stays the focus');
      await t.tap(find.byKey(const Key('info-panel-header')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
      expect(find.text('Alpha'), findsWidgets);
      expect(find.descendant(of: find.byKey(const Key('repeater-sheet')), matching: find.text('Data: MeshCore Map (map.meshcore.io)')), findsOneWidget);
      expect(find.byKey(const Key('repeater-sheet-status')), findsNothing, reason: 'not in the roster');
    });
  });

  group('global layer scope', () {
    setUp(networkOn);
    testWidgets('phone outside every region: the whole list (world view, count clusters); picking a region limits it', (t) async {
      useHugeScreen(t);
      final srv = FakeMapServer();
      final h = make(srv);
      h.location.currentFix = () => GeoFix(lat: 47.6, lon: -122.3, at: DateTime.utc(2026, 10, 16, 17, 59));
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.currentRegion, isNull);
      expect(indexedCountOf(t, kNetworkLayerId), 3, reason: 'no region detected or picked: every repeater, minus the roster one the roster layer (on by default) draws');
      await openSheet(t);
      expect(statusText(t, 'network'), startsWith('4 repeaters · '));
      await closeSheet(t);

      await h.state.setViewingRegion('CMH');
      await t.pumpAndSettle();
      expect(h.state.viewingIsManual, isTrue);
      expect(indexedCountOf(t, kNetworkLayerId), 2, reason: 'picked region: CMH + 40 km only, minus the roster one');
    });
  });

  group('region roster layer', () {
    testWidgets('from the sync: tap a roster repeater for its sheet with roster fields and "Open repeater page"', (t) async {
      useHugeScreen(t);
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      expect(h.state.globalRepeaterSet, isNotNull);
      final paint = find.byKey(RepeaterPainterLayer.paintKey);
      final painter = t.widget<CustomPaint>(paint).painter! as RepeaterPainter;
      await t.tapAt(t.getTopLeft(paint) + painter.camera.latLngToScreenOffset(const LatLng(40.13, -82.92)));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('info-panel-header'))); // the panel opens collapsed
      await t.pumpAndSettle();
      expect(find.byKey(const Key('repeater-sheet')), findsOneWidget);
      expect(find.text('Roster-C'), findsWidgets);
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
      useHugeScreen(t);
      serveObservers();
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      // On by default (Map Definition `observers.defaultOn`): fetched for the viewed region at once.
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
      useHugeScreen(t);
      serveObservers(fail: true);
      final h = make(FakeMapServer());
      await h.pumpApp(t);
      await t.pumpAndSettle();
      await openSheet(t);
      expect(statusText(t, 'observers'), "Couldn't load. Check the connection and retry.");
      serveObservers();
      await revealInLayersSheet(t, find.byKey(const Key('layer-observers-retry')));
      await t.tap(find.byKey(const Key('layer-observers-retry')));
      await t.pumpAndSettle();
      expect(statusText(t, 'observers'), '1 observer with a public position');
    });
  });
}
