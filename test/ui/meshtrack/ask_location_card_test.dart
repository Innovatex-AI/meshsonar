// MeshTrack MT-13 "Ask for location" on a person's contact screen: every state of the card (ready, asking with Cancel,
// position with distance and direction through Units and Open on map, no position, no answer with Try again, the 30 s
// limit, no radio), the asked pin on the Friends layer, and where the card shows (people only). iPhone 17 Pro, dark.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Tristate;

import 'package:flutter/cupertino.dart' show CupertinoActivityIndicator;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/core/meshtrack/meshtrack_service.dart';
import 'package:meshsonar/core/units.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/tools/ask_location.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/telemetry_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/ui/contacts/contact_profile_screen.dart';
import 'package:meshsonar/ui/map/layers/friends_layer.dart';
import 'package:meshsonar/ui/meshtrack/ask_location_card.dart';
import 'package:meshsonar/ui/theme.dart';

import '../../chat/contact_support.dart';
import '../../support/tools_rig.dart';
import '../contacts/contacts_ui_support.dart';

/// Westerville start of the simulated drive; Maya answers from about 3 km north-east.
const here = (lat: 40.1258, lon: -82.9312);
const mayaLat = 40.1472, mayaLon = -82.9046;

class Rig {
  final radio = FakeToolsRadio();
  late final TelemetryTool tool;
  late final AskLocationHub hub;
  final log = <String>[];
  final opened = <(MtAskedPosition, bool)>[];
  late final MeshTrackService mt = MeshTrackService(
    sendChannelText: (_, _) async => true,
    budget: (_, _) => MtBudget.ok,
    zones: () => throw UnimplementedError(),
    selfName: () => 'Me',
    now: () => now,
  );

  /// The hub's clock (the 30 s limit); [pass] moves it with the test's fake time.
  DateTime now = DateTime(2026, 11, 16, 12);

  Rig() {
    tool = TelemetryTool(radio, testArbiter(), minGap: Duration.zero, clock: () => now)..queue = RemoteRequestQueue();
    hub = AskLocationHub(tool, log: log.add, clock: () => now);
  }

  /// Lets [d] pass: the hub's clock and the widget test's timers.
  Future<void> pass(WidgetTester tester, Duration d) async {
    now = now.add(d);
    await tester.pump(d);
    await tester.pump();
  }

  /// The contact answers with [lpp] after [after]; null = never answers.
  void answers(Contact c, List<int>? lpp, {Duration after = const Duration(seconds: 2)}) {
    radio.onSend = (f) {
      if (lpp != null) {
        Timer(after, () {
          radio.push(encodeTelemetryResponsePush(
              Uint8List.fromList([for (var k = 0; k < 6; k++) int.parse(c.publicKey.substring(k * 2, k * 2 + 2), radix: 16)]), lpp));
        });
      }
      return const SentFrame(flood: false, tag: 1, estTimeoutMs: 1800);
    };
  }

  AskLocationEnv env({bool connected = true, Units units = Units.metric, bool meshTrack = true}) => AskLocationEnv(
        hub: connected ? hub : null,
        units: units,
        here: () => here,
        meshTrack: meshTrack ? mt : null,
        now: () => now,
        openOnMap: (context, p, {required friendsLayer}) => opened.add((p, friendsLayer)),
      );
}

Future<void> pumpCard(WidgetTester tester, Contact c, AskLocationEnv env) async {
  tester.view.physicalSize = const Size(402 * 3, 874 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: meshSonarTheme(Brightness.dark),
    home: Scaffold(body: ListView(children: [AskLocationCard(contact: c, env: env)])),
  ));
  await tester.pump();
}

