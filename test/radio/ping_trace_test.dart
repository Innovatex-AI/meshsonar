// The per-ping debug trace (engine.onTrace -> trace.jsonl beside the drive): every frame the radio reported around a ping,
// with its arrival time and the reason it did or did not count. Plus the frame classifier behind it.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/crypto.dart';
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/ping_gate.dart';
import 'package:meshsonar/radio/wardrive_engine.dart';

import '../support/replay_radio.dart';

MeshPacket grp(List<int> secret, int ts, String sender, String text, List<int> path, {int route = RouteType.flood, int type = PayloadType.grpTxt}) {
  final payload = buildGroupTextPayload(secret, ts, sender, text);
  return MeshPacket(
      header: makeHeader(route, type), pathLenByte: encodePathLen(1, path.length), path: [for (final p in path) Uint8List.fromList([p])], payload: payload);
}

void main() {
  final secret = hashtagChannelSecret('#wardriving');

  group('classifyEcho names the reason', () {
    test('echo, own transmission, other timestamp, other text, other channel, not a group text, unparsed', () {
      expect(classifyEcho(grp(secret, 100, 'ME', 'MS:aaaaaaaaaa', [0x11]), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict, EchoVerdict.echo);
      expect(classifyEcho(grp(secret, 100, 'ME', 'MS:aaaaaaaaaa', []), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict, EchoVerdict.emptyPath);
      expect(classifyEcho(grp(secret, 99, 'ME', 'MS:aaaaaaaaaa', [0x11]), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict, EchoVerdict.otherTimestamp);
      expect(classifyEcho(grp(secret, 100, 'YOU', 'MS:bbbbbbbbbb', [0x11]), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict, EchoVerdict.otherText);
      final other = hashtagChannelSecret('#other');
      expect(classifyEcho(grp(other, 100, 'ME', 'MS:aaaaaaaaaa', [0x11]), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict, EchoVerdict.otherChannel);
      expect(classifyEcho(grp(secret, 100, 'ME', 'MS:aaaaaaaaaa', [0x11], type: PayloadType.advert), secret, 'MS:aaaaaaaaaa', timestamp: 100).verdict,
          EchoVerdict.notGroupText);
      expect(classifyEcho(null, secret, 'x').verdict, EchoVerdict.unparsed);
    });

    test('a scoped flood (transport codes, header 0x14) is an echo too, and matchEcho agrees with classifyEcho', () {
      final p = MeshPacket(
          header: makeHeader(RouteType.transportFlood, PayloadType.grpTxt),
          transportCode1: 1,
          transportCode2: 2,
          pathLenByte: encodePathLen(1, 1),
          path: [Uint8List.fromList([0x22])],
          payload: buildGroupTextPayload(secret, 7, 'ME', 'MS:cccccccccc'));
      final parsed = MeshPacket.tryParse(p.toBytes())!;
      expect(matchEcho(parsed, secret, 'MS:cccccccccc', timestamp: 7)?.repeater, '22');
      expect(classifyEcho(parsed, secret, 'MS:cccccccccc', timestamp: 7).verdict, EchoVerdict.echo);
    });
  });

  group('engine trace', () {
    late List<Map<String, Object?>> trace;
    StackBuilder tracing() => (link, gps, clock) async {
          final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
          e.onTrace = trace.add;
          return e;
        };

    setUp(() => trace = []);

    test('one record per ping: send time, frames with arrival times and a verdict each, repeats flagged', () {
      final r = runReplay(build: tracing(), seed: 3, driveSeconds: 600, backgroundEverySec: 3);
      final pings = trace.where((t) => t.containsKey('frames') && t.containsKey('ping')).toList();
      expect(pings.length, r.pingsSent);
      for (final t in pings) {
        expect(t['tag'], matches(RegExp(r'^[0-9a-z]{10}$')));
        expect(t['at'], isA<String>());
        expect(t['window_ms'], greaterThanOrEqualTo(10000));
        final frames = (t['frames']! as List).cast<Map<String, Object?>>();
        var last = -1;
        for (final f in frames) {
          expect(f['t'], greaterThanOrEqualTo(last), reason: 'frames in arrival order');
          last = f['t']! as int;
          expect(f['v'], isNotNull);
        }
        final echoes = frames.where((f) => f['v'] == 'echo');
        expect(echoes.length, t['echoes'], reason: 'the trace and the saved ping agree on how many repeaters');
        for (final e in echoes) {
          expect(e['rep'], isNotNull);
          expect(e['hops'], isNotNull);
          expect(e['snr'], isNotNull);
          expect(e['rssi'], isNotNull);
        }
      }
      final verdicts = {for (final t in pings) for (final f in (t['frames']! as List).cast<Map<String, Object?>>()) f['v']};
      expect(verdicts, containsAll(['echo', 'other-timestamp']), reason: 'other drivers\' pings are named as such, not silently dropped');
      expect(verdicts.contains('echo-repeat'), isTrue, reason: 'a second copy from the same repeater is flagged, not counted twice');
    });

    test('skipped pings leave a record with the reason', () {
      // A gate that refuses every ping.
      final r = runReplay(
          build: (link, gps, clock) async {
            final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
            e.onTrace = trace.add;
            e.pingGate = _Refuse();
            return e;
          },
          driveSeconds: 60);
      expect(r.pingsSent, 0);
      expect(trace.where((t) => t['skipped'] == 'radioQueueBusy'), isNotEmpty);
    });

    test('a late repeat after the window is noted in the trace against its ping, not in the ping', () {
      // A repeat at +17.5 s is past the ceiling of a 20 s interval (15 s): too late for the ping, noted in the trace.
      final r = runReplay(
          build: tracing(),
          seed: 1,
          driveSeconds: 120,
          intervalSec: 20,
          script: (i, rng) => const [ScriptedEcho([0x11], 1000, 5, -100), ScriptedEcho([0x22], 17500, 4, -105)]);
      expect(r.pings.first.echoes.map((e) => e.repeater), ['11']);
      final late = trace.where((t) => t.containsKey('late_for')).toList();
      expect(late, isNotEmpty);
      expect(late.first['late_for'], r.pings.first.id);
      final f = (late.first['frames']! as List).cast<Map<String, Object?>>();
      expect(f.any((x) => x['v'] == 'echo' && x['rep'] == '22'), isTrue);
    });

    test('a failing trace sink never touches the ping', () {
      final r = runReplay(
          build: (link, gps, clock) async {
            final e = DefaultWardriveEngine(link: link, location: gps, clock: clock);
            e.onTrace = (_) => throw StateError('disk full');
            return e;
          },
          driveSeconds: 120);
      expect(r.pingsSent, greaterThan(5));
      expect(r.pings.length, r.pingsSent);
    });
  });

  group('adaptive listen', () {
    test('a quiet ping closes at the base window (10 s); a still-answering mesh keeps it open up to the interval', () {
      final quiet = runReplay(
          build: (l, g, c) async => DefaultWardriveEngine(link: l, location: g, clock: c),
          driveSeconds: 300,
          script: (i, rng) => const [ScriptedEcho([0x11], 800, 5, -100)]);
      expect(quiet.pings.every((p) => p.echoes.length == 1), isTrue);
      final tr = <Map<String, Object?>>[];
      runReplay(
          build: (l, g, c) async => DefaultWardriveEngine(link: l, location: g, clock: c)..onTrace = tr.add,
          driveSeconds: 300,
          script: (i, rng) => const [ScriptedEcho([0x11], 800, 5, -100)]);
      expect(tr.where((t) => t.containsKey('window_ms')).every((t) => t['window_ms'] == 10000), isTrue,
          reason: 'one early echo, nothing since: the window closes at 10 s exactly');

      final chain = runReplay(
          build: (l, g, c) async => DefaultWardriveEngine(link: l, location: g, clock: c),
          driveSeconds: 300,
          script: (i, rng) => const [
                ScriptedEcho([0x11], 2000, 5, -100),
                ScriptedEcho([0x22], 6500, 3, -108),
                ScriptedEcho([0x33], 10200, 1, -112),
                ScriptedEcho([0x44], 13000, -2, -115),
              ]);
      expect(chain.pings.first.echoes.map((e) => e.repeater), ['11', '22', '33', '44'],
          reason: 'echoes kept arriving less than 4 s apart, so the listen carried on past 10 s');
    });
  });
}

class _Refuse implements PingGate {
  @override
  FutureOr<PingDecision> requestPing({bool manual = false, int? airtimeMs}) =>
      const PingDecision.skip(PingSkipReason.radioQueueBusy, 'busy');
  @override
  void pingSent({int? airtimeMs}) {}
}
