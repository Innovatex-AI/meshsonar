// Ping / trace / discovery result mapping, including the no-reply states.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/path_tools.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/tools/ping_tool.dart';
import 'package:meshsonar/radio/tools/tool_frames.dart';
import 'package:meshsonar/radio/tools/trace_tool.dart';

import '../../support/tools_rig.dart';

final key = 'ab' * 32;
const fast = Duration(milliseconds: 150);

PingTool toolFor(FakeToolsRadio r) {
  final arb = testArbiter();
  final trace = TraceTool(r, arb, minGap: Duration.zero, waitSlack: Duration.zero, minWait: fast, maxWait: fast);
  return PingTool(r, arb, trace, waitSlack: Duration.zero, minWait: fast, maxWait: fast);
}

void main() {
  group('frames', () {
    test('CMD 52 is [52][0][key]; 0x8D parses out and back routes; trailing bytes are ignored', () {
      expect(encodePathDiscoveryReq(fromHex(key)), [52, 0, ...fromHex(key)]);
      final push = encodePathDiscoveryPush(fromHex(key), 0x42, [1, 2, 3, 4], 0x01, [9], );
      final p = PathDiscoveryPush.tryParse(Uint8List.fromList([...push, 0xEE]))!;
      expect(p.prefixHex, key.substring(0, 12));
      expect(decodePath(p.outPathLen, p.outPath)!.hexHops, ['0102', '0304']);
      expect(decodePath(p.inPathLen, p.inPath)!.hexHops, ['09']);
    });

    test('a short or inconsistent 0x8D is ignored', () {
      expect(PathDiscoveryPush.tryParse(Uint8List.fromList([0x8D, 0, 1, 2, 3, 4, 5, 6])), isNull);
      expect(PathDiscoveryPush.tryParse(Uint8List.fromList([0x8D, 0, 1, 2, 3, 4, 5, 6, 0x03, 1, 2])), isNull);
      expect(PathDiscoveryPush.tryParse(Uint8List.fromList([0x8E, 0, 1, 2, 3, 4, 5, 6, 0, 0])), isNull);
    });
  });

  group('discovery (a person)', () {
    test('answer: route out and back, round trip measured', () async {
      final r = FakeToolsRadio();
      r.onSend = (f) {
        expect(f[0], 52);
        Timer(const Duration(milliseconds: 40), () => r.push(encodePathDiscoveryPush(fromHex(key), 1, [0xa1], 2, [0xa1, 0xb2])));
        return const SentFrame(flood: true, tag: 1, estTimeoutMs: 100);
      };
      final res = await toolFor(r).discover(key);
      expect(res.status, PingStatus.ok);
      expect(res.kind, PingMethod.discovery);
      expect(res.outRoute!.hexHops, ['a1']);
      expect(res.backRoute!.hexHops, ['a1', 'b2']);
      expect(res.rttMs, greaterThanOrEqualTo(30));
      expect(res.failReason, isNull);
    });

    test('an answer for another contact does not count: no reply', () async {
      final r = FakeToolsRadio();
      r.onSend = (f) {
        Timer(const Duration(milliseconds: 20), () => r.push(encodePathDiscoveryPush(fromHex('cd' * 32), 0, [], 0, [])));
        return const SentFrame(flood: true, tag: 1, estTimeoutMs: 100);
      };
      final res = await toolFor(r).discover(key);
      expect(res.status, PingStatus.noReply);
      expect(res.failReason, 'noReply');
      expect(res.rttMs, isNull);
      expect(res.waitedMs, isNotNull);
    });

    test('ERR 1 means the firmware cannot; ERR 2 means the radio lacks the contact; no radio', () async {
      final r = FakeToolsRadio();
      r.onSend = (f) => ErrFrame(ErrCode.unsupportedCmd);
      expect((await toolFor(r).discover(key)).status, PingStatus.unsupported);
      r.onSend = (f) => ErrFrame(ErrCode.notFound);
      expect((await toolFor(r).discover(key)).status, PingStatus.refused);
      r.connected = false;
      expect((await toolFor(r).discover(key)).status, PingStatus.notConnected);
    });

    test('two at once: the second is told to wait', () async {
      final r = FakeToolsRadio();
      r.onSend = (f) => const SentFrame(flood: true, tag: 1, estTimeoutMs: 100);
      final t = toolFor(r);
      final first = t.discover(key);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect((await t.discover(key)).status, PingStatus.tooSoon);
      expect((await first).status, PingStatus.noReply);
    });
  });

  group('mapping a trace', () {
    TraceResult tr(TraceStatus s, {List<double> snr = const [], Duration? took}) => TraceResult(
        id: '1',
        at: DateTime(2026, 11, 3),
        status: s,
        hashSize: 1,
        hops: [for (var i = 0; i < snr.length; i++) TraceHopResult(stop: TraceStop(name: 'H$i', keyHex: 'a$i' * 32), hashHex: 'a$i', snrDb: snr[i])],
        finalSnrDb: 3,
        elapsed: took);

    test('every trace status has a ping status', () {
      final expected = {
        TraceStatus.ok: PingStatus.ok,
        TraceStatus.silent: PingStatus.noReply,
        TraceStatus.refused: PingStatus.refused,
        TraceStatus.notConnected: PingStatus.notConnected,
        TraceStatus.tooSoon: PingStatus.tooSoon,
        TraceStatus.invalid: PingStatus.invalid,
      };
      for (final e in expected.entries) {
        expect(pingFromTrace(tr(e.key), kind: PingMethod.trace).status, e.value, reason: '${e.key}');
      }
    });

    test('ok carries per-hop SNR, names, round trip and the route', () {
      final route = PathRoute.fromHex(['a1']);
      final p = pingFromTrace(tr(TraceStatus.ok, snr: [7.5, 1.0], took: const Duration(milliseconds: 1800)), kind: PingMethod.trace, route: route);
      expect(p.hopSnrDb, [7.5, 1.0]);
      expect(p.hopNames, ['H0', 'H1']);
      expect(p.rttMs, 1800);
      expect(p.outRoute, route);
      expect(p.backRoute, route.reversed);
      expect(p.repeaters, 1);
    });

    test('noReply has no round trip', () {
      final p = pingFromTrace(tr(TraceStatus.silent, took: const Duration(seconds: 12)), kind: PingMethod.zeroHop);
      expect(p.status, PingStatus.noReply);
      expect(p.rttMs, isNull);
      expect(p.ok, isFalse);
    });
  });

  group('trace ping (repeater, room, sensor)', () {
    test('the saved route plus the node go out as one trace; zero-hop sends only the node', () async {
      final r = FakeToolsRadio();
      final sent = <Uint8List>[];
      r.onSend = (f) {
        sent.add(f);
        return const SentFrame(flood: false, tag: 1, estTimeoutMs: 100);
      };
      final t = toolFor(r);
      final withRoute = await t.trace(keyHex: key, name: 'Hill', route: PathRoute.fromHex(['a1', 'b2']));
      expect(withRoute.kind, PingMethod.trace);
      expect(sent.last.sublist(10), [0xa1, 0xb2, 0xab]);
      expect(sent.last[9], 0, reason: '1-byte hashes');
      final zero = await t.trace(keyHex: key, name: 'Hill', route: PathRoute.fromHex(['a1']), directOnly: true, hashSize: 2);
      expect(zero.kind, PingMethod.zeroHop);
      expect(sent.last.sublist(10), [0xab, 0xab]);
      expect(sent.last[9], 1, reason: '2-byte hashes');
      expect(zero.status, PingStatus.noReply, reason: 'nothing answered the scripted radio');
    });
  });
}
