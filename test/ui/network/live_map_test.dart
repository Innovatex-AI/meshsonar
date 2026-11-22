// AZ-3.3: Network > Map, the live map with replay. Controller rules (live, pause, replay, filters, catch-up, battery)
// and the widget (status, controls, feed sheet, filters, Saver banner, the packet focus from "Show on map").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/design/map_panel.dart';
import 'package:meshsonar/ui/map/coverage_map.dart' show CoverageMap;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/network_request.dart';
import 'package:meshsonar/core/power_profile.dart';
import 'package:meshsonar/core/region_lookup.dart';
import 'package:meshsonar/core/v1/favourites_store.dart';
import 'package:meshsonar/core/v1/live_api.dart';
import 'package:meshsonar/core/v1/live_geometry.dart';
import 'package:meshsonar/core/v1/nodes_api.dart';
import 'package:meshsonar/core/v1/packets_api.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/network/live/live_map_controller.dart';
import 'package:meshsonar/ui/network/live/live_map_view.dart';
import 'package:meshsonar/ui/network/live/packet_type_colors.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;

String fixture(String name) => File('test/fixtures/analyzer/$name').readAsStringSync();

class FakeSse {
  final List<http.Request> requests = [];
  final List<StreamController<List<int>>> conns = [];
  Future<http.StreamedResponse> connect(http.Request r) async {
    requests.add(r);
    final c = StreamController<List<int>>();
    conns.add(c);
    return http.StreamedResponse(c.stream, 200, headers: {'content-type': 'text/event-stream'}, request: r);
  }

  void send(String text) => conns.last.add(utf8.encode(text));
}

http.Response j(String body, [int code = 200]) => http.Response(body, code, headers: {'content-type': 'application/json'});

String packetEvent(String hash, {int type = 4, String at = '2026-11-20T14:00:00.000Z', String? origin}) => 'event: packet\ndata: ${jsonEncode({
      'hash': hash,
      'type': type,
      'typeName': packetTypeWireNames[type] ?? 'UNKNOWN',
      'route': 'FLOOD',
      'firstSeen': at,
      'origin': origin == null ? null : {'key': origin, 'name': 'Origin', 'role': 'repeater'},
      'observations': [
        {'id': 'o1', 'observer': {'id': 'obs1', 'name': 'Obs One', 'kind': 'fixed', 'src': 'meshsonar'}, 'at': at, 'snr': 4.0, 'pathId': 'p1', 'src': 'meshsonar'}
      ],
      'paths': [
        {
          'id': 'p1',
          'hops': [
            {'index': 0, 'prefix': 'aa', 'confidence': 'unique', 'node': {'key': 'aa${'0' * 62}', 'name': 'A', 'role': 'repeater'}, 'score': 1, 'candidates': [], 'candidatesTotal': 1, 'evidence': []}
          ],
          'observationIds': ['o1']
        }
      ],
      'unknownHops': [],
      'settled': true,
      'src': ['meshsonar'],
    })}\n\n';

LiveMapController makeController(FakeSse fake, {http.Client? client, DateTime Function()? clock}) {
  final c = LiveMapController(
    baseUrl: 'https://cmh.meshsonar.com',
    regionSlug: 'cmh',
    stream: NetworkLiveStream('https://cmh.meshsonar.com', const LiveSubscription(region: 'cmh'), connect: fake.connect),
    api: LiveReplayApi('https://cmh.meshsonar.com', client: client ?? MockClient((r) async => j(fixture('packets-density.json')))),
    clock: clock,
  );
  c.setPositions(LivePositions(
    node: (k) => k.startsWith('aa') ? const GeoPoint(40, -83) : (k.startsWith('or') ? const GeoPoint(39.5, -83.2) : null),
    observer: (id) => id == 'obs1' ? const GeoPoint(40.1, -82.9) : null,
  ));
  return c;
}