Future<void> tapAsk(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  final maya = radioContact(1, name: 'Maya Chen');

  testWidgets('ready: Ask for location with a plain footer', (tester) async {
    final r = Rig();
    await pumpCard(tester, maya, r.env());
    expect(find.text('Ask for location'), findsOneWidget);
    expect(find.text("Asks Maya's radio where it is. It answers only if they allow it."), findsOneWidget);
  });

  testWidgets('asking (spinner + Cancel), then a position: distance and direction, the asked pin, Open on map', (tester) async {
    final r = Rig()..answers(maya, [...lppVoltage(3.9), ...lppGps(mayaLat, mayaLon, 268)]);
    await pumpCard(tester, maya, r.env());
    await tapAsk(tester, 'ask-location');
    expect(find.byKey(const Key('ask-location-asking')), findsOneWidget);
    expect(find.text('Asking Maya Chen…'), findsOneWidget);
    expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
    expect(find.byKey(const Key('ask-location-cancel')), findsOneWidget);

    await r.pass(tester, const Duration(seconds: 3));
    expect(find.byKey(const Key('ask-location-answer')), findsOneWidget);
    expect(find.text('3.3 km NE of you'), findsOneWidget);
    expect(find.text('Answered just now'), findsOneWidget);
    expect(find.text('Open on map'), findsOneWidget);
    expect(find.textContaining('Ask again in'), findsOneWidget, reason: 'the 30 s limit shows as a countdown');

    // The asked pin is on the Friends layer (memory only).
    expect(r.mt.state.asked.single.lat, closeTo(mayaLat, 1e-4));
    final data = FriendsLayerData.of(r.mt.state, r.now);
    expect(data.asked.single.asked.name, 'Maya Chen');

    await tester.tap(find.byKey(const Key('ask-location-open')));
    expect(r.opened.single.$1.lon, closeTo(mayaLon, 1e-4));
    expect(r.opened.single.$2, isTrue, reason: 'MeshTrack on: the Friends layer draws it');

    await r.pass(tester, const Duration(seconds: 30));
    expect(find.text('Ask again'), findsOneWidget);
    r.hub.dispose();
  });

  testWidgets('imperial units: the distance is in miles', (tester) async {
    final r = Rig()..answers(maya, [...lppVoltage(3.9), ...lppGps(mayaLat, mayaLon, 268)]);
    await pumpCard(tester, maya, r.env(units: Units.imperial));
    await tapAsk(tester, 'ask-location');
    await r.pass(tester, const Duration(seconds: 3));
    expect(find.textContaining(RegExp(r'^2\.\d mi NE of you$')), findsOneWidget);
    await r.pass(tester, const Duration(seconds: 31));
    r.hub.dispose();
  });

  testWidgets('MeshTrack off in the build: Open on map still works, as a one-off target', (tester) async {
    final r = Rig()..answers(maya, [...lppGps(mayaLat, mayaLon, 268)]);
    await pumpCard(tester, maya, r.env(meshTrack: false));
    await tapAsk(tester, 'ask-location');
    await r.pass(tester, const Duration(seconds: 3));
    await tester.tap(find.byKey(const Key('ask-location-open')));
    expect(r.opened.single.$2, isFalse);
    await r.pass(tester, const Duration(seconds: 31));
  });

  testWidgets('answer without a position: the plain sentence, Ask again after the limit', (tester) async {
    final r = Rig()..answers(maya, [...lppVoltage(3.9), ...lppTemperature(27)]);
    await pumpCard(tester, maya, r.env());
    await tapAsk(tester, 'ask-location');
    await r.pass(tester, const Duration(seconds: 3));
    expect(find.text("Maya Chen did not share a location. They can allow it in their MeshCore app's telemetry settings."), findsOneWidget);
    expect(r.mt.state.asked, isEmpty);
    await r.pass(tester, const Duration(seconds: 30));
    expect(find.text('Ask again'), findsOneWidget);
  });

  testWidgets('no answer within 30 s: "No answer from Maya Chen." with Try again, which asks again', (tester) async {
    final r = Rig()..answers(maya, null);
    await pumpCard(tester, maya, r.env());
    await tapAsk(tester, 'ask-location');
    await r.pass(tester, const Duration(seconds: 29));
    expect(find.byKey(const Key('ask-location-asking')), findsOneWidget, reason: 'still asking at 29 s');
    await r.pass(tester, const Duration(seconds: 2));
    expect(find.text('No answer from Maya Chen.'), findsOneWidget);
    expect(find.text('They may be out of range, or their radio may not answer location requests.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tapAsk(tester, 'ask-location-retry');
    expect(find.byKey(const Key('ask-location-asking')), findsOneWidget);
    expect(r.radio.sent.length, 2);
    await r.pass(tester, const Duration(seconds: 31));
  });

  testWidgets('Cancel: back to the start, with the 30 s countdown (the request was already on air)', (tester) async {
    final r = Rig()..answers(maya, null);
    await pumpCard(tester, maya, r.env());
    await tapAsk(tester, 'ask-location');
    await tester.tap(find.byKey(const Key('ask-location-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('ask-location-asking')), findsNothing);
    expect(find.textContaining('Ask again in'), findsOneWidget);
    // Tapping the dimmed row sends nothing.
    await tester.tap(find.byKey(const Key('ask-location')));
    await tester.pump();
    expect(r.radio.sent.length, 1);
    await r.pass(tester, const Duration(seconds: 31));
    expect(find.text('Ask for location'), findsOneWidget);
  });

  testWidgets('no radio: the row is dimmed with the reason and does nothing', (tester) async {
    final r = Rig();
    await pumpCard(tester, maya, r.env(connected: false));
    expect(find.text('Ask for location'), findsOneWidget);
    expect(find.text('Connect your radio to ask.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('ask-location')));
    await tester.pump();
    expect(r.radio.sent, isEmpty);
    final sem = tester.getSemantics(find.byKey(const Key('ask-location')));
    expect(sem.flagsCollection.isEnabled, Tristate.isFalse);
  });

  testWidgets('not on the radio: says so, Try again right away', (tester) async {
    final r = Rig();
    r.radio.onSend = (f) => const ErrFrame(ErrCode.notFound);
    await pumpCard(tester, maya, r.env());
    await tapAsk(tester, 'ask-location');
    await tester.pump();
    expect(find.text('Maya Chen is not on your radio yet. Put them on your radio, then ask.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('every action is at least 48 pt tall', (tester) async {
    final r = Rig()..answers(maya, [...lppGps(mayaLat, mayaLon, 268)]);
    await pumpCard(tester, maya, r.env());
    expect(tester.getSize(find.byKey(const Key('ask-location'))).height, greaterThanOrEqualTo(48));
    await tapAsk(tester, 'ask-location');
    expect(tester.getSize(find.byKey(const Key('ask-location-cancel'))).height, greaterThanOrEqualTo(48));
    await r.pass(tester, const Duration(seconds: 3));
    expect(tester.getSize(find.byKey(const Key('ask-location-open'))).height, greaterThanOrEqualTo(48));
    await r.pass(tester, const Duration(seconds: 31));
  });

  group('contact screen', () {
    Future<void> pumpProfile(WidgetTester tester, ContactsRig rig, String key, AskLocationEnv env) async {
      tester.view.physicalSize = const Size(402 * 3, 874 * 3);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: meshSonarTheme(Brightness.dark),
        home: ContactProfileScreen(
          controller: rig.controller,
          publicKey: key,
          mapBuilder: (c, lat, lon) => const SizedBox(height: 120),
          askLocation: env,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a person gets Ask for location; a repeater and a room do not', (tester) async {
      final rig = ContactsRig();
      rig.port.radioAdd(radioContact(1, name: 'Maya Chen'));
      rig.port.radioAdd(radioContact(2, type: ContactType.repeater, name: 'Hilltop'));
      rig.port.radioAdd(radioContact(3, type: ContactType.room, name: 'Club room'));
      rig.chat.contacts.attach(rig.port);
      await rig.chat.contacts.syncNow();
      final env = Rig().env();
      await pumpProfile(tester, rig, keyN(1), env);
      await tester.scrollUntilVisible(find.byKey(const Key('ask-location')), 200,
          scrollable: find.descendant(of: find.byKey(const Key('contact-profile')), matching: find.byType(Scrollable)).first);
      expect(find.byKey(const Key('ask-location-card')), findsOneWidget);
      await pumpProfile(tester, rig, keyN(2), env);
      expect(find.byKey(const Key('ask-location-card')), findsNothing);
      await pumpProfile(tester, rig, keyN(3), env);
      expect(find.byKey(const Key('ask-location-card')), findsNothing);
      rig.dispose();
    });
  });
}
