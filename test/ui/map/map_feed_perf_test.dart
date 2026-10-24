// The AppState-backed repeater feed (roster key lookup by map, quiet on unrelated AppState changes, identity kept),
// advert-age bands recomputed on refresh / on demand, the observer sheet in both unit systems, and 15,000- and 55,000-point
// synthetic global sets that must build (off the UI isolate) and render on CoverageMap inside a widget test.
// Timings are printed (Mac host VM under `flutter test`, JIT: not a phone).
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/region_overview_api.dart';
import 'package:meshsonar/core/repeater_points.dart';
import 'package:meshsonar/core/repeater_sync.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/ui/map/coverage_map.dart';
import 'package:meshsonar/ui/map/layers/app_repeater_feed.dart';
import 'package:meshsonar/ui/map/layers/clustered_points_layer.dart' show ClusteredPointsPainter;
import 'package:meshsonar/ui/map/layers/map_layer.dart';
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/map/layers/repeater_map_source.dart';
import 'package:meshsonar/ui/map/sheets/observer_sheet.dart';

import '../fakes.dart';

const cmh = RegionIndexEntry(
  code: 'CMH',
  slug: 'cmh',
  name: 'Columbus, US',
  url: 'https://cmh.meshsonar.com',
  bbox: [-83.5, 39.75, -82.45, 40.65],
);
final t0 = DateTime.utc(2026, 10, 16, 18);

Harness syncedHarness({int rosterSize = 400}) {
  final c = MockClient((req) async {
    if (req.url.path.endsWith('/region-repeaters')) {
      return http.Response(
        jsonEncode({
          'status': {'state': 'ready', 'reason': null, 'computedAt': null},
          'rows': [
            for (var i = 0; i < rosterSize; i++)
              {
                'key': i.toRadixString(16).padLeft(64, '0'),
                'hashPrefix': i.toRadixString(16).padLeft(2, '0'),
                'name': 'R$i',
                'role': i.isEven ? 'repeater' : 'room',
                'lat': 40 + i * 0.001,
                'lon': -83.0,
                'status': 'active',
              },
          ],
          'counts': {'active': rosterSize},
        }),
        200,
      );
    }
    return http.Response('{}', 404);
  });
  final h = Harness();
  h.repeaterSync = RepeaterSync(rosterClient: () => c, networkClient: () => c, clock: () => t0, parseInIsolate: false);
  h.client.regionsIndexResult = const [cmh];
  return h;
}

