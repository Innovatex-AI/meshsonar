// MeshTrack MT-13 "Ask for location": the request bytes, an LPP GPS answer written the way the firmware writes it, and
// the hub's states (position, no position, no answer, cancel, not on radio, no radio), the once-per-30-s limit, the
// TxArbiter user-send accounting, and the privacy rule (no coordinates or names in the log). Firmware reading:
// docs/protocol/telemetry-location-request.md (source-based, not verified on hardware).
import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/command_queue.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/remote_request_queue.dart';
import 'package:meshsonar/radio/tools/ask_location.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/telemetry_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

import '../../support/tools_rig.dart';

/// The firmware's LPP GPS record for 40.14725, -82.90461, 268.5 m (LPPDataHelpers.h writeGPS / CayenneLPP addGPS:
/// float x 10000 truncated to int32, 3 bytes big endian each; altitude x 100): 401472, -829046, 26850.
const gpsRecord = [0x01, 0x88, 0x06, 0x20, 0x40, 0xF3, 0x59, 0x8A, 0x00, 0x68, 0xE2];

/// Battery 3.70 V on channel 1 (LPP_VOLTAGE 116, 0.01 V).
const voltRecord = [0x01, 0x74, 0x01, 0x72];

/// MCU temperature 27.5 C (LPP_TEMPERATURE 103, 0.1 C).
const tempRecord = [0x01, 0x67, 0x01, 0x13];

final key = Uint8List.fromList(List.generate(32, (i) => 0xa0 + (i % 16)));
String get keyHex => key.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// PUSH_CODE_TELEMETRY_RESPONSE as the companion firmware frames it (MyMesh.cpp 739-749): [0x8B][0][key prefix x6][LPP],
/// the LPP zero padded to the cipher block.
Uint8List push(List<int> lpp) {
  final body = [0x8B, 0x00, ...key.sublist(0, 6), ...lpp];
  final pad = (16 - (lpp.length + 4) % 16) % 16;
  return Uint8List.fromList([...body, ...List.filled(pad, 0)]);
}

RadioContact sam() => RadioContact(publicKeyHex: keyHex, type: AdvType.chat, outPath: Uint8List(0), name: 'Sam Lee');

