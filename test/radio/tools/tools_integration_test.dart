// The Tools end to end: real MeshCoreCompanionLink and LinkRadioSession over the simulated radio (which speaks the real
// frames), plus a scripted radio for exact silences and lies.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/rf_thresholds.dart';
import 'package:meshsonar/radio/command_queue.dart';
import 'package:meshsonar/radio/companion_link.dart';
import 'package:meshsonar/radio/inbound.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/advert_decode.dart';
import 'package:meshsonar/radio/tools/advert_tool.dart';
import 'package:meshsonar/radio/tools/discover_tool.dart';
import 'package:meshsonar/radio/tools/lpp.dart';
import 'package:meshsonar/radio/tools/noise_monitor.dart';
import 'package:meshsonar/radio/tools/radio_setup.dart';
import 'package:meshsonar/radio/tools/telemetry_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/radio/tools/trace_tool.dart';

import '../../support/tools_fixtures.dart';
import '../../support/tools_rig.dart';

TraceStop stopOf(dynamic r) => TraceStop(name: r.name as String, keyHex: r.keyHex as String, lat: r.lat as double, lon: r.lon as double);

void main() {
  late ToolsRig rig;

  setUp(() async => rig = await ToolsRig.start());
  tearDown(() => rig.close());

  group('trace', () {
    test('a real chain: sent as one frame, per-hop SNR back, distance from the phone, airtime in the ledger', () async {
      final r = rig.nearest;
      final trace = TraceTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: const Duration(seconds: 2));
      final me = rig.radio.location.positionAt(DateTime.now());
      final before = rig.tools.arbiter.snapshot().totalMsInCapWindow;
      final res = await trace.run([stopOf(r)], hashSize: 2, origin: (lat: me.lat, lon: me.lon));
      expect(res.status, TraceStatus.ok, reason: res.detail);
      expect(res.hops.single.snrDb, isNotNull);
      expect(res.finalSnrDb, isNotNull);
      expect(res.hops.single.distanceKm, closeTo(0.2, 0.15));
      expect(res.totalKm, res.hops.single.distanceKm);
      final frame = rig.radio.sentFrames.lastWhere((f) => f[0] == ToolCmd.sendTracePath);
      expect(frame[9], 1, reason: 'flags: 2-byte hashes');
      expect(frame.sublist(10), r.publicKey.sublist(0, 2));
      expect(rig.tools.arbiter.snapshot().totalMsInCapWindow, greaterThan(before));
      expect(trace.last, same(res));
    });

    test('1-byte and 4-byte hashes work too', () async {
      final r = rig.nearest;
      for (final size in [1, 4]) {
        final trace = TraceTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: const Duration(seconds: 2));
        final res = await trace.run([stopOf(r)], hashSize: size);
        expect(res.status, TraceStatus.ok, reason: '$size: ${res.detail}');
        expect(res.hashSize, size);
      }
    });

    test('a hop that does not exist: the radio says SENT and then nothing, the tool says so in plain words', () async {
      final trace = TraceTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: Duration.zero, maxWait: const Duration(milliseconds: 300));
      final res = await trace.run([TraceStop(name: 'Ghost', keyHex: 'aa' * 32)], hashSize: 1);
      expect(res.status, TraceStatus.silent);
      expect(res.detail, contains('No answer'));
      expect(res.detail, contains('may not exist'));
      expect(res.estTimeoutMs, greaterThan(0));
      expect(res.hops, isEmpty);
    });

    test('a second trace right away waits (cooldown), and an empty or oversized chain is refused without any frame', () async {
      final r = rig.nearest;
      final trace = TraceTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: const Duration(seconds: 2));
      await trace.run([stopOf(r)]);
      final n = rig.radio.sentFrames.where((f) => f[0] == ToolCmd.sendTracePath).length;
      final again = await trace.run([stopOf(r)]);
      expect(again.status, TraceStatus.tooSoon);
      expect(trace.cooldown(), isNotNull);
      expect((await trace.run(const [])).status, TraceStatus.invalid);
      expect((await trace.run(List.filled(9, stopOf(r)))).status, TraceStatus.invalid);
      expect(rig.radio.sentFrames.where((f) => f[0] == ToolCmd.sendTracePath).length, n);
    });

    test('saved traces keep, survive JSON, and compare hop by hop', () async {
      final r = rig.nearest;
      final trace = TraceTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: const Duration(seconds: 2), minGap: Duration.zero);
      final a = await trace.run([stopOf(r)]);
      await trace.saveLast();
      final b = await trace.run([stopOf(r)]);
      expect(trace.store.items.length, 1);
      final back = TraceResult.fromJson(trace.store.items.single.toJson());
      expect(back.hops.single.stop.name, r.name);
      expect(back.finalSnrDb, a.finalSnrDb);
      final cmp = compareTraces(a, b);
      expect(cmp.sameChain, isTrue);
      expect(cmp.rows.single.snrA, a.hops.single.snrDb);
      expect(cmp.deltas.single, b.hops.single.snrDb! - a.hops.single.snrDb!);
    });

    test('1-byte hash shared with another known repeater is flagged', () {
      final a = TraceStop(name: 'A', keyHex: 'df${'01' * 31}');
      final others = [
        RadioContact(publicKeyHex: 'df${'02' * 31}', type: AdvType.repeater, outPath: Uint8List(0), name: 'Other DF'),
        RadioContact(publicKeyHex: 'ab${'02' * 31}', type: AdvType.repeater, outPath: Uint8List(0), name: 'Not DF'),
        RadioContact(publicKeyHex: 'df${'03' * 31}', type: AdvType.chat, outPath: Uint8List(0), name: 'A person'),
      ];
      final amb = findAmbiguousHops([a], 1, others);
      expect(amb.single.otherNames, ['Other DF']);
      expect(findAmbiguousHops([a], 2, others), isEmpty, reason: 'two bytes tell them apart');
    });

    test('scripted radio: ERR means refused, timeout means silent command, disconnect means notConnected', () async {
      final fake = FakeToolsRadio()..onSend = (f) => const ErrFrame(ErrCode.illegalArg);
      final t = TraceTool(fake, testArbiter(), waitSlack: Duration.zero, minWait: Duration.zero, minGap: Duration.zero);
      final stop = TraceStop(name: 'R', keyHex: 'df${'01' * 31}');
      expect((await t.run([stop])).status, TraceStatus.refused);
      fake.onSend = (f) => throw TimeoutException('x');
      expect((await t.run([stop])).status, TraceStatus.silent);
      fake.connected = false;
      expect((await t.run([stop])).status, TraceStatus.notConnected);
    });

    test('scripted radio: the reply from the live run is matched by tag and mapped to the hop', () async {
      final fake = FakeToolsRadio();
      late int tag;
      fake.onSend = (f) {
        tag = ByteData.sublistView(f).getUint32(1, Endian.little);
        scheduleMicrotask(() => fake.push(encodeTraceDataPush(tag, [0xdf, 0x01], [1.0], 3.25, hashSize: 2)));
        return const SentFrame(flood: false, tag: 0, estTimeoutMs: 2692);
      };
      final t = TraceTool(fake, testArbiter(), waitSlack: Duration.zero, minWait: const Duration(seconds: 1));
      final res = await t.run([TraceStop(name: 'INNO-OB-2', keyHex: '$repeaterKeyPrefixHex${'00' * 24}')]);
      expect(res.ok, isTrue);
      expect(res.hops.single.snrDb, 1.0);
      expect(res.finalSnrDb, 3.25);
      expect(res.estTimeoutMs, 2692);
    });
  });

  group('discover', () {
    test('a scan hears the nearest repeater with both SNRs, sorted by the weaker direction; the radio gets one control frame', () async {
      final d = DiscoverTool(rig.tools.radio, rig.tools.arbiter, listenFor: const Duration(milliseconds: 600));
      d.setContacts((await rig.session.getContacts()).contacts);
      final out = await d.scan();
      expect(d.status, DiscoverStatus.done);
      expect(out, isNotEmpty);
      final n = out.first;
      expect(n.nodeType, AdvType.repeater);
      expect(n.snrHeardDb, isNot(equals(n.snrTheyHeardDb)));
      expect(n.inContacts, isTrue);
      expect(n.knownName, isNotNull);
      for (var i = 1; i < out.length; i++) {
        expect(out[i - 1].weakestSnrDb, greaterThanOrEqualTo(out[i].weakestSnrDb));
      }
      final f = rig.radio.sentFrames.where((f) => f[0] == Cmd.sendControlData).single;
      expect(f[1], 0x80);
      expect(f[2], 0x1C, reason: 'repeaters, rooms, sensors');
    });

    test('four scans in two minutes, the fifth is a cooldown, not an error, and sends nothing', () async {
      var now = DateTime(2026, 11, 1, 12);
      final d = DiscoverTool(rig.tools.radio, rig.tools.arbiter, clock: () => now, listenFor: const Duration(milliseconds: 50));
      for (var i = 0; i < 4; i++) {
        await d.scan();
        now = now.add(const Duration(seconds: 10));
      }
      expect(d.requestsLeft, 0);
      final frames = rig.radio.sentFrames.where((f) => f[0] == Cmd.sendControlData).length;
      expect(frames, 4);
      await d.scan();
      expect(d.status, DiscoverStatus.cooldown);
      expect(d.message, contains('Next scan in'));
      expect(d.cooldown()!.inSeconds, inInclusiveRange(70, 90));
      expect(rig.radio.sentFrames.where((f) => f[0] == Cmd.sendControlData).length, 4);
      now = now.add(const Duration(seconds: 100));
      expect(d.cooldown(), isNull, reason: 'the first scan is more than 120 s old');
      await d.scan();
      expect(d.status, DiscoverStatus.done);
    });

    test('scripted: both answer lengths, tag filtering, Add to contacts only with a full key', () async {
      final fake = FakeToolsRadio();
      late int tag;
      fake.onSend = (f) {
        tag = ByteData.sublistView(f).getUint32(3, Endian.little); // [55][0x80][filter][tag...]
        return const OkFrame();
      };
      final d = DiscoverTool(fake, testArbiter(), listenFor: const Duration(milliseconds: 200));
      final scan = d.scan();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      DiscoverResponse mk(int t, int n) => DiscoverResponse(2, -5.25, t, Uint8List(n)..[0] = 0xdf);
      Uint8List payload(DiscoverResponse r) => Uint8List.fromList([0x90 | r.nodeType, (r.remoteSnrDb * 4).round() & 0xff, r.tag & 255, (r.tag >> 8) & 255, (r.tag >> 16) & 255, (r.tag >> 24) & 255, ...r.publicKey]);
      fake.control(ControlPacket(DateTime.now(), -4.25, -125, 0, payload(mk(tag, 32))));
      fake.control(ControlPacket(DateTime.now(), -1.0, -110, 0, payload(DiscoverResponse(2, 3.0, tag, Uint8List(8)..[0] = 0xab))));
      fake.control(ControlPacket(DateTime.now(), 9, -90, 0, payload(mk(tag + 1, 32)))); // someone else's scan
      final out = await scan;
      expect(out.length, 2);
      expect(out.first.hasFullKey, isFalse, reason: '-1.0/3.0 beats -4.25/-5.25 so the prefix-only node sorts first');
      expect(await d.addToContacts(out.first), contains('cannot be added'));
      expect(fake.added, isEmpty);
      expect(await d.addToContacts(out.last, name: 'Hill repeater'), isNull);
      expect(fake.added.single.name, 'Hill repeater');
      expect(fake.added.single.type, AdvType.repeater);
      expect(fake.added.single.outPathLen, 0xFF);
      expect(d.results.last.inContacts, isTrue);
    });

    test('nothing answers: a plain message, not an error', () async {
      final d = DiscoverTool(FakeToolsRadio(), testArbiter(), listenFor: const Duration(milliseconds: 20));
      expect(await d.scan(), isEmpty);
      expect(d.status, DiscoverStatus.done);
      expect(d.message, contains('Nothing answered'));
    });

    test('old firmware: ERR unsupported becomes a sentence', () async {
      final fake = FakeToolsRadio()..onSend = (f) => const ErrFrame(ErrCode.unsupportedCmd);
      final d = DiscoverTool(fake, testArbiter(), listenFor: const Duration(milliseconds: 20));
      await d.scan();
      expect(d.status, DiscoverStatus.refused);
      expect(d.message, contains('needs version 8'));
    });
  });

  group('adverts', () {
    test('zero-hop is allowed every 30 s, flood every 5 min; the cooldown is a visible wait, not an error', () async {
      var now = DateTime(2026, 11, 1, 12);
      final a = AdvertTool(rig.tools.radio, rig.tools.arbiter, clock: () => now);
      expect((await a.send(flood: false)).ok, isTrue);
      expect(rig.radio.sentAdverts, [false]);
      final again = await a.send(flood: false);
      expect(again.status, AdvertSendStatus.cooldown);
      expect(again.wait!.inSeconds, inInclusiveRange(25, 30));
      expect((await a.send(flood: true)).ok, isTrue, reason: 'separate cooldowns');
      now = now.add(const Duration(seconds: 31));
      expect((await a.send(flood: false)).ok, isTrue);
      expect((await a.send(flood: true)).status, AdvertSendStatus.cooldown);
      now = now.add(const Duration(minutes: 5));
      expect((await a.send(flood: true)).ok, isTrue);
      expect(rig.radio.sentAdverts, [false, true, false, true]);
    });

    test('a send is airtime in the ledger, class advert', () async {
      final a = AdvertTool(rig.tools.radio, rig.tools.arbiter);
      final before = rig.tools.arbiter.snapshot().totalMsInCapWindow;
      await a.send(flood: true);
      expect(rig.tools.arbiter.snapshot().totalMsInCapWindow - before, closeTo(a.estimateAirtimeMs(), 1));
    });

    test('hearing: name, type, position, path, SNR, first/last seen, scope "in scope: #cmh", contact flag from the push', () async {
      final a = AdvertTool(rig.tools.radio, rig.tools.arbiter)..scopeNames = ['#cmh']..start();
      rig.radio.injectAdvertHeard('Hill Top', type: AdvType.repeater, lat: 40.1, lon: -82.9, pathHashes: [0xaa], scope: '#cmh', snrDb: 5.5);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      rig.radio.injectAdvertHeard('Hill Top', type: AdvType.repeater, lat: 40.1, lon: -82.9, pathHashes: [0xaa, 0xbb], scope: '#cmh', snrDb: 7.0);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(a.count, 1);
      final h = a.heard.single;
      expect(h.name, 'Hill Top');
      expect(h.nodeType, AdvType.repeater);
      expect(h.lat, closeTo(40.1, 1e-6));
      expect(h.path, ['aa', 'bb']);
      expect(h.hops, 2);
      expect(h.snrDb, 7.0);
      expect(h.bestSnrDb, 7.0);
      expect(h.count, 2);
      expect(h.scope.label, 'in scope: #cmh');
      expect(h.inContacts, isTrue, reason: 'the radio added it (NEW_ADVERT) and pushed ADVERT for the repeat');
      expect(h.lastSeen.isAfter(h.firstSeen) || h.lastSeen == h.firstSeen, isTrue);
      a.scopeNames = ['#other'];
      expect(a.heard.single.scope.label, 'scoped to another region');
      await a.dispose();
    });

    test('an unscoped advert says unscoped; non-adverts are ignored', () async {
      final a = AdvertTool(rig.tools.radio, rig.tools.arbiter)..scopeNames = ['#cmh'];
      a.hear(advertZeroHop, snrDb: -2.5, rssiDbm: -122);
      expect(a.heard.single.scope.label, 'unscoped');
      expect(a.heard.single.name, repeaterName);
      a.hear(Uint8List.fromList([0x15, 0x00, 1, 2, 3]));
      expect(a.count, 1);
    });

    test('the book is bounded and forgets the node not heard for longest', () {
      final a = AdvertTool(FakeToolsRadio(), testArbiter(), capacity: 3);
      var t = DateTime(2026, 11, 1, 12);
      for (final n in ['a', 'b', 'c', 'd']) {
        final key = Uint8List(32)..[0] = n.codeUnitAt(0);
        a.hear(
            MeshPacket(header: makeHeader(RouteType.flood, PayloadType.advert), pathLenByte: 0, path: const [], payload: buildAdvertPayload(key, 1000, 2, n)).toBytes(),
            at: t);
        t = t.add(const Duration(seconds: 1));
      }
      expect(a.count, 3);
      expect(a.heard.map((e) => e.name), ['d', 'c', 'b']);
    });
  });

  group('noise floor and health', () {
    test('samples the radio, min/avg/max, "Quiet" for a -112 dBm floor, the website thresholds, own airtime from the ledger', () async {
      final m = NoiseMonitor(rig.tools.radio, rig.tools.arbiter);
      for (var i = 0; i < 4; i++) {
        expect(await m.sampleNow(), isNotNull);
      }
      final s = m.stats!;
      expect(s.count, 4);
      expect(s.min, lessThanOrEqualTo(s.avg));
      expect(s.avg, lessThanOrEqualTo(s.max));
      expect(m.verdict, NoiseVerdict.normal);
      expect(m.verdictWord, 'Quiet');
      expect(m.interpretation, noiseVerdictText(NoiseVerdict.normal));
      rig.tools.arbiter.admitUserSend(300);
      expect(m.ownAirtime.lastHourMs, greaterThanOrEqualTo(300));
      expect(m.ownAirtime.capMs, 36000, reason: '1% of an hour');
      expect(m.core.queueLen, 0, reason: 'the first sample also read the core counters');
    });

    test('reads at the lowest command priority and skips while a ping is in flight', () async {
      var pinging = true;
      final fake = FakeToolsRadio()..stats = () => const RadioStatsFrame(-95, -100, 1.0, 1, 2);
      final m = NoiseMonitor(fake, testArbiter(), busy: () => pinging);
      expect(await m.sampleNow(), isNull);
      expect(m.samples, isEmpty);
      pinging = false;
      expect(await m.sampleNow(), isNotNull);
      expect(m.verdictWord, 'Noisy', reason: '-95 is above the -100 interference line');
      expect(m.interpretation, contains('likely interference'));
    });

    test('noise floor 0 is "not measured", never 0 dBm', () async {
      final fake = FakeToolsRadio()..stats = () => const RadioStatsFrame(0, 0, 0, 0, 0);
      final m = NoiseMonitor(fake, testArbiter());
      await m.sampleNow();
      expect(m.samples.single.noiseDbm, isNull);
      expect(m.samples.single.lastRssiDbm, isNull);
      expect(m.stats, isNull);
      expect(m.verdict, isNull);
    });

    test('spikes: a jump above the median and a crossing of -100', () async {
      var v = -112;
      final fake = FakeToolsRadio()..stats = () => RadioStatsFrame(v, -100, 1, 0, 0);
      final m = NoiseMonitor(fake, testArbiter());
      for (var i = 0; i < 12; i++) {
        v = i == 7 ? -99 : -112 + (i % 2);
        await m.sampleNow();
      }
      final sp = m.spikes();
      expect(sp.length, 1);
      expect(sp.single.noiseDbm, -99);
    });

    test('ring is bounded', () async {
      final fake = FakeToolsRadio()..stats = () => const RadioStatsFrame(-110, -100, 1, 0, 0);
      final m = NoiseMonitor(fake, testArbiter(), capacity: 5);
      for (var i = 0; i < 9; i++) {
        await m.sampleNow();
      }
      expect(m.samples.length, 5);
    });

    test('firmware without stats: three misses and the monitor says unsupported', () async {
      final r2 = await ToolsRig.start(noiseFloorDbm: null);
      addTearDown(r2.close);
      final m = NoiseMonitor(r2.tools.radio, r2.tools.arbiter);
      for (var i = 0; i < 4; i++) {
        await m.sampleNow();
      }
      expect(m.unsupported, isTrue);
      expect(m.samples, isEmpty);
    });

    test('radio-reported airtime since the first sample', () async {
      var tx = 10;
      final fake = FakeToolsRadio()..stats = () => RadioStatsFrame(-110, -100, 1, tx += 5, tx * 2);
      final m = NoiseMonitor(fake, testArbiter());
      await m.sampleNow();
      await m.sampleNow();
      await m.sampleNow();
      expect(m.radioAirSinceFirst.txSecs, 10);
    });
  });

  group('telemetry', () {
    test('a repeater answers with battery, temperature and its position; the key goes in the frame; airtime counted', () async {
      final t = TelemetryTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: const Duration(seconds: 2));
      final r = rig.nearest;
      final c = RadioContact(publicKeyHex: r.keyHex, type: AdvType.repeater, outPath: Uint8List(0), name: r.name);
      final res = await t.requestContact(c);
      expect(res.status, TelemetryStatus.ok, reason: res.detail);
      expect(res.battery!.value, inInclusiveRange(3.8, 4.3));
      expect(res.temperature, isNotNull);
      expect(res.position!.lat, closeTo(r.lat, 1e-3));
      final f = rig.radio.sentFrames.lastWhere((f) => f[0] == Cmd.sendTelemetryReq);
      expect(f.length, 36);
      expect(f.sublist(4), r.publicKey);
    });

    test('a contact the radio does not have: say so; a contact that stays silent: say so with the wait', () async {
      final t = TelemetryTool(rig.tools.radio, rig.tools.arbiter, waitSlack: Duration.zero, minWait: Duration.zero, maxWait: const Duration(milliseconds: 300), minGap: Duration.zero);
      final nobody = RadioContact(publicKeyHex: 'cd' * 32, type: AdvType.repeater, outPath: Uint8List(0), name: 'Nobody');
      final a = await t.requestContact(nobody);
      expect(a.status, TelemetryStatus.noContact);
      expect(a.detail, contains('Add it first'));
      final person = (await rig.session.getContacts()).contacts.firstWhere((c) => c.type == AdvType.chat);
      final b = await t.requestContact(person);
      expect(b.status, TelemetryStatus.silent);
      expect(b.detail, contains('out of range or asleep'));
    });

    test('this radio: voltage and MCU temperature from the self request', () async {
      final t = TelemetryTool(rig.tools.radio, rig.tools.arbiter);
      final r = await t.requestSelf();
      expect(r.ok, isTrue);
      expect(r.isSelf, isTrue);
      expect(r.battery!.value, inInclusiveRange(3.4, 4.2));
      expect(r.temperature!.value, inInclusiveRange(20, 40));
    });

    test('scripted: the answer is matched by key prefix; another node\'s answer is ignored; a quick repeat waits', () async {
      final fake = FakeToolsRadio();
      fake.onSend = (f) {
        scheduleMicrotask(() {
          fake.push(encodeTelemetryResponsePush(hex('aabbccddeeff'), [...lppVoltage(1.0)])); // someone else
          fake.push(encodeTelemetryResponsePush(hex('df0136c20a99'), repeaterTelemetryLpp));
        });
        return const SentFrame(flood: false, tag: 1, estTimeoutMs: 1782);
      };
      final t = TelemetryTool(fake, testArbiter(), waitSlack: Duration.zero, minWait: const Duration(seconds: 1));
      final c = RadioContact(publicKeyHex: '$repeaterKeyPrefixHex${'00' * 24}', type: AdvType.repeater, outPath: Uint8List(0), name: repeaterName);
      final res = await t.requestContact(c);
      expect(res.battery!.value, closeTo(3.86, 1e-9));
      expect(res.temperature!.value, closeTo(45.0, 1e-9));
      expect((await t.requestContact(c)).status, TelemetryStatus.tooSoon);
    });
  });

  group('radio setup', () {
    test('read gives the radio\'s real settings', () async {
      final c = (await rig.tools.setup.read())!;
      expect(c.name, 'MeshSonar Sim');
      expect(c.params.label, '910.525 MHz, 62.5 kHz, SF7, CR5');
      expect(c.txDbm, 22);
      expect(c.maxTxDbm, 22);
      expect(c.lat, isNull);
      expect(c.manualAdd, isFalse);
    });

    test('name: validation first (nothing sent), then written and read back', () async {
      final s = rig.tools.setup;
      await s.read();
      final n = rig.radio.sentFrames.length;
      for (final bad in ['', '   ', 'Ann: base', 'x' * 32, 'a\u0001b']) {
        final r = await s.setName(bad);
        expect(r.ok, isFalse, reason: bad);
      }
      expect(rig.radio.sentFrames.length, n, reason: 'not a byte left the phone');
      final ok = await s.setName('KE4BFI Mobile');
      expect(ok.ok, isTrue, reason: ok.message);
      expect(rig.radio.advertName, 'KE4BFI Mobile');
      expect(s.config!.name, 'KE4BFI Mobile');
      expect(ok.message, startsWith('Saved: the radio reports'));
    });

    test('position: ranges, and (0,0) is refused because a radio reads it as none', () async {
      final s = rig.tools.setup;
      await s.read();
      expect((await s.setPosition(91, 0)).message, contains('Latitude'));
      expect((await s.setPosition(10, 181)).message, contains('Longitude'));
      expect((await s.setPosition(0, 0)).message, contains('no position'));
      final ok = await s.setPosition(39.9612, -82.9988);
      expect(ok.ok, isTrue, reason: ok.message);
      expect(rig.radio.advertPosition.lat, closeTo(39.9612, 1e-6));
      expect(s.config!.lat, closeTo(39.9612, 1e-6));
    });

    test('TX power stays inside -9 .. the radio\'s own maximum (from SELF_INFO)', () async {
      final s = rig.tools.setup;
      await s.read();
      expect((await s.setTxPower(23)).message, contains('hardware limit is 22'));
      expect((await s.setTxPower(-10)).ok, isFalse);
      expect((await s.setTxPower(15)).ok, isTrue);
      expect(rig.radio.txPowerDbm, 15);
    });

    test('behaviour flags are written together and the telemetry sharing the radio had is kept', () async {
      final s = rig.tools.setup;
      await s.read();
      final r = await s.setBehaviour(manualAdd: true, multiAcks: 1, advertLocPolicy: 1);
      expect(r.ok, isTrue, reason: r.message);
      final f = rig.radio.sentFrames.lastWhere((f) => f[0] == Cmd.setOtherParams);
      expect(f.sublist(1), [1, 0, 1, 1]);
      expect(s.config!.manualAdd, isTrue);
      expect(s.config!.advertSharesPosition, isTrue);
      expect((await s.setBehaviour(multiAcks: 5)).ok, isFalse);
    });

    test('radio parameters: applied, read back, undone to the exact previous values', () async {
      final s = rig.tools.setup;
      await s.read();
      const swoh = RadioParams(910525, 250000, 10, 5);
      expect(swoh.label, '910.525 MHz, 250 kHz, SF10, CR5');
      final r = await s.applyRadioParams(swoh);
      expect(r.ok, isTrue, reason: r.message);
      expect(rig.radio.radioParams, (freqKhz: 910525, bwHz: 250000, sf: 10, cr: 5));
      expect(s.canUndo, isTrue);
      final u = await s.undo();
      expect(u.ok, isTrue, reason: u.message);
      expect(rig.radio.radioParams, (freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5));
      expect(s.canUndo, isFalse);
      expect((await s.undo()).message, 'Nothing to undo.');
    });

    test('radio parameters outside what the firmware accepts never leave the phone', () async {
      final s = rig.tools.setup;
      await s.read();
      final n = rig.radio.sentFrames.length;
      for (final p in const [RadioParams(100000, 62500, 7, 5), RadioParams(910525, 600000, 7, 5), RadioParams(910525, 62500, 4, 5), RadioParams(910525, 62500, 7, 9)]) {
        expect((await s.applyRadioParams(p)).ok, isFalse);
      }
      expect(rig.radio.sentFrames.length, n);
    });

    test('a radio that says OK but reads back different is reported, never "saved"', () async {
      final fake = FakeToolsRadio()
        ..selfInfo = SelfInfoFrame(advType: 1, txPowerDbm: 22, maxTxPowerDbm: 22, publicKey: Uint8List(32), advLat: 0, advLon: 0, freqKhz: 910525, bwHz: 62500, sf: 7, cr: 5, name: 'R');
      final s = RadioSetupTool(fake);
      await s.read();
      final r = await s.applyRadioParams(const RadioParams(915800, 250000, 10, 5));
      expect(r.ok, isFalse);
      expect(r.mismatches, ['radio parameters']);
      expect(r.message, contains('reads back differently'));
      expect(s.canUndo, isFalse);
    });

    test('RadioParams.matches tolerates the float rounding the radio does (1 kHz, 50 Hz)', () {
      expect(const RadioParams(910525, 62500, 7, 5).matches(const RadioParams(910524, 62450, 7, 5)), isTrue);
      expect(const RadioParams(910525, 62500, 7, 5).matches(const RadioParams(910530, 62500, 7, 5)), isFalse);
    });
  });

  group('arbiter interplay: tool traffic never starves chat or pings', () {
    test('a user message queued behind tool reads goes out before them; a ping beats discovery and stats', () async {
      final link = rig.link;
      final session = rig.session;
      await session.ensureChannel('#wardriving');
      final mark = rig.radio.sentFrames.length;
      // all queued in one tick: the queue picks by class, not by arrival
      final stats = link.radioStatsAt(CommandPriority.discovery);
      final disc = link.sendToolCommand(encodeSendControlData(encodeDiscoverRequestPayload(9)), priority: CommandPriority.discovery);
      final ping = link.sendChannelFrame(1, 'MS:aaaaaaaaaa', priority: CommandPriority.ping);
      final msg = session.sendChannelMessage(0, 'hello');
      await Future.wait<Object?>([stats, disc, ping, msg]);
      final codes = rig.radio.sentFrames.skip(mark).map((f) => f[0]).toList();
      expect(codes.first, Cmd.sendChannelTxtMsg, reason: 'the user message first');
      expect(codes[1], Cmd.sendChannelTxtMsg, reason: 'then the ping');
      expect(codes.sublist(2), containsAll([Cmd.getStats, Cmd.sendControlData]));
      final firstMsgText = String.fromCharCodes(rig.radio.sentFrames.skip(mark).first.sublist(7));
      expect(firstMsgText, 'hello');
    });

    test('twenty queued noise reads do not hold up a message sent while they run', () async {
      final slow = await ToolsRig.start(timeScale: 1); // a reply takes 5 ms, so 20 reads take about 100 ms
      addTearDown(slow.close);
      final reads = [for (var i = 0; i < 20; i++) slow.link.radioStatsAt(CommandPriority.discovery)];
      while (slow.radio.sentFrames.where((f) => f[0] == Cmd.getStats).length < 3) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final r = await slow.session.sendChannelMessage(0, 'urgent');
      expect(r.isAccepted, isTrue);
      await Future.wait(reads);
      final order = slow.radio.sentFrames.map((f) => f[0]).toList();
      final msgAt = order.indexOf(Cmd.sendChannelTxtMsg);
      final lastStats = order.lastIndexOf(Cmd.getStats);
      expect(msgAt, greaterThan(0));
      expect(msgAt, lessThan(lastStats - 5), reason: 'the message jumped the queue of reads');
    });
  });

  group('session wiring', () {
    test('tools exist on a MeshCore link, are one instance, and their ledger is the session arbiter', () {
      expect(rig.session.tools, isNotNull);
      expect(rig.session.tools, same(rig.session.tools));
      expect(rig.tools.arbiter, same(rig.session.arbiter));
      expect(rig.tools.connected, isTrue);
    });

    test('pushes reach the tools: raw push stream carries trace data but not the RX log', () async {
      final seen = <int>[];
      final sub = rig.link.rawPushes.listen((f) => seen.add(f[0]));
      rig.radio.injectChatter('Ann', 'hi');
      rig.radio.injectAdvertHeard('Hill', lat: 40, lon: -82);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sub.cancel();
      expect(seen, isNot(contains(Push.logRxData)));
      expect(seen, contains(Push.newAdvert));
    });
  });
}
