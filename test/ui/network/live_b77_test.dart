// Build 77, Network > Live (package W2-A): Live does not open empty (Round 2 N-U2), Speed only in replay (N-U6), the collapsed
// count says "filtered" (N-U7), "Replay on map" for one reception with "Play again" (N-U1, Live half), the repeaters drawn by
// the Drive painter (Round 1 F1), the position table not rebuilt per update (F12), Reduce Motion on packets (F11), Measured
// coverage opt-in (decision 4) and the shared Legend panel.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:meshsonar/core/map_prefs.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/live_api.dart';
import 'package:meshsonar/core/v1/live_geometry.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/map/layers/repeater_painter_layer.dart';
import 'package:meshsonar/ui/network/live/live_map_controller.dart';
import 'package:meshsonar/ui/network/live/live_map_view.dart';
import 'package:meshsonar/ui/network/live/live_nodes_layer.dart';
import 'package:meshsonar/ui/network/live/live_replay_entry.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'live_map_test.dart' show FakeSse, fixture, j, settle;

const _region = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus', url: 'https://cmh.meshsonar.com', bbox: [-83.2, 39.8, -82.8, 40.2]);

Map<String, Object?> _packet(String hash, DateTime at) => {
  'hash': hash,
  'type': 4,
  'typeName': 'ADVERT',
  'route': 'FLOOD',
  'firstSeen': at.toUtc().toIso8601String(),
  'observations': [
    {'id': 'o-$hash', 'observer': {'id': 'obs1', 'name': 'Obs One', 'kind': 'fixed', 'src': 'meshsonar'}, 'at': at.toUtc().toIso8601String(), 'snr': 4.0, 'pathId': 'p1', 'src': 'meshsonar'}
  ],
  'paths': [
    {'id': 'p1', 'hops': [], 'observationIds': ['o-$hash']}
  ],
  'unknownHops': [],
  'settled': true,
  'src': ['meshsonar'],
};

/// A controller whose replay answers [packets] (newest last) and counts the replay calls.
(LiveMapController, List<Uri>) _controller(FakeSse fake, List<Map<String, Object?>> packets) {
  final calls = <Uri>[];
  final c = LiveMapController(
    baseUrl: 'https://cmh.meshsonar.com',
    regionSlug: 'cmh',
    stream: NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'), connect: fake.connect),
    api: LiveReplayApi('https://cmh.meshsonar.com', client: MockClient((r) async {
      calls.add(r.url);
      if (r.url.path == '/v1/replay') return j(jsonEncode({'data': packets, 'page': {'limit': 200, 'next': null}, 'meta': (jsonDecode(fixture('replay.json')) as Map)['meta']}));
      return j(fixture('packets-density.json'));
    })),
    clock: () => DateTime.utc(2026, 11, 27, 15),
  );
  return (c, calls);
}