void main() {
  group('wire format (from the firmware source)', () {
    test('the request is [39][0 0 0][public key x32]: 36 bytes, the key form the companion answers with SENT', () {
      final f = encodeTelemetryReqFor(key);
      expect(f.length, 36);
      expect(f.sublist(0, 4), [39, 0, 0, 0]);
      expect(f.sublist(4), key);
      expect(Cmd.sendTelemetryReq, 39);
    });

    test('a 0x8B answer with battery, GPS and temperature decodes to the position at 0.0001 degree steps', () {
      final f = push([...voltRecord, ...gpsRecord, ...tempRecord]);
      final t = TelemetryPush.tryParse(f)!;
      expect(t.prefixHex, keyHex.substring(0, 12));
      final r = decodeLpp(t.lpp);
      expect(r.map((x) => x.kind), [LppKind.voltage, LppKind.gps, LppKind.temperature], reason: 'padding is not a reading');
      final g = r[1];
      expect(g.lat, closeTo(40.1472, 1e-9));
      expect(g.lon, closeTo(-82.9046, 1e-9));
      expect(g.altitudeM, closeTo(268.5, 1e-9));
      expect(r[0].value, closeTo(3.70, 1e-9));
      expect(r[2].value, closeTo(27.5, 1e-9));
    });

    test('the parsed frame type is TelemetryResponsePush with the 6-byte prefix', () {
      final f = decodeFrame(push([...voltRecord, ...gpsRecord]));
      expect(f, isA<TelemetryResponsePush>());
      expect((f as TelemetryResponsePush).prefixHex, keyHex.substring(0, 12));
    });

    test('the test encoder matches the firmware bytes for a point exactly on the 0.0001 grid', () {
      expect(lppGps(40.1472, -82.9046, 268.5), gpsRecord);
    });

    test('a southern / western position: negative 24-bit values', () {
      final r = decodeLpp(Uint8List.fromList(lppGps(-33.8688, 151.2093, -5)));
      expect(r.single.lat, closeTo(-33.8688, 1e-9));
      expect(r.single.lon, closeTo(151.2093, 1e-9));
      expect(r.single.altitudeM, closeTo(-5, 1e-9));
    });
  });

  group('pure rules', () {
    test('wait: 30 s direct, 45 s when the radio floods, longer only when the radio estimates more, never past 60 s', () {
      expect(askLocationWait(flood: false, estTimeoutMs: 1800), const Duration(seconds: 30));
      expect(askLocationWait(flood: true, estTimeoutMs: 3000), const Duration(seconds: 45));
      expect(askLocationWait(flood: false, estTimeoutMs: 20000), const Duration(seconds: 43));
      expect(askLocationWait(flood: true, estTimeoutMs: 90000), const Duration(seconds: 60));
    });

    test('0, 0 (GPS on, never a fix) and out-of-range values are not a position', () {
      expect(askedPositionUsable(0, 0), isFalse);
      expect(askedPositionUsable(0.00005, -0.00005), isFalse);
      expect(askedPositionUsable(91, 0), isFalse);
      expect(askedPositionUsable(double.nan, 1), isFalse);
      expect(askedPositionUsable(40.1, -82.9), isTrue);
      expect(askedPositionUsable(0, 12.5), isTrue);
    });

    test('limiter: once per 30 s per contact, others unaffected, clear frees it', () {
      var now = DateTime(2026, 11, 16, 12);
      final l = AskLimiter(clock: () => now);
      expect(l.waitFor('AB'), isNull);
      l.mark('AB');
      expect(l.waitFor('ab'), const Duration(seconds: 30));
      expect(l.waitFor('cd'), isNull);
      now = now.add(const Duration(seconds: 29));
      expect(l.waitFor('ab'), const Duration(seconds: 1));
      now = now.add(const Duration(seconds: 1));
      expect(l.waitFor('ab'), isNull);
      l.mark('ab');
      l.clear('ab');
      expect(l.waitFor('ab'), isNull);
    });

    test('an asked position never prints its coordinates', () {
      final p = MtAskedPosition(keyHex: keyHex, name: 'Sam Lee', lat: 40.1472, lon: -82.9046, at: DateTime(2026));
      expect(p.toString(), isNot(contains('40.1')));
      expect(p.toString(), isNot(contains('Sam')));
    });
  });

  group('hub', () {
    late FakeToolsRadio radio;
    late TxArbiter arbiter;
    late TelemetryTool tool;
    late AskLocationHub hub;
    late List<String> log;
    var now = DateTime(2026, 11, 16, 12);
    DateTime clock() => now;

    setUp(() {
      now = DateTime(2026, 11, 16, 12);
      radio = FakeToolsRadio();
      arbiter = testArbiter(clock: clock);
      tool = TelemetryTool(radio, arbiter, clock: clock, minGap: Duration.zero)..queue = RemoteRequestQueue();
      log = [];
      hub = AskLocationHub(tool, clock: clock, log: log.add);
    });

    void answer(List<int>? lpp, {bool flood = false, Duration after = const Duration(milliseconds: 5)}) {
      radio.onSend = (f) {
        if (lpp != null) Timer(after, () => radio.push(push(lpp)));
        return SentFrame(flood: flood, tag: 7, estTimeoutMs: 1800);
      };
    }

    test('answer with a position: located, the pin callback gets it, the request went at user priority', () async {
      answer([...voltRecord, ...gpsRecord, ...tempRecord]);
      MtAskedPosition? pinned;
      final s = await hub.ask(sam(), onLocated: (p) => pinned = p);
      expect(s.phase, AskPhase.located);
      expect(s.position!.lat, closeTo(40.1472, 1e-9));
      expect(pinned!.lon, closeTo(-82.9046, 1e-9));
      expect(pinned!.name, 'Sam Lee');
      expect(hub.stateOf(keyHex).phase, AskPhase.located);
      expect(radio.sent.single.frame.sublist(0, 4), [39, 0, 0, 0]);
      expect(radio.sent.single.priority, CommandPriority.user);
    });

    test('airtime: recorded by the TxArbiter as a user send (not admin)', () async {
      answer([...voltRecord]);
      final before = arbiter.snapshot().userSends;
      await hub.ask(sam());
      expect(arbiter.snapshot().userSends, before + 1);
    });

    test('answer without a position: noLocation; a 0, 0 GPS record counts as no position', () async {
      answer([...voltRecord, ...tempRecord]);
      expect((await hub.ask(sam())).phase, AskPhase.noLocation);
      now = now.add(const Duration(seconds: 31));
      answer([...voltRecord, 0x01, 0x88, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect((await hub.ask(sam())).phase, AskPhase.noLocation);
    });

    test('no answer: waits the firmware-derived time (30 s direct), then noAnswer', () {
      fakeAsync((fa) {
        answer(null);
        AskState? s;
        hub.ask(sam()).then((v) => s = v);
        fa.elapse(const Duration(seconds: 1));
        expect(hub.stateOf(keyHex).phase, AskPhase.asking);
        fa.elapse(const Duration(seconds: 28));
        expect(s, isNull, reason: 'still waiting at 29 s');
        fa.elapse(const Duration(seconds: 2));
        expect(s!.phase, AskPhase.noAnswer);
      });
    });

    test('no answer on a flooded request waits 45 s', () {
      fakeAsync((fa) {
        answer(null, flood: true);
        AskState? s;
        hub.ask(sam()).then((v) => s = v);
        fa.elapse(const Duration(seconds: 44));
        expect(s, isNull);
        fa.elapse(const Duration(seconds: 2));
        expect(s!.phase, AskPhase.noAnswer);
      });
    });

    test('Cancel ends the wait at once; a late answer is ignored; the 30 s limit stays (the request was on air)', () {
      fakeAsync((fa) {
        answer([...voltRecord, ...gpsRecord], after: const Duration(seconds: 10));
        AskState? s;
        hub.ask(sam()).then((v) => s = v);
        fa.elapse(const Duration(seconds: 2));
        hub.cancel(keyHex);
        fa.flushMicrotasks();
        fa.elapse(const Duration(milliseconds: 10));
        expect(s!.phase, AskPhase.idle);
        fa.elapse(const Duration(seconds: 10));
        expect(hub.stateOf(keyHex).phase, AskPhase.idle, reason: 'the late answer changes nothing');
        expect(hub.retryIn(keyHex), isNotNull);
      });
    });

    test('Cancel after an earlier answer keeps that answer on screen', () async {
      answer([...voltRecord, ...gpsRecord]);
      await hub.ask(sam());
      now = now.add(const Duration(seconds: 31));
      answer(null);
      final f = hub.ask(sam());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      hub.cancel(keyHex);
      expect((await f).phase, AskPhase.located);
    });

    test('rate limit: a second ask inside 30 s sends nothing and changes nothing; after 30 s it goes', () async {
      answer([...voltRecord]);
      await hub.ask(sam());
      expect(radio.sent.length, 1);
      now = now.add(const Duration(seconds: 10));
      final again = await hub.ask(sam());
      expect(again.phase, AskPhase.noLocation, reason: 'unchanged');
      expect(radio.sent.length, 1, reason: 'nothing sent');
      expect(hub.retryIn(keyHex), const Duration(seconds: 20));
      now = now.add(const Duration(seconds: 20));
      expect(hub.retryIn(keyHex), isNull);
      await hub.ask(sam());
      expect(radio.sent.length, 2);
    });

    test('while asking, a second tap does not send a second request', () async {
      answer([...voltRecord], after: const Duration(milliseconds: 50));
      final a = hub.ask(sam());
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(hub.isAsking(keyHex), isTrue);
      await hub.ask(sam());
      await a;
      expect(radio.sent.length, 1);
    });

    test('not on the radio (ERR not found): notOnRadio and no limit (nothing went on air)', () async {
      radio.onSend = (f) => const ErrFrame(ErrCode.notFound);
      expect((await hub.ask(sam())).phase, AskPhase.notOnRadio);
      expect(hub.retryIn(keyHex), isNull);
    });

    test('no radio: notConnected, nothing sent', () async {
      radio.connected = false;
      expect((await hub.ask(sam())).phase, AskPhase.notConnected);
      expect(radio.sent, isEmpty);
    });

    test('privacy: the log never carries a coordinate, a name or the key', () async {
      answer([...voltRecord, ...gpsRecord]);
      await hub.ask(sam());
      now = now.add(const Duration(seconds: 31));
      answer([...voltRecord]);
      await hub.ask(sam());
      expect(log, isNotEmpty);
      for (final l in log) {
        expect(l, isNot(matches(RegExp(r'\d+\.\d+'))), reason: l);
        expect(l, isNot(contains('Sam')), reason: l);
        expect(l, isNot(contains(keyHex.substring(0, 6))), reason: l);
      }
    });
  });

  group('simulated radio (the demo answers all three ways)', () {
    test('Bob answers with his position, Cara without one (demo radio), Ann never answers', () async {
      final rig = await ToolsRig.start(ambient: true);
      final tool = TelemetryTool(rig.tools.radio, rig.tools.arbiter, minGap: Duration.zero);
      final hub = AskLocationHub(tool);
      final people = {for (final c in (await rig.session.getContacts()).contacts) if (c.type == AdvType.chat) c.name: c};
      expect(people.keys, containsAll(['Ann KE8ANN', 'Bob W8BOB', 'Cara N8CRA']));
      final bob = await hub.ask(people['Bob W8BOB']!);
      expect(bob.phase, AskPhase.located);
      expect(bob.position!.lat, closeTo(40.1472, 1e-4));
      expect(bob.position!.lon, closeTo(-82.9046, 1e-4));
      expect((await hub.ask(people['Cara N8CRA']!)).phase, AskPhase.noLocation);
      // Ann's silence: the sim's SENT says flood (no route), so the wait is 45 s of fake-scaled radio time; ask the tool
      // directly with a short wait instead of sleeping through it.
      final quiet = await tool.requestContact(people['Ann KE8ANN']!, waitFor: (_) => const Duration(milliseconds: 300));
      expect(quiet.status, TelemetryStatus.silent);
      final sent = rig.radio.sentFrames.where((f) => f[0] == Cmd.sendTelemetryReq).toList();
      expect(sent.length, 3);
      expect(sent.every((f) => f.length == 36), isTrue);
      hub.dispose();
      await rig.close();
    });

    test('a plain simulated radio (tests) keeps two people: Ann silent, Bob with a position', () async {
      final rig = await ToolsRig.start();
      final people = [for (final c in (await rig.session.getContacts()).contacts) if (c.type == AdvType.chat) c.name];
      expect(people, ['Ann KE8ANN', 'Bob W8BOB']);
      await rig.close();
    });
  });
}
