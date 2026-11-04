// The Network segment (WP11): grouping and show-all, empty states, the radio card (battery chip states, 60 s foreground poll,
// Announce and Tools menus), Heard nearby with Add / Ignore, and the swipe actions. NetworkView is pumped on its own over a
// chat controller whose "radio" can be switched on and off, with a fake radio behind the card.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_controller.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/radio/protocol.dart' show BattAndStorageFrame;
import 'package:meshsonar/ui/chat/chat_navigation.dart';
import 'package:meshsonar/ui/chat/network_radio.dart';
import 'package:meshsonar/ui/chat/network_view.dart';
import 'package:meshsonar/ui/design/app_surfaces.dart';
import 'package:meshsonar/ui/theme.dart';

import '../chat/chat_kit.dart';

class _Sink extends SwitchableSink {
  bool up = false;
  @override
  bool get canSend => up;
}

class FakeNetworkRadio implements NetworkRadio {
  @override
  bool connected = true;
  @override
  String? name = 'INNO-OB-1';
  @override
  String? firmware = '1.18';
  @override
  double? frequencyMhz = 915;
  int batteryCalls = 0;
  BattAndStorageFrame? reading = const BattAndStorageFrame(batteryMv: 4000);
  Completer<BattAndStorageFrame?>? pending;
  final announces = <bool>[];
  int discovers = 0;
  Completer<({bool ok, String message})>? discoverGate;

  @override
  Future<BattAndStorageFrame?> battery() async {
    batteryCalls++;
    final p = pending;
    if (p != null) return p.future;
    return reading;
  }

  @override
  Future<({bool ok, String message})> announce({required bool wide}) async {
    announces.add(wide);
    return (ok: true, message: wide ? 'Advert sent to the whole mesh.' : 'Local advert sent.');
  }

  @override
  Future<({bool ok, String message})> discover() {
    discovers++;
    return discoverGate?.future ?? Future.value((ok: true, message: '2 nodes answered.'));
  }
}

String key64(int i) => '${i.toRadixString(16).padLeft(2, '0')}${'cd' * 31}';

