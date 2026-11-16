// The MeshTrack `friends` map layer (meshtrack plan section 7 "Map layer", section 6 staleness): pins with initials and a
// course arrow, a fading trail with no line across a jump, the meet-up flag with its label, my last sent position as a
// hollow ring, stale styling, the switch off (nothing drawn), the long-press "Meet here" menu, app-only registry row.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/core/map_definition.dart';
import 'package:meshsonar/core/map_view_state.dart';
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/meshtrack/plus_code.dart';
import 'package:meshsonar/core/privacy_zones.dart';
import 'package:meshsonar/ui/drive/drive_map_model.dart';
import 'package:meshsonar/ui/map/layers/friends_layer.dart';
import 'package:meshsonar/ui/map/layers/map_layer.dart' show MapLayerState;
import 'package:meshsonar/ui/map/layers/registry.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart';

final _now = DateTime.utc(2026, 11, 16, 12);

MtFriend _friend(String name, {Duration ago = const Duration(minutes: 1), MtStaleness? st, int? speed, int? course, List<MtTrailPoint> trail = const [], bool parked = false, double lat = 40.0, double lon = -83.0}) =>
    MtFriend(
      name: name,
      lat: lat,
      lon: lon,
      accuracyM: 3,
      lastHeard: _now.subtract(ago),
      staleness: st ?? mtStaleness(_now.subtract(ago), _now),
      speedKmh: speed,
      courseDeg: course,
      trail: trail,
      parked: parked,
    );

MeshTrackState _state(List<MtFriend> friends, {MtMeetPin? meet, bool see = true, bool share = false, MtMyPosition? me}) => MeshTrackState(
      groups: [
        MtGroupView(
          config: MtGroupConfig(channelId: 7, name: 'Family', see: see, share: share),
          friends: see ? friends : const [],
          heardLast30Min: friends.length,
          sharingNow: share,
          meet: meet,
        ),
      ],
      myLastSent: share ? me : null,
    );

Widget _map(Widget layer, {Brightness b = Brightness.dark}) => MaterialApp(
      theme: meshSonarTheme(b),
      home: FlutterMap(options: const MapOptions(initialCenter: LatLng(40.0, -83.0), initialZoom: 13), children: [layer]),
    );