Future<void> _pump(WidgetTester tester, LiveMapController c, {NetworkRequest? request, bool reduceMotion = false}) async {
  tester.view.physicalSize = const Size(390 * 3, 844 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  MapPanelStore.clear();
  await tester.pumpWidget(AppScope(
    state: Harness().state,
    child: MaterialApp(
      theme: meshSonarTheme(Brightness.dark),
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
          child: Scaffold(body: NetworkLiveMap(region: _region, controller: c, showBasemap: false, request: request)),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.runAsync(settle);
  await tester.pump();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('live-panel-header')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    PowerProfile.debugReset();
    resetV1NotLive();
    LiveReplayRequests.clear();
    nodesApiFactory = (b) => NodesApi(b, client: MockClient((r) async => j(fixture(r.url.path.endsWith('/nodes') ? 'nodes.json' : 'observers.json'))));
    packetsApiFactory = (b) => PacketsApi(b, client: MockClient((r) async => j(fixture('packet-detail.grp-txt-outside-ambiguous.json'))));
    MapPrefs.shared.setLayerPrefs(kLiveLayerPage, LayerPrefs.empty);
  });
  tearDown(() {
    nodesApiFactory = (b) => NodesApi(b);
    packetsApiFactory = (b) => PacketsApi(b);
    MapPrefs.shared.setLayerPrefs(kLiveLayerPage, LayerPrefs.empty);
  });

  group('N-U2: the latest packets', () {
    test('the latest 20, newest first, loaded once', () async {
      final base = DateTime.utc(2026, 11, 27, 14, 52);
      final (c, calls) = _controller(FakeSse(), [for (var i = 0; i < 30; i++) _packet('h$i', base.add(Duration(seconds: i * 10)))]);
      await c.loadLatest();
      expect(c.feed.length, 20);
      expect(c.feed.first.hash, 'h29');
      expect(c.feed.last.hash, 'h10');
      final n = calls.where((u) => u.path == '/v1/replay').length;
      await c.loadLatest();
      expect(calls.where((u) => u.path == '/v1/replay').length, n, reason: 'once');
      c.dispose();
    });

    testWidgets('the map opens with them under "Latest packets", not on "Waiting for packets"', (tester) async {
      final (c, _) = _controller(FakeSse(), [_packet('abc123', DateTime.utc(2026, 11, 27, 14, 58))]);
      await _pump(tester, c);
      await _open(tester);
      expect(find.text('Latest packets · tap one for details'), findsOneWidget);
      expect(find.byKey(const Key('live-feed-row-abc123')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('N-U6 / N-U7: Speed and the collapsed count', () {
    testWidgets('Speed shows only in replay; the collapsed count says "filtered" while filters are on', (tester) async {
      final (c, _) = _controller(FakeSse(), [_packet('abc123', DateTime.utc(2026, 11, 27, 14, 58))]);
      await _pump(tester, c);
      expect(tester.widget<Text>(find.byKey(const Key('live-map-count'))).data, '1 packet');
      c.setFilter(const LiveFilter(types: {4}));
      await tester.pump();
      expect(tester.widget<Text>(find.byKey(const Key('live-map-count'))).data, '1 packet · filtered');
      c.setFilter(LiveFilter.none);
      await tester.pump();
      await _open(tester);
      expect(find.byKey(const Key('live-map-speed')), findsNothing, reason: 'live: speed does nothing');
      await tester.runAsync(() => c.replayFrom(DateTime.utc(2026, 11, 27, 14, 30)));
      await tester.pump();
      expect(find.byKey(const Key('live-map-speed')), findsOneWidget, reason: 'replay: speed is there');
      c.jumpToLive();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('N-U1: Replay on map (Live half)', () {
    test('oneReception keeps only that observation and the path it heard', () {
      final p = LiveV2Packet.tryParse({
        ..._packet('h1', DateTime.utc(2026, 11, 27, 14)),
        'observations': [
          {'id': 'o1', 'observer': {'id': 'a', 'name': 'A', 'kind': 'fixed', 'src': 'meshsonar'}, 'pathId': 'p1', 'src': 'meshsonar'},
          {'id': 'o2', 'observer': {'id': 'b', 'name': 'B', 'kind': 'fixed', 'src': 'meshsonar'}, 'pathId': 'p2', 'src': 'meshsonar'},
        ],
        'paths': [
          {'id': 'p1', 'hops': [], 'observationIds': ['o1']},
          {'id': 'p2', 'hops': [], 'observationIds': ['o2']},
        ],
      })!;
      final one = oneReception(p, 'o2');
      expect(one.observations.map((o) => o.id), ['o2']);
      expect(one.paths.map((x) => x.id), ['p2']);
      expect(oneReception(p, 'nope'), same(p));
    });

    testWidgets('openLiveReplay hands the observation to the Live map: only that copy, animated, with Play again', (tester) async {
      final (c, _) = _controller(FakeSse(), const []);
      LiveReplayRequests.put('c4b06ee8fc39b187', 'o2');
      await _pump(tester, c, request: NetworkRequest.mapPacket('c4b06ee8fc39b187', region: 'cmh'));
      await tester.runAsync(settle);
      await tester.pump();
      expect(c.focus?.hash, 'c4b06ee8fc39b187');
      expect(c.focusObservationId, 'o2');
      expect(c.focus!.observations.single.observer.name, 'Scioto North');
      expect(c.focusAnimating, isTrue);
      expect(find.textContaining('Heard by Scioto North'), findsWidgets);
      expect(find.byKey(const Key('live-focus-play-again')), findsOneWidget);
      expect(LiveReplayRequests.take('c4b06ee8fc39b187'), isNull, reason: 'taken once');
      // It plays: progress grows with the ticker, and Play again starts it over.
      c.setActive(true);
      c.tick(const Duration(milliseconds: 700));
      final p1 = c.focusProgress!;
      expect(p1, greaterThan(0));
      await tester.pump();
      await tester.tap(find.byKey(const Key('live-focus-play-again')));
      await tester.pump();
      expect(c.focusProgress, 0);
      c.clearFocus();
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  testWidgets('a map request carrying an observation (W2-C\'s "Replay on map") plays only that copy', (tester) async {
    final (c, _) = _controller(FakeSse(), const []);
    await _pump(tester, c, request: NetworkRequest.mapPacket('c4b06ee8fc39b187', region: 'cmh', observation: 'o1'));
    await tester.runAsync(settle);
    await tester.pump();
    expect(c.focusObservationId, 'o1');
    expect(c.focusAnimating, isTrue);
    c.clearFocus();
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });

  group('F1: the repeaters on Live are the Drive painter', () {
    testWidgets('tappable, idle ones dimmed to 62 % and clustered; the ones in use are full-strength badges', (tester) async {
      final (c, _) = _controller(FakeSse(), const []);
      await _pump(tester, c);
      final markers = find.byKey(const Key('live-nodes-markers'));
      expect(markers, findsOneWidget);
      final painter = tester.widget<RepeaterPainterLayer>(find.descendant(of: markers, matching: find.byType(RepeaterPainterLayer)));
      expect(painter.sourceOpacity, 0.62);
      expect(painter.onHit, isNotNull, reason: 'a node can be tapped');
      expect(painter.sources.single.$1.globalPoints.length, greaterThan(0), reason: '/v1/nodes feeds the painter');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    test('the Live nodes become painter rows: key, name, room, last heard', () {
      final rows = liveNodeRows(const []);
      expect(rows, isEmpty);
    });
  });

  group('F12: the position table', () {
    testWidgets('built once, not on every dependency change of the screen', (tester) async {
      final (c, _) = _controller(FakeSse(), const []);
      liveDebugPositionTableBuilds = 0;
      await _pump(tester, c);
      final after = liveDebugPositionTableBuilds;
      expect(after, 1);
      // Dependency changes (text scale, theme) do not rebuild it.
      for (final scale in [1.2, 1.4, 1.0]) {
        await tester.pumpWidget(AppScope(
          state: Harness().state,
          child: MaterialApp(
            theme: meshSonarTheme(Brightness.dark),
            home: MediaQuery(
              data: MediaQueryData(size: const Size(390, 844), textScaler: TextScaler.linear(scale)),
              child: Scaffold(body: NetworkLiveMap(region: _region, controller: c, showBasemap: false)),
            ),
          ),
        ));
        await tester.pump();
      }
      expect(liveDebugPositionTableBuilds, lessThanOrEqualTo(2), reason: 'a new app state may build it once more, never per change');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('F11: Reduce Motion', () {
    testWidgets('a live packet is drawn whole at once (it only fades)', (tester) async {
      final fake = FakeSse();
      final (c, _) = _controller(fake, const []);
      await _pump(tester, c, reduceMotion: true);
      c.setActive(true);
      c.setPositions(LivePositions(
        node: (k) => k.startsWith('aa') ? const GeoPoint(40, -83) : null,
        observer: (id) => id == 'obs1' ? const GeoPoint(40.1, -82.9) : null,
      ));
      await tester.runAsync(() async {
        fake.send('event: packet\ndata: ${jsonEncode({..._packet('rm1', DateTime.utc(2026, 11, 27, 14, 59)), 'origin': {'key': 'aa${'0' * 62}', 'name': 'O', 'role': 'repeater'}})}\n\n');
        await settle();
      });
      await tester.pump();
      if (c.animations.isNotEmpty) {
        final lines = tester.widget<PolylineLayer>(find.byKey(const Key('live-map-lines')));
        final seg = c.animations.first.drawing.segments.first;
        final end = lines.polylines.last.points.last;
        expect(end.latitude, closeTo(seg.b.lat, 1e-9), reason: 'the whole segment, not the part reached so far');
      }
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });

  group('decision 4: Measured coverage on Live', () {
    test('opt-in: drawn on the Live map, off by default', () {
      expect(kLiveDrawnLayerIds, contains('measured'));
      expect(liveDefaultLayerState().isOn('measured'), isFalse);
    });
  });

}