void main() {
  late ChatKit kit;
  late _Sink sink;
  late ChatController controller;
  late ChatNavigator nav;
  late FakeNetworkRadio radio;

  setUp(() {
    kit = ChatKit();
    sink = _Sink();
    controller = ChatController(
      store: kit.store,
      service: kit.service,
      sink: sink,
      wardriveChannelName: () => '#wardriving',
      now: () => DateTime.fromMillisecondsSinceEpoch(kit.clockMs),
    );
    nav = ChatNavigator(controller);
    radio = FakeNetworkRadio();
  });
  tearDown(() {
    nav.dispose();
    kit.dispose();
    dismissAppToast();
  });

  void setConnected(bool v) {
    sink.up = v;
    radio.connected = v;
    // ignore: invalid_use_of_protected_member
    controller.notifyListeners();
  }

  Future<void> pump(WidgetTester tester, {bool connected = true, String query = '', double scale = 1.0, Size size = const Size(393, 2000), NetworkRadio? r}) async {
    tester.view.physicalSize = size * 3;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    sink.up = connected;
    radio.connected = connected;
    await tester.pumpWidget(MaterialApp(
      theme: meshSonarTheme(Brightness.light).copyWith(platform: TargetPlatform.iOS),
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      home: Scaffold(
        body: CustomScrollView(
          slivers: [NetworkView(controller: controller, navigator: nav, query: query, radio: r ?? radio, onConnect: () {})],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
  }

  Contact node(int i, ContactType t, String name, {bool fav = false, int? heard, int pathLen = 0xFF}) {
    final c = Contact(radioId: radioA, publicKey: key64(i), type: t, name: name, favourite: fav, lastHeardMs: heard ?? kit.clockMs - i * 60000, outPathLen: pathLen);
    kit.store.contacts.upsert(c);
    return c;
  }

  // The contact manager picks the radio from its link, else from the book; the book needs one entry (a person, not listed
  // in Network) to name radioA.
  void advert(int i, String name, {ContactType t = ContactType.repeater}) {
    kit.bob();
    kit.store.adverts.record(AdvertSeen(
      radioId: radioA, publicKey: key64(100 + i), type: t, name: name, firstTsMs: kit.clockMs, lastTsMs: kit.clockMs - i * 1000, pathLen: 2));
  }

  group('grouping and sections', () {
    testWidgets('repeaters, rooms and sensors: five rows each, favourites first, then Show all N and Show fewer', (tester) async {
      for (var i = 1; i <= 7; i++) {
        node(i, ContactType.repeater, 'Ridge $i', fav: i == 7);
      }
      node(20, ContactType.room, 'North room');
      node(21, ContactType.sensor, 'Garage temp');
      await pump(tester);
      expect(find.text('REPEATERS'), findsOneWidget);
      expect(find.text('ROOMS'), findsOneWidget);
      expect(find.text('SENSORS'), findsOneWidget);
      expect(find.text('Ridge 7'), findsOneWidget, reason: 'the favourite jumps the queue');
      expect(find.text('Ridge 1'), findsOneWidget);
      expect(find.text('Ridge 5'), findsNothing);
      final fav = tester.getTopLeft(find.text('Ridge 7')).dy;
      expect(fav, lessThan(tester.getTopLeft(find.text('Ridge 1')).dy));
      expect(find.text('Show all 7'), findsOneWidget);
      expect(find.byKey(const Key('network-showall-room')), findsNothing, reason: 'one room needs no Show all');
      await tester.ensureVisible(find.byKey(const Key('network-showall-repeater')));
      await tester.tap(find.byKey(const Key('network-showall-repeater')));
      await tester.pump();
      expect(find.text('Ridge 5'), findsOneWidget);
      expect(find.text('Show fewer'), findsOneWidget);
    });

    testWidgets('a search filters the sections and hides the radio card; no match says so', (tester) async {
      node(1, ContactType.repeater, 'North Ridge');
      node(2, ContactType.repeater, 'Hill Top');
      await pump(tester, query: 'ridge');
      expect(find.text('North Ridge'), findsOneWidget);
      expect(find.text('Hill Top'), findsNothing);
      expect(find.byKey(const Key('network-radio-card')), findsNothing);
      await pump(tester, query: 'zzz');
      expect(find.byKey(const Key('network-no-results')), findsOneWidget);
    });

    testWidgets('the subtitle under the radio card explains the page', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('network-subtitle')), findsOneWidget);
      expect(find.text('Your radio, repeaters, rooms and sensors'), findsOneWidget);
    });
  });

  group('empty states', () {
    testWidgets('connected: No repeaters heard yet with Send an advert and Discover nearby that work', (tester) async {
      await pump(tester);
      expect(find.byKey(const Key('network-empty')), findsOneWidget);
      expect(find.text('No repeaters heard yet'), findsOneWidget);
      expect(find.text('They appear after their next advert.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('network-empty-advert')));
      await tester.pump();
      expect(radio.announces, [false]);
      await tester.tap(find.byKey(const Key('network-empty-discover')));
      await tester.pump();
      expect(radio.discovers, 1);
      dismissAppToast();
    });

    testWidgets('no radio: the card says so, the empty state offers Connect radio', (tester) async {
      await pump(tester, connected: false);
      expect(find.text('Radio not connected'), findsOneWidget);
      expect(find.byKey(const Key('network-empty-connect')), findsOneWidget);
      expect(find.byKey(const Key('network-announce')), findsNothing);
      expect(find.byKey(const Key('network-tools')), findsNothing);
      expect(find.byKey(const Key('battery-chip-ok')), findsNothing);
    });
  });

  group('radio card and battery chip', () {
    testWidgets('shows name, state, battery, firmware and frequency', (tester) async {
      await pump(tester);
      expect(find.text('INNO-OB-1'), findsOneWidget);
      expect(find.text('Connected'), findsOneWidget);
      expect(find.text('82%'), findsOneWidget);
      expect(find.text('· fw 1.18'), findsOneWidget);
      expect(find.text('· 915 MHz'), findsOneWidget);
      expect(find.bySemanticsLabel(RegExp('Battery about 82 percent')), findsOneWidget);
    });

    testWidgets('states: reading, ok, low, unavailable, and none once the radio goes', (tester) async {
      final gate = Completer<BattAndStorageFrame?>();
      radio.pending = gate;
      await pump(tester);
      expect(find.byKey(const Key('battery-chip-loading')), findsOneWidget);
      gate.complete(const BattAndStorageFrame(batteryMv: 3500));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('battery-chip-low')), findsOneWidget);
      expect(find.text('5%'), findsOneWidget);
      radio.pending = null;
      radio.reading = null;
      await tester.pump(const Duration(seconds: 61));
      await tester.pump();
      expect(find.byKey(const Key('battery-chip-unavailable')), findsOneWidget);
      radio.reading = const BattAndStorageFrame(batteryMv: 4100);
      await tester.pump(const Duration(seconds: 60));
      await tester.pump();
      expect(find.byKey(const Key('battery-chip-ok')), findsOneWidget);
      setConnected(false);
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('battery-chip-ok')), findsNothing);
    });

    testWidgets('polled every 60 s in the foreground only', (tester) async {
      await pump(tester);
      expect(radio.batteryCalls, 1);
      await tester.pump(const Duration(seconds: 59));
      expect(radio.batteryCalls, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(radio.batteryCalls, 2);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      await tester.pump(const Duration(minutes: 5));
      expect(radio.batteryCalls, 2, reason: 'a backgrounded app asks the radio nothing');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(radio.batteryCalls, 3, reason: 'back in the foreground it reads at once');
      // Leaving the segment stops the timer (no pending timers at the end of the test).
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('Announce and Tools', () {
    testWidgets('Announce: nearby only goes out at once, wider asks first', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('network-announce')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('announce-nearby')), findsOneWidget);
      expect(find.byKey(const Key('announce-wide')), findsOneWidget);
      await tester.tap(find.byKey(const Key('announce-nearby')));
      await tester.pumpAndSettle();
      expect(radio.announces, [false]);
      dismissAppToast();
      await tester.tap(find.byKey(const Key('network-announce')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('announce-wide')));
      await tester.pumpAndSettle();
      expect(radio.announces, [false], reason: 'the mesh-wide advert needs a yes first');
      await tester.tap(find.byKey(const Key('announce-wide-confirm')));
      await tester.pumpAndSettle();
      expect(radio.announces, [false, true]);
      dismissAppToast();
    });

    testWidgets('Tools lists Trace, Discover, Rx log and Adverts', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const Key('network-tools')));
      await tester.pumpAndSettle();
      for (final k in ['tools-trace', 'tools-discover', 'tools-rxlog', 'tools-adverts']) {
        expect(find.byKey(Key(k)), findsOneWidget, reason: k);
      }
    });
  });

  group('Heard nearby', () {
    testWidgets('three new nodes show with Add and Ignore; Ignore takes one away', (tester) async {
      for (var i = 1; i <= 3; i++) {
        advert(i, 'Newcomer $i');
      }
      await pump(tester);
      expect(find.text('HEARD NEARBY (3 NEW)'), findsOneWidget);
      expect(find.text('Newcomer 1'), findsOneWidget);
      expect(find.byKey(const Key('nearby-see-all')), findsNothing, reason: 'three fit');
      expect(find.byKey(Key('nearby-add-${key64(101).substring(0, 8)}')), findsOneWidget);
      await tester.tap(find.byKey(Key('nearby-ignore-${key64(101).substring(0, 8)}')));
      await tester.pump();
      await tester.pump();
      expect(find.text('Newcomer 1'), findsNothing);
      expect(find.text('HEARD NEARBY (2 NEW)'), findsOneWidget);
    });

    testWidgets('more than three: the first three and See all, which lists every one', (tester) async {
      for (var i = 1; i <= 5; i++) {
        advert(i, 'Newcomer $i');
      }
      await pump(tester);
      expect(find.text('Newcomer 3'), findsOneWidget);
      expect(find.text('Newcomer 4'), findsNothing);
      await tester.tap(find.byKey(const Key('nearby-see-all')));
      await tester.pumpAndSettle();
      expect(find.text('Newcomer 5'), findsOneWidget);
    });

    testWidgets('nothing new: says so, and Discover nearby runs once and is busy meanwhile', (tester) async {
      radio.discoverGate = Completer();
      await pump(tester);
      expect(find.byKey(const Key('nearby-none')), findsOneWidget);
      await tester.tap(find.byKey(const Key('nearby-discover')));
      await tester.pump();
      expect(find.text('Discovering…'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nearby-discover')), warnIfMissed: false);
      await tester.pump();
      expect(radio.discovers, 1, reason: 'a second tap during a scan is ignored');
      radio.discoverGate!.complete((ok: true, message: '2 nodes answered.'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Discover nearby'), findsWidgets);
      dismissAppToast();
    });

    testWidgets('no radio and nothing heard: no Heard nearby section', (tester) async {
      await pump(tester, connected: false);
      expect(find.byKey(const Key('nearby-heading')), findsNothing);
    });
  });

  group('swipe actions', () {
    testWidgets('repeaters and rooms swipe to Log in and Ping; sensors do not swipe', (tester) async {
      final rep = node(1, ContactType.repeater, 'North Ridge');
      final room = node(2, ContactType.room, 'Lounge');
      final sens = node(3, ContactType.sensor, 'Garage');
      await pump(tester);
      expect(find.byType(Slidable), findsNWidgets(2));
      await tester.drag(find.byKey(Key('network-row-${rep.prefix}')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('network-swipe-login-${rep.prefix}')), findsOneWidget);
      expect(find.byKey(Key('network-swipe-ping-${rep.prefix}')), findsOneWidget);
      expect(find.byKey(Key('network-swipe-login-${sens.prefix}')), findsNothing);
      expect(find.byKey(Key('network-row-${room.prefix}')), findsOneWidget);
    });

    testWidgets('with no radio, Log in and Ping say to connect instead of failing', (tester) async {
      final rep = node(1, ContactType.repeater, 'North Ridge');
      await pump(tester, connected: false);
      await tester.drag(find.byKey(Key('network-row-${rep.prefix}')), const Offset(-300, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('network-swipe-login-${rep.prefix}')));
      await tester.pump();
      expect(find.text('Connect your radio first.'), findsOneWidget);
      dismissAppToast();
      await tester.pump(const Duration(seconds: 6));
    });

    testWidgets('VoiceOver gets Log in and Ping as custom actions on the row', (tester) async {
      final rep = node(1, ContactType.repeater, 'North Ridge');
      final h = tester.ensureSemantics();
      await pump(tester);
      final data = tester.getSemantics(find.byKey(Key('network-row-${rep.prefix}'))).getSemanticsData();
      expect(data.customSemanticsActionIds, isNotNull);
      expect(data.customSemanticsActionIds!.length, 2);
      h.dispose();
    });
  });

  testWidgets('AX2 text keeps the card readable with no overflow', (tester) async {
    node(1, ContactType.repeater, 'North Ridge');
    await pump(tester, scale: 2.0, size: const Size(375, 667));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('network-announce')), findsOneWidget);
  });
}