void main() {
  group('data', () {
    test('initials: two words -> two first letters, one word -> first two characters', () {
      expect(friendInitials('Sam Lee'), 'SL');
      expect(friendInitials('KE4BFI'), 'KE');
      expect(friendInitials('andy_truck'), 'AT');
      expect(friendInitials('  '), '?');
      expect(friendInitials('Zoë'), 'ZO');
    });

    test('trail: no line across a jump (breakBefore); older lines are weaker', () {
      final trail = [
        MtTrailPoint(40.00, -83.00, _now.subtract(const Duration(minutes: 20))),
        MtTrailPoint(40.01, -83.00, _now.subtract(const Duration(minutes: 10))),
        MtTrailPoint(41.50, -83.00, _now.subtract(const Duration(minutes: 5)), breakBefore: true),
        MtTrailPoint(41.51, -83.00, _now),
      ];
      final segs = trailSegments(trail, _now);
      expect(segs, hasLength(2), reason: 'three steps, one is a jump');
      expect(segs.any((s) => (s.a.latitude - 40.01).abs() < 1e-9 && (s.b.latitude - 41.5).abs() < 1e-9), isFalse);
      expect(segs.first.strength, lessThan(segs.last.strength));
      expect(segs.last.strength, closeTo(1, 1e-9));
    });

    test('staleness: fresh full, faded dimmer, grey grey, list-only not drawn', () {
      expect(friendLook(MtStaleness.fresh), (opacity: 1.0, grey: false));
      expect(friendLook(MtStaleness.faded)!.opacity, lessThan(1));
      expect(friendLook(MtStaleness.grey)!.grey, isTrue);
      expect(friendLook(MtStaleness.listOnly), isNull);
      final d = FriendsLayerData.of(
          _state([
            _friend('A', ago: const Duration(minutes: 1)),
            _friend('B', ago: const Duration(minutes: 8)),
            _friend('C', ago: const Duration(minutes: 30)),
            _friend('D', ago: const Duration(hours: 3)),
          ]),
          _now);
      expect([for (final p in d.pins) p.friend.name], ['A', 'B', 'C']);
    });

    test('the arrow shows only while moving (5 km/h or more, not parked, not grey)', () {
      final d = FriendsLayerData.of(
          _state([
            _friend('Fast', speed: 40, course: 90),
            _friend('Slow', speed: 3, course: 90),
            _friend('Parked', speed: 0, course: 90, parked: true),
            _friend('Old', speed: 40, course: 90, ago: const Duration(minutes: 30)),
          ]),
          _now);
      expect({for (final p in d.pins) p.friend.name: p.arrowDeg}, {'Fast': 90.0, 'Slow': null, 'Parked': null, 'Old': null});
    });

    test('See off draws nothing; my ring only while sharing', () {
      expect(FriendsLayerData.of(_state([_friend('A')], see: false), _now).isEmpty, isTrue);
      final me = MtMyPosition(40.0, -83.0, _now);
      expect(FriendsLayerData.of(_state(const [], share: false, me: me), _now).me, isNull);
      expect(FriendsLayerData.of(_state(const [], share: true, me: me), _now).me, isNotNull);
    });
  });

  group('drawing', () {
    testWidgets('pins with initials and arrow, meet flag with label, my ring; stale keys', (tester) async {
      final s = _state(
        [
          _friend('Sam Lee', speed: 50, course: 45, trail: [
            MtTrailPoint(39.99, -83.0, _now.subtract(const Duration(minutes: 4))),
            MtTrailPoint(40.0, -83.0, _now),
          ]),
          _friend('Kim', ago: const Duration(minutes: 8), lat: 40.01),
          _friend('Old', ago: const Duration(minutes: 40), lat: 39.99),
        ],
        meet: MtMeetPin(lat: 40.005, lon: -83.005, label: 'Gate 3', at: _now),
        share: true,
        me: MtMyPosition(40.002, -83.002, _now),
      );
      final data = FriendsLayerData.of(s, _now);
      await tester.pumpWidget(_map(Stack(children: [FriendsTrailsLayer(data: data), FriendsMarkersLayer(data: data, now: () => _now)])));
      await tester.pump();
      expect(find.byKey(const ValueKey('map-friend-7-Sam Lee-fresh')), findsOneWidget);
      expect(find.text('SL'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-friend-arrow-7-Sam Lee')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-friend-7-Kim-faded')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-friend-arrow-7-Kim')), findsNothing);
      expect(find.byKey(const ValueKey('map-friend-7-Old-grey')), findsOneWidget);
      expect(find.byKey(const ValueKey('map-meet-7')), findsOneWidget);
      expect(find.text('Gate 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('map-friend-me')), findsOneWidget);
      final opacity = tester.widget<Opacity>(find.byKey(const ValueKey('map-friend-7-Kim')));
      expect(opacity.opacity, lessThan(1));
      final poly = tester.widget<PolylineLayer>(find.byType(PolylineLayer));
      expect(poly.polylines, hasLength(1));
      Finder label(String l) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == l);
      expect(label('Sam Lee, last heard 1 min ago'), findsOneWidget, reason: 'VoiceOver reads the name and when');
      expect(label('Meet-up point: Gate 3'), findsOneWidget);
      expect(label('Your last shared position'), findsOneWidget);
    });

    testWidgets('the arrow follows the course', (tester) async {
      final data = FriendsLayerData.of(_state([_friend('Sam', speed: 50, course: 90)]), _now);
      await tester.pumpWidget(_map(FriendsMarkersLayer(data: data, now: () => _now)));
      await tester.pump();
      final t = tester.widget<Transform>(find.byKey(const ValueKey('map-friend-arrow-7-Sam')));
      final angle = math.atan2(t.transform.entry(1, 0), t.transform.entry(0, 0));
      expect(angle, closeTo(math.pi / 2, 1e-6));
    });

    testWidgets('friendsLayerWidgets rebuilds on every MeshTrack change (a friend appears)', (tester) async {
      final svc = MeshTrackService(
        sendChannelText: (_, _) async => true,
        budget: (_, _) => MtBudget.ok,
        zones: () => const PrivacyZones([]),
        selfName: () => 'Me',
        now: () => _now,
      );
      svc.addGroup(7, 'Family');
      await tester.pumpWidget(_map(Stack(children: friendsLayerWidgets(svc, now: () => _now))));
      expect(find.byKey(const ValueKey('map-friend-7-Sam-fresh')), findsNothing);
      svc.onChannelText(MtInboundText(channelId: 7, text: 'Sam: MT1 @${PlusCode.encode(40.0, -83.0)}', receivedAt: _now));
      await tester.pump();
      expect(find.byKey(const ValueKey('map-friend-7-Sam-fresh')), findsOneWidget);
      expect(find.byKey(const Key('friends-layer')), findsOneWidget);
      expect(find.byKey(const Key('friends-trails-layer')), findsOneWidget);
    });
  });

  group('registry and the Drive map', () {
    tearDown(() {
      AppFlags.debugMeshTrack = null;
      friendsLayerOffered = () => AppFlags.meshTrackOn;
    });

    test('friends is an app-only key, on by default, never on the website', () {
      final spec = layerSpec(kFriendsLayerId)!;
      expect(spec.onWebsite, isFalse);
      expect(spec.serverFed, isFalse);
      expect(spec.defaultOn, isTrue);
      expect(spec.label, 'Friends');
      expect(kAppOnlyShowKeys, contains('friends'));
      expect(kWebsiteShowKeys, isNot(contains('friends')));
      expect(kWebsiteKeysDrawn, isNot(contains('friends')));
      expect(definitionLayerId(kFriendsLayerId), isNull, reason: 'not a Map Definition layer');
      const s = MapLayerState(on: {'measured', 'friends'});
      expect(s.toShow(), 'measured', reason: 'https links never carry it');
      expect(s.toShow(web: false), contains('friends'));
    });

    test('the sheet lists Friends first under Network only while MeshTrack is in the build', () {
      friendsLayerOffered = () => false;
      final off = sheetRows(MapDefinition.bundled);
      expect([for (final (_, rows) in off) ...rows.map((r) => r.id)], isNot(contains('friends')));
      friendsLayerOffered = () => true;
      final on = sheetRows(MapDefinition.bundled);
      expect(on[1].$1.id, 'network');
      expect(on[1].$2.first.id, 'friends');
    });

    test('Drive map: the layer draws only with MeshTrack and the switch on; it is offered only with MeshTrack', () async {
      AppFlags.debugMeshTrack = true;
      final h = Harness();
      await h.state.init();
      final model = DriveMapModel(h.state);
      expect(model.layerOffered(kFriendsLayerId), isTrue);
      expect(model.friendsOn, isTrue, reason: 'on by default');
      model.setLayer(kFriendsLayerId, false);
      expect(model.friendsOn, isFalse);
      model.dispose();
      h.state.dispose();

      AppFlags.debugMeshTrack = false;
      final h2 = Harness();
      await h2.state.init();
      final m2 = DriveMapModel(h2.state);
      expect(m2.layerOffered(kFriendsLayerId), isFalse);
      expect(m2.friendsOn, isFalse);
      m2.dispose();
      h2.state.dispose();
    });

    testWidgets('long-press "Meet here": one action per group; it sets the pin; Undo takes it away', (tester) async {
      final svc = MeshTrackService(
        sendChannelText: (_, _) async => true,
        budget: (_, _) => MtBudget.ok,
        zones: () => const PrivacyZones([]),
        selfName: () => 'Me',
        now: () => _now,
      );
      svc.addGroup(7, 'Family');
      svc.setRadioConnected(true);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showMeetHereMenu(context, svc, 40.0, -83.0), child: const Text('hold'))))),
      ));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('meet-here-sheet')), findsOneWidget);
      await tester.tap(find.byKey(const Key('meet-here-7')));
      await tester.pumpAndSettle();
      expect(svc.state.group(7)!.meet, isNotNull);
      expect(find.text('Meet-up point shared'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(svc.state.group(7)!.meet, isNull);
      await tester.pumpAndSettle(const Duration(seconds: 6));
      await svc.dispose();
    });

    testWidgets('long-press "Meet here" in Approximate goes at 8 digits; the zone gate runs on the pressed point', (tester) async {
      final sent = <String>[];
      var zones = const PrivacyZones([]);
      final svc = MeshTrackService(
        sendChannelText: (_, t) async {
          sent.add(t);
          return true;
        },
        budget: (_, _) => MtBudget.ok,
        zones: () => zones,
        selfName: () => 'Me',
        now: () => _now,
      );
      svc.addGroup(7, 'Family');
      svc.setRadioConnected(true);
      svc.setPositionMode(MtPositionMode.approximate);
      var at = (lat: 39.5, lon: -83.5);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showMeetHereMenu(context, svc, at.lat, at.lon), child: const Text('hold'))))),
      ));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('meet-here-7')));
      await tester.pumpAndSettle();
      expect(sent.single, 'MT1 !${PlusCode.encode(39.5, -83.5, codeLength: kPlusCodeApproxDigits)}');
      await tester.pumpAndSettle(const Duration(seconds: 6));
      // A pressed point 150 m outside a zone edge (inside the 200 m buffer) is refused.
      zones = const PrivacyZones([PrivacyZone(label: 'Home', lat: 40.0, lon: -83.0, radiusM: 300)]);
      at = (lat: 40.0, lon: -83.0 + 450 / (111320 * math.cos(40 * math.pi / 180)));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('meet-here-7')));
      await tester.pumpAndSettle();
      expect(sent, hasLength(1));
      expect(find.textContaining('privacy zones'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 6));
      await svc.dispose();
    });

    testWidgets('long-press "Meet here" inside a privacy zone says so and sets nothing', (tester) async {
      final svc = MeshTrackService(
        sendChannelText: (_, _) async => true,
        budget: (_, _) => MtBudget.ok,
        zones: () => const PrivacyZones([PrivacyZone(label: 'Home', lat: 40.0, lon: -83.0, radiusM: 300)]),
        selfName: () => 'Me',
        now: () => _now,
      );
      svc.addGroup(7, 'Family');
      svc.setRadioConnected(true);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: Builder(builder: (context) => Scaffold(body: Center(child: TextButton(onPressed: () => showMeetHereMenu(context, svc, 40.0, -83.0), child: const Text('hold'))))),
      ));
      await tester.tap(find.text('hold'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('meet-here-7')));
      await tester.pumpAndSettle();
      expect(svc.state.group(7)!.meet, isNull);
      expect(find.textContaining('privacy zones'), findsOneWidget);
      await tester.pumpAndSettle(const Duration(seconds: 6));
    });

    test('no group: no menu', () async {
      final svc = MeshTrackService(
        sendChannelText: (_, _) async => true,
        budget: (_, _) => MtBudget.ok,
        zones: () => const PrivacyZones([]),
        selfName: () => 'Me',
      );
      expect(svc.state.groups, isEmpty);
      // showMeetHereMenu returns false before touching the context when there is no group.
      expect(await showMeetHereMenu(_NoContext(), svc, 0, 0), isFalse);
    });
  });
}

class _NoContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError('context used');
}