void main() {
  group('AppStateRepeaterFeed', () {
    test(
      'roster detail by key from a map (any case); region = the viewed one; 404 network list = unsupported',
      () async {
        final h = syncedHarness();
        await h.state.init();
        await h.state.launchSettled.timeout(const Duration(seconds: 20));
        final f = AppStateRepeaterFeed(h.state);
        expect(f.region.rows, hasLength(400));
        expect(f.rosterRegion?.slug, 'cmh');
        expect(f.rosterRegion?.baseUrl, 'https://cmh.meshsonar.com');
        final key = 399.toRadixString(16).padLeft(64, '0');
        expect(f.rosterDetail(key)?.name, 'R399');
        expect(f.rosterDetail(key.toUpperCase())?.name, 'R399');
        expect(f.rosterDetail('ff' * 32), isNull);
        expect(f.global.state, MapFeedState.unsupported);
        f.dispose();
      },
    );

    test(
      'passes on only real changes: an unrelated AppState notification keeps row identity and is not forwarded',
      () async {
        final h = syncedHarness(rosterSize: 3);
        await h.state.init();
        await h.state.launchSettled.timeout(const Duration(seconds: 20));
        final f = AppStateRepeaterFeed(h.state);
        var n = 0;
        f.addListener(() => n++);
        final rows = f.region.rows;
        h.state.notifyListeners(); // e.g. a ping, a GPS fix
        expect(n, 0);
        expect(identical(f.region.rows, rows), isTrue);
        f.dispose();
      },
    );

    test(
      'with no sync and nothing fetched by the host: global unsupported, roster idle (host fallback drives it)',
      () async {
        final h = Harness();
        await h.state.init();
        final f = AppStateRepeaterFeed(
          h.state,
          fallbackRoster: () => const FallbackRoster(
            region: RosterRegion(slug: 'cmh', name: 'CMH', baseUrl: 'https://cmh.meshsonar.com'),
            rows: [],
            state: MapFeedState.failed,
          ),
        );
        expect(f.global.state, MapFeedState.unsupported);
        expect(f.region.state, MapFeedState.failed);
        expect(f.rosterRegion?.slug, 'cmh');
        f.dispose();
      },
    );
  });

  group('advert-age bands', () {
    testWidgets('recomputed when the same rows are confirmed later (304) and by refreshAges when they got old', (
      t,
    ) async {
      var now = t0;
      final rows = [MapRepeaterRow(key: 'a' * 64, lat: 40, lon: -83, lastSeen: t0.subtract(const Duration(hours: 20)))];
      final feed = StaticRepeaterMapFeed(
        global: MapRepeaterSet(rows: rows, state: MapFeedState.ready, fetchedAt: t0),
      );
      final src = RepeaterMapSource(feed, clock: () => now);
      await t.pump();
      await src.settled;
      expect(src.globalPoints.band.single, 0, reason: '20 h: the 24 h band');

      // Five hours later the server confirms the same list (304): same rows identity, newer fetchedAt.
      now = t0.add(const Duration(hours: 5));
      feed.global = MapRepeaterSet(rows: rows, state: MapFeedState.ready, fetchedAt: now);
      await t.pump();
      await src.settled;
      expect(src.globalPoints.band.single, 1, reason: '25 h: the 7 d band');

      // Nobody refreshes for 7 more days; switching the layer on asks for fresh bands.
      now = now.add(const Duration(days: 7));
      src.refreshAges(maxAge: const Duration(minutes: 10));
      await t.pump();
      await src.settled;
      expect(src.globalPoints.band.single, 2, reason: '8 days: the 30 d band');
      // Recent bands are not rebuilt again.
      final idx = src.globalIndex;
      src.refreshAges(maxAge: const Duration(minutes: 10));
      await t.pump();
      expect(identical(src.globalIndex, idx), isTrue);
      src.dispose();
    });
  });

  group('observer sheet', () {
    const o = RegionObserver(
      key: 'abcdef0123',
      name: 'Hilltop',
      online: false,
      lat: 40.0,
      lon: -83.0,
      batteryMv: 4012,
      packetsPerHour: 1234,
      nodesHeard24h: 56,
      model: 'Heltec V3',
      firmware: 'v1.9',
    );
    Widget host(Units u) => MaterialApp(
      home: Scaffold(
        body: ObserverSheet(
          observer: o,
          regionName: 'Columbus, US',
          ctx: ObserverSheetContext(position: const LatLng(40.01, -83.0), units: u, clock: () => t0),
        ),
      ),
    );

    testWidgets('metric: distance in km, raw battery mV, offline', (t) async {
      await t.pumpWidget(host(Units.metric));
      expect(find.text('1.1 km'), findsOneWidget);
      expect(find.text('4012 mV'), findsOneWidget);
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('Heltec V3 · v1.9'), findsOneWidget);
      expect(find.textContaining('rounded to about 1.0 km'), findsOneWidget);
    });

    testWidgets('imperial: distance in miles', (t) async {
      await t.pumpWidget(host(Units.imperial));
      expect(find.text('0.7 mi'), findsOneWidget);
      expect(find.textContaining('rounded to about 0.6 mi'), findsOneWidget);
    });
  });

  // 15k = the design estimate; 55k = the live list on Oct 24 2026 (55,601 rows).
  for (final n in [15000, 55000]) {
    group('$n-point global set', () {
      testWidgets('builds off the UI isolate and renders on CoverageMap (world and street zoom) without timing out', (
        t,
      ) async {
        final rnd = math.Random(42);
        final rows = <MapRepeaterRow>[
          for (var i = 0; i < n; i++)
            MapRepeaterRow(
              key: (i + 1).toRadixString(16).padLeft(64, '0'),
              name: i.isEven ? 'Repeater $i' : null,
              // 80% continental US, 20% worldwide, like the real network.
              lat: i % 5 == 0 ? -55 + rnd.nextDouble() * 120 : 25 + rnd.nextDouble() * 24,
              lon: i % 5 == 0 ? -180 + rnd.nextDouble() * 360 : -124 + rnd.nextDouble() * 57,
              isRoom: i % 7 == 0,
              lastSeen: t0.subtract(Duration(hours: rnd.nextInt(24 * 60))),
            ),
        ];
        final feed = StaticRepeaterMapFeed(
          global: MapRepeaterSet(
            rows: rows,
            state: MapFeedState.ready,
            fetchedAt: t0,
            attribution: 'Data: MeshCore Map (map.meshcore.io)',
          ),
        );
        final points = Stopwatch()..start();
        RepeaterPoints.fromRows(rows, now: t0);
        points.stop();
        final build = Stopwatch()..start();
        late RepeaterMapSource src;
        await t.runAsync(() async {
          src = RepeaterMapSource(feed, clock: () => t0); // default threshold: clustered in Isolate.run
          await src.settled;
        });
        build.stop();
        expect(src.globalIndex!.indexedCount, n);
        expect(src.statusOf(kNetworkLayerId).availability, LayerAvailability.ready);

        final state = kDefaultLayerState.toggle(kNetworkLayerId, true);
        Widget host() => MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 860,
              child: CoverageMap(
                pings: const [],
                showTiles: false,
                follow: false,
                fallbackCenter: const LatLng(39.5, -98.35),
                repeaterSource: src,
                layerState: state,
              ),
            ),
          ),
        );
        final render = Stopwatch()..start();
        await t.pumpWidget(host());
        await t.pump();
        render.stop();
        expect(find.byKey(const ValueKey('layer-network-paint')), findsOneWidget);
        ClusteredPointsPainter painter() =>
            t.widget<CustomPaint>(find.byKey(const ValueKey('layer-network-paint'))).painter! as ClusteredPointsPainter;
        final wide = painter().slice.length;
        expect(
          wide,
          inInclusiveRange(1, 400),
          reason: 'a continent at z 8 is a bounded number of clusters, not $n items',
        );

        // Pan/zoom frames: move the camera through world -> street zoom and repaint each time.
        final pan = Stopwatch()..start();
        final cam = MapCamera.of(t.element(find.byKey(const ValueKey('layer-network-paint'))));
        expect(cam.zoom, closeTo(8, 0.01));
        var frames = 0;
        for (final (lat, lon, z) in [
          (39.5, -98.35, 3.0),
          (39.5, -98.35, 5.0),
          (40.0, -83.0, 9.0),
          (40.0, -83.0, 12.0),
          (34.05, -118.24, 14.0),
          (34.05, -118.24, 16.0),
        ]) {
          MapController.maybeOf(t.element(find.byKey(const ValueKey('layer-network-paint'))))!
              .move(LatLng(lat, lon), z);
          await t.pump();
          frames++;
          expect(painter().camera.zoom, closeTo(z, 0.01));
        }
        pan.stop();
        // ignore: avoid_print
        print(
          '$n-point global set (Mac host VM, flutter test JIT; not a phone): RepeaterPoints.fromRows alone ${points.elapsedMilliseconds} ms '
          '(reference only: the source runs it in the isolate), rows -> points + cluster index via Isolate.run ${build.elapsedMilliseconds} ms, first CoverageMap pump ${render.elapsedMilliseconds} ms, '
          '$frames camera moves z3..z16 ${pan.elapsedMilliseconds} ms total, $wide items drawn at z8.',
        );
        src.dispose();
      });
    });
  }
}