/// The Live map reads the app (Layers, basemap, the roster): host it under an AppScope like the app does.
Widget scoped(Widget app) => AppScope(state: Harness().state, child: app);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  setUp(() {
    PowerProfile.debugReset();
    resetV1NotLive();
  });

  group('LiveMapController', () {
    test('a live packet is listed and drawn; paused counts it instead', () async {
      final fake = FakeSse();
      final c = makeController(fake);
      c.setActive(true);
      await settle();
      fake.send(packetEvent('1111000011112222'));
      await settle();
      expect(c.feed.single.hash, '1111000011112222');
      expect(c.animations, hasLength(1));
      expect(c.animations.single.drawing.segments.single.style, SegmentStyle.solid);
      c.pause();
      fake.send(packetEvent('2222000011112222', at: '2026-11-20T14:00:05.000Z'));
      await settle();
      expect(c.missedWhilePaused, 1);
      expect(c.feed.first.hash, '2222000011112222');
      c.play();
      expect(c.mode, LiveMode.live);
      expect(c.missedWhilePaused, 0);
      c.dispose();
    });

    test('animation runs about 660 ms per hop then fades, and stops while inactive', () async {
      final fake = FakeSse();
      final c = makeController(fake);
      c.setActive(true);
      await settle();
      fake.send(packetEvent('1111000011112222'));
      await settle();
      final a = c.animations.single;
      expect(a.drawing.steps, 1);
      c.tick(const Duration(milliseconds: 330));
      expect(c.progressOf(a).$1, closeTo(0.5, 0.01));
      c.setActive(false);
      expect(fake.requests, hasLength(1));
      c.tick(const Duration(seconds: 10)); // inactive: nothing moves
      expect(c.animations, hasLength(1));
      c.setActive(true);
      c.tick(Duration(milliseconds: LiveMapController.durationMs(a)));
      expect(c.animations, isEmpty);
      c.dispose();
    });

    test('filters: type, observer and My nodes', () async {
      final fake = FakeSse();
      final c = makeController(fake);
      c.setActive(true);
      await settle();
      fake.send(packetEvent('1111000011112222', type: 4));
      fake.send(packetEvent('3333000011112222', type: 5, at: '2026-11-20T14:00:01.000Z'));
      await settle();
      expect(c.feed, hasLength(2));
      c.setFilter(const LiveFilter(types: {5}));
      expect(c.feed.single.hash, '3333000011112222');
      c.setFilter(const LiveFilter(observerId: 'nobody'));
      expect(c.feed, isEmpty);
      c.setFilter(const LiveFilter(myNodesOnly: true));
      expect(c.feed, isEmpty, reason: 'no starred or claimed nodes');
      c.setMyNodes(const MyNodes(keys: {'aa00000000000000000000000000000000000000000000000000000000000000'}));
      expect(c.feed, hasLength(2), reason: 'both went through my node A');
      c.setMyNodes(const MyNodes(keys: {'ab00000000000000000000000000000000000000000000000000000000000000'}));
      expect(c.feed, isEmpty);
      c.setMyNodes(const MyNodes(observerIds: {'obs1'}));
      expect(c.feed, hasLength(2));
      c.dispose();
    });

    test('replay: plays the page at speed, then jump to live', () async {
      final fake = FakeSse();
      final calls = <Uri>[];
      final c = makeController(fake,
          clock: () => DateTime.utc(2026, 11, 20, 14, 15),
          client: MockClient((r) async {
            calls.add(r.url);
            if (r.url.path == '/v1/replay') return j(fixture('replay.json'));
            return j(fixture('packets-density.json'));
          }));
      c.setActive(true);
      await settle();
      c.setSpeed(4);
      await c.replayFrom(DateTime.utc(2026, 11, 20, 14));
      expect(c.mode, LiveMode.replay);
      expect(c.replayClock!.pending, greaterThan(0));
      expect(calls.any((u) => u.path == '/v1/replay' && u.queryParameters['from'] == '2026-11-20T14:00:00.000Z'), isTrue);
      for (var i = 0; i < 40; i++) {
        c.tick(const Duration(milliseconds: 100));
      }
      expect(c.feed.map((p) => p.hash), contains('1add53ffce368256'));
      expect(c.replayClock!.playhead.isAfter(DateTime.utc(2026, 11, 20, 14)), isTrue);
      c.jumpToLive();
      expect(c.mode, LiveMode.live);
      expect(c.replayClock, isNull);
      expect(c.speed, 1);
      c.dispose();
    });

    test('missed: the gap is read back from the refetch path and listed', () async {
      final fake = FakeSse();
      final c = makeController(fake, client: MockClient((r) async {
        if (r.url.path == '/v1/replay') return j(fixture('replay.json'));
        return j(fixture('packets-density.json'));
      }));
      c.setActive(true);
      await settle();
      fake.send('id: 1-0\nevent: missed\ndata: {"count":2,"refetch":"/v1/replay?from=2026-11-20T14:00:00.000Z&region=cmh"}\n\n');
      await settle();
      await settle();
      expect(c.note, contains('Caught up'));
      expect(c.feed.map((p) => p.hash), contains('c4b06ee8fc39b187'));
      c.dispose();
    });

    test('density: from the server, else counted on the phone', () async {
      final fake = FakeSse();
      final c = makeController(fake);
      await c.loadDensity();
      expect(c.density!.estimated, isFalse);
      expect(c.density!.max, 52);
      resetV1NotLive();
      final c2 = makeController(FakeSse(),
          clock: () => DateTime.utc(2026, 11, 20, 15),
          client: MockClient((r) async => r.url.path == '/api/cmh/region-replay'
              ? j(jsonEncode({
                  'packets': [
                    {'hash': 'aaaa000011112222', 'type': 4, 'route': 1, 'at': '2026-11-20T14:30:00.000Z', 'observations': [], 'hops': []}
                  ],
                  'nextFrom': null
                }))
              : http.Response('<html>', 404)));
      await c2.loadDensity();
      expect(c2.density!.estimated, isTrue);
      expect(c2.density!.counts.fold<int>(0, (a, b) => a + b.$2), 1);
      c.dispose();
      c2.dispose();
      resetV1NotLive();
    });
  });

  group('NetworkRequest for the live map', () {
    test('the packet replay link opens Map with the packet and time, and round-trips', () {
      final r = NetworkRequest.parse(Uri.parse('https://cmh.meshsonar.com/map?panel=live&t=2026-11-20T14:02:05.120Z&packet=c4b06ee8fc39b187'))!;
      expect(r.section, NetworkSection.live);
      expect(r.region, 'cmh');
      expect(r.packetHash, 'c4b06ee8fc39b187');
      expect(r.mapTime, DateTime.utc(2026, 11, 20, 14, 2, 5, 120));
      expect(NetworkRequest.parse(r.toWebUri()), r);
      final m = NetworkRequest.mapPacket('C4B06EE8FC39B187', region: 'cmh', at: DateTime.utc(2026, 11, 20, 14));
      expect(m.toWebUri().queryParameters, {'panel': 'live', 't': '2026-11-20T14:00:00.000Z', 'packet': 'c4b06ee8fc39b187'});
      expect(NetworkRequest.parse(m.toAppUri()), m);
    });
  });

  test('packet type palette matches the website', () {
    expect(packetTypeColorFor(4, Brightness.dark), const Color(0xFF3987E5));
    expect(packetTypeColorFor(5, Brightness.dark), const Color(0xFFD95926));
    expect(packetTypeColorFor(9, Brightness.light), const Color(0xFF008300));
    expect(packetTypeColorFor(11, Brightness.dark), const Color(0xFF8A929B));
  });

  group('NetworkLiveMap widget', () {
    const region = RegionIndexEntry(code: 'CMH', slug: 'cmh', name: 'Columbus', url: 'https://cmh.meshsonar.com', bbox: [-83.2, 39.8, -82.8, 40.2]);

    setUp(() {
      nodesApiFactory = (b) => NodesApi(b, client: MockClient((r) async => j(fixture('observers.json'))));
      packetsApiFactory = (b) => PacketsApi(b, client: MockClient((r) async => j(fixture('packet-detail.grp-txt-outside-ambiguous.json'))));
    });
    tearDown(() {
      nodesApiFactory = (b) => NodesApi(b);
      packetsApiFactory = (b) => PacketsApi(b);
    });

    Future<LiveMapController> pump(WidgetTester tester, FakeSse fake, {NetworkRequest? request, bool open = true, double width = 390}) async {
      // A phone: the Live panel starts collapsed there.
      tester.view.physicalSize = Size(width * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      MapPanelStore.clear();
      late LiveMapController c;
      await tester.runAsync(() async {
        c = makeController(fake);
      });
      await tester.pumpWidget(AppScope(
        state: Harness().state,
        child: MaterialApp(
          theme: meshSonarTheme(Brightness.dark),
          home: Scaffold(body: NetworkLiveMap(region: region, controller: c, showBasemap: false, request: request)),
        ),
      ));
      await tester.pump();
      if (open) {
        await tester.tap(find.byKey(const Key('live-panel-header')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
      }
      return c;
    }

    testWidgets('collapsed on a phone: one 56 pt header is the whole chrome (status, count, pause), nothing at the top', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake, open: false);
      await tester.runAsync(() async {
        await settle();
        fake.send('event: status\ndata: {"observersOnline":26}\n\n');
        fake.send(packetEvent('1111000011112222'));
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      final panel = tester.getRect(find.byKey(const Key('map-panel-live.main')));
      expect(panel.height, kMapPanelHeader);
      expect(panel.bottom, 844);
      expect(find.text('Live · 26 observers online'), findsOneWidget);
      expect(find.text('1 packet'), findsOneWidget);
      expect(find.byKey(const Key('live-map-pause')), findsOneWidget);
      expect(find.byKey(const Key('live-panel-body')), findsNothing);
      // Nothing but the map above the header: the map's own buttons (Layers, the legend chip, the credit) belong to the map and
      // are not the Live panel's chrome (build 75: the Live map is a CoverageMap with a Layers button).
      final chrome = find.descendant(of: find.byKey(const Key('live-map')), matching: find.byType(Material));
      for (final e in chrome.evaluate()) {
        if (find.descendant(of: find.byType(CoverageMap), matching: find.byWidget(e.widget)).evaluate().isNotEmpty) continue;
        final r = tester.getRect(find.byWidget(e.widget));
        expect(r.top, greaterThanOrEqualTo(panel.top - 0.5), reason: 'no bar or card above the panel header');
      }
      // Pause works from the collapsed header and does not open the panel; new packets do not open it either.
      await tester.tap(find.byKey(const Key('live-map-pause')));
      await tester.pump();
      expect(find.byKey(const Key('live-map-play')), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      expect(find.byKey(const Key('live-panel-body')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('live: status, the feed in the panel, pause and play', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake);
      await tester.runAsync(() async {
        await settle();
        fake.send('event: status\ndata: {"observersOnline":26}\n\n');
        fake.send(packetEvent('1111000011112222'));
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Live · 26 observers online'), findsWidgets);
      expect(find.text('1 packet'), findsOneWidget);
      expect(tester.getRect(find.byKey(const Key('map-panel-live.main'))).height, lessThanOrEqualTo(844 * 0.6 + 0.5));
      expect(find.byKey(const Key('live-feed-row-1111000011112222')), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-map-pause')));
      await tester.pump();
      expect(find.byKey(const Key('live-map-play')), findsOneWidget);
      expect(find.text('Paused'), findsOneWidget);
      // Draw on the map: the packet becomes the transient panel and the Live panel goes back to its header.
      await tester.tap(find.byKey(const Key('live-feed-draw-1111000011112222')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      expect(find.byKey(const Key('live-panel-body')), findsNothing, reason: 'one open panel per map');
      expect(MapPanelStore.read('live.main'), MapPanelState.open, reason: 'a transient panel never changes the remembered state');
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('Saver mode: the stream is not opened until "Show anyway"', (tester) async {
      PowerProfile.debugReset(PowerSettings.saver);
      final fake = FakeSse();
      final c = await pump(tester, fake);
      await tester.runAsync(settle);
      expect(find.byKey(const Key('live-saver-banner')), findsOneWidget);
      expect(fake.requests, isEmpty);
      await tester.tap(find.byKey(const Key('live-saver-override')));
      await tester.pump();
      await tester.runAsync(settle);
      expect(fake.requests, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('filters sheet and window chips', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake);
      await tester.tap(find.byKey(const Key('live-map-filters')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-filter-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-filter-type-4')));
      await tester.pump();
      expect(c.filter.types, {4});
      expect(find.byKey(const Key('live-window-6h')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('Show on map: the packet is drawn as the focus with a Replay here action', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake, request: NetworkRequest.mapPacket('c4b06ee8fc39b187', region: 'cmh'), open: false);
      await tester.runAsync(settle);
      await tester.pump();
      expect(c.focus?.hash, 'c4b06ee8fc39b187');
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      expect(find.textContaining('not placed'), findsOneWidget);
      final focus = tester.getRect(find.byKey(const Key('map-panel-live.focus')));
      expect(focus.bottom, tester.getRect(find.byKey(const Key('map-panel-live.main'))).top, reason: 'directly above the Live panel header');
      final drawn = c.focus!;
      await tester.tap(find.byKey(const Key('live-focus-close')));
      await tester.pump();
      expect(find.byKey(const Key('live-focus-card')), findsNothing);
      // A tap on empty map closes it too.
      c.showPacket(drawn);
      await tester.pump();
      expect(find.byKey(const Key('live-focus-card')), findsOneWidget);
      await tester.tapAt(const Offset(195, 120));
      await tester.pump(const Duration(milliseconds: 400));
      expect(c.focus, isNull);
      expect(find.byKey(const Key('live-focus-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    const reason = 'Partial: node list incomplete. 949 of 2,592 hop codes heard in the last 24 h match a known node (37%); weighted by packets, '
        '79% of hop appearances sit on a placed node (90% needed); routes are not drawn on the map and hop codes are marked unconfirmed.';

    testWidgets('the status is said once: the body repeats it in full only when the header had to cut it', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake);
      await tester.runAsync(() async {
        await settle();
        fake.send('event: status\ndata: {"observersOnline":26}\n\n');
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      // The test font is far wider than the app's: this wording does not fit the 390 pt header here, so it is cut there...
      final header = find.descendant(of: find.byKey(const Key('live-panel-header')), matching: find.text('Live · 26 observers online'));
      final para = tester.renderObject<RenderParagraph>(find.descendant(of: header, matching: find.byType(RichText)));
      expect(para.didExceedMaxLines, isTrue, reason: 'the header had to cut it');
      // ...and the body says it in full.
      expect(find.byKey(const Key('live-map-status')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('live-map-status'))).data, 'Live · 26 observers online');
      // A wording that fits is in the header only.
      await tester.tap(find.byKey(const Key('live-map-pause')));
      await tester.pump();
      final short = find.descendant(of: find.byKey(const Key('live-panel-header')), matching: find.text('Paused'));
      expect(tester.renderObject<RenderParagraph>(find.descendant(of: short, matching: find.byType(RichText))).didExceedMaxLines, isFalse);
      expect(find.text('Paused'), findsOneWidget, reason: 'not said twice');
      expect(find.byKey(const Key('live-map-status')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('a server note is one plain line with Details for the full sentence', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake);
      await tester.runAsync(() async {
        await settle();
        fake.send('event: status\ndata: ${jsonEncode({'observersOnline': 4, 'nodeList': {'trusted': false, 'reason': reason}})}\n\n');
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      expect(c.nodeListTrusted, isFalse);
      final line = find.text('Routes are hidden: not enough hops match known nodes yet.');
      expect(line, findsOneWidget);
      expect(tester.getSize(line).height, lessThan(40), reason: 'one or two lines, not a paragraph');
      expect(find.textContaining('949 of 2,592'), findsNothing, reason: 'the internals are behind Details');
      final details = find.byKey(const Key('live-note-details'));
      await tester.ensureVisible(details);
      await tester.pump();
      expect(tester.getSize(details).height, greaterThanOrEqualTo(44));
      await tester.tap(details);
      await tester.pump();
      expect(find.byKey(const Key('live-note-full')), findsOneWidget);
      expect(find.text(reason), findsOneWidget, reason: 'the server\'s sentence, word for word');
      await tester.tap(details);
      await tester.pump();
      expect(find.byKey(const Key('live-note-full')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('body order and reach: scrubber, window, controls, feed, then legend and notes; every feed row can be scrolled above the tab bar', (tester) async {
      tester.view.physicalSize = const Size(402 * 3, 874 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      MapPanelStore.clear();
      final fake = FakeSse();
      late LiveMapController c;
      await tester.runAsync(() async => c = makeController(fake));
      const bar = 83.0;
      await tester.pumpWidget(scoped(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(402, 874), padding: EdgeInsets.only(top: 59, bottom: bar)),
          child: Scaffold(
            body: Column(children: [
              const SizedBox(height: 59 + 48 + 44),
              Expanded(child: NetworkLiveMap(region: region, controller: c, showBasemap: false)),
            ]),
          ),
        ),
      )));
      await tester.pump();
      await tester.runAsync(() async {
        await settle();
        fake.send('event: status\ndata: ${jsonEncode({'observersOnline': 4, 'nodeList': {'trusted': false, 'reason': reason}})}\n\n');
        for (var i = 0; i < 12; i++) {
          fake.send(packetEvent('${1000 + i}000011112222', at: '2026-11-20T14:00:${i.toString().padLeft(2, '0')}.000Z'));
        }
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      double y(Finder f) => tester.getTopLeft(f).dy;
      final scrub = y(find.byKey(const Key('live-map-scrubber')));
      final chips = y(find.byKey(const Key('live-window-1h')));
      final controls = y(find.byKey(const Key('live-map-filters')));
      final heading = y(find.byKey(const Key('live-feed-heading')));
      expect(scrub < chips && chips < controls && controls < heading, isTrue, reason: 'scrubber, window, controls, feed');
      // The first feed row is on screen above the tab bar without scrolling (the feed is not pushed out by notes).
      final rows = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('live-feed-row-'));
      expect(rows, findsWidgets);
      expect(y(rows.first) + 44, lessThanOrEqualTo(874 - bar), reason: 'the first feed row shows above the tab bar (the test font is taller than the app\'s)');
      expect(y(rows.first), greaterThan(heading));
      expect(find.text('Routes are hidden: not enough hops match known nodes yet.').hitTestable(), findsNothing, reason: 'notes come after the feed');
      // The body scrolls: the last feed row, then the legend and the note, come up above the tab bar.
      final body = find.byKey(const Key('live-panel-body'));
      for (var i = 0; i < 12 && find.text('Routes are hidden: not enough hops match known nodes yet.').hitTestable().evaluate().isEmpty; i++) {
        await tester.drag(body, const Offset(0, -200));
        await tester.pump(const Duration(milliseconds: 300));
      }
      final note = find.text('Routes are hidden: not enough hops match known nodes yet.');
      expect(note.hitTestable(), findsOneWidget);
      expect(tester.getRect(note).bottom, lessThanOrEqualTo(874 - bar));
      expect(tester.getRect(rows.last).bottom, lessThan(y(note)), reason: 'feed first, then legend and notes');
      expect(tester.getRect(find.byKey(const Key('map-panel-live.main'))).bottom, 874);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('the selected window chip uses the app\'s selected colour (primaryContainer), not the secondary fill', (tester) async {
      final fake = FakeSse();
      final c = await pump(tester, fake);
      final chip = tester.widget<ChoiceChip>(find.byKey(Key('live-window-${c.window}')));
      expect(chip.selected, isTrue);
      expect(chip.selectedColor, meshSonarTheme(Brightness.dark).colorScheme.primaryContainer);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('375x667 under the Network header (48) and section strip (44): the Open panel leaves at least 150 pt of map', (tester) async {
      tester.view.physicalSize = const Size(375 * 2, 667 * 2);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      MapPanelStore.clear();
      final fake = FakeSse();
      late LiveMapController c;
      await tester.runAsync(() async => c = makeController(fake));
      await tester.pumpWidget(scoped(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: MediaQuery(
          // iPhone SE: 20 pt status bar; the tab bar zone (56) is the bottom padding the body runs behind.
          data: const MediaQueryData(size: Size(375, 667), padding: EdgeInsets.only(top: 20, bottom: 56)),
          child: Scaffold(
            body: Column(children: [
              const SizedBox(height: 20 + 48 + 44), // status bar, Network header, section strip
              Expanded(child: NetworkLiveMap(region: region, controller: c, showBasemap: false)),
            ]),
          ),
        ),
      )));
      await tester.pump();
      await tester.runAsync(() async {
        await settle();
        for (var i = 0; i < 30; i++) {
          fake.send(packetEvent('${(1000 + i)}000011112222', at: '2026-11-20T14:00:${(i % 60).toString().padLeft(2, '0')}.000Z'));
        }
        await settle();
      });
      await tester.pump(const Duration(milliseconds: 50));
      final map = tester.getRect(find.byKey(const Key('live-map')));
      expect(map.top, 112);
      // Collapsed: the map keeps everything but the header.
      var panel = tester.getRect(find.byKey(const Key('map-panel-live.main')));
      expect(panel.top - map.top, greaterThanOrEqualTo(400));
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      panel = tester.getRect(find.byKey(const Key('map-panel-live.main')));
      expect(find.byKey(const Key('live-panel-body')), findsOneWidget);
      expect(panel.bottom, 667);
      expect(panel.top - map.top, greaterThanOrEqualTo(150), reason: 'visible map above the Open panel: ${panel.top - map.top} pt');
      expect(tester.getRect(find.byKey(const Key('live-panel-header'))).bottom, lessThanOrEqualTo(667 - 56), reason: 'nothing under the tab bar');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });

    testWidgets('large text does not break the controls', (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      MapPanelStore.clear();
      final fake = FakeSse();
      late LiveMapController c;
      await tester.runAsync(() async => c = makeController(fake));
      await tester.pumpWidget(scoped(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: MediaQuery(
          data: const MediaQueryData(size: Size(390, 844), textScaler: TextScaler.linear(2)),
          child: Scaffold(body: NetworkLiveMap(region: region, controller: c, showBasemap: false)),
        ),
      )));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const Key('live-panel-header')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('live-panel-body')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
    });
  });
}
