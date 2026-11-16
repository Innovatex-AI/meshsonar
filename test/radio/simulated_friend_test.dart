// SimulatedFriend (MeshTrack plan section 10, MT-9): what the simulator's friends put on the air is valid MT1 text whose
// Plus Code decodes back onto the route (within 5 m), at the smart rate; one parks (s0, then quiet), one answers
// "Where are you?" after 2-10 s. Plus the demo radio (private "Saturday crew" slot, off outside the demo) and the replay
// radio's friend script.
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/meshtrack/mt_wire.dart';
import 'package:meshsonar/core/meshtrack/smart_beacon.dart' show SmartBeacon;
import 'package:meshsonar/core/privacy_zones.dart' show distanceM;
import 'package:meshsonar/radio/crypto.dart' show channelHash;
import 'package:meshsonar/radio/packet.dart';
import 'package:meshsonar/radio/protocol.dart';
import 'package:meshsonar/radio/simulator.dart';

import '../support/meshtrack_packets.dart' show meshTrackTestKey;
import '../support/replay_radio.dart';

final DateTime _t0 = DateTime.utc(2026, 11, 16, 14);

/// A Duration in [lo, hi].
Matcher _between(Duration lo, Duration hi) =>
    predicate<Duration>((d) => d >= lo && d <= hi, 'between ${lo.inMilliseconds} and ${hi.inMilliseconds} ms');

/// Ticks [f] every [step] for [span] and returns the texts sent.
List<({DateTime at, String text})> _drive(SimulatedFriend f, Duration span, {Duration step = const Duration(seconds: 1)}) {
  for (var t = Duration.zero; t <= span; t += step) {
    f.tick(_t0.add(t));
  }
  return f.sent;
}

void main() {
  group('a driving friend', () {
    test('every send is valid MT1 whose code decodes within 5 m of where the friend was', () {
      final f = SimulatedFriend('Sam KD8SAM', startedAt: _t0, speedMps: 13, offsetM: 800);
      final sent = _drive(f, const Duration(minutes: 30));
      expect(sent.length, greaterThan(10));
      for (final s in sent) {
        expect(s.text, startsWith('MT1 @'));
        final m = parseMeshTrack(s.text);
        expect(m, isA<MtPosition>(), reason: s.text);
        final p = m as MtPosition;
        expect(p.code.length, 12, reason: '11 digits + "+": Exact');
        final truth = f.positionAt(s.at);
        expect(distanceM(p.area.lat, p.area.lon, truth.lat, truth.lon), lessThan(5), reason: s.text);
        expect(p.speedKmh, 47, reason: '13 m/s');
        expect(p.courseDeg, isNotNull);
        expect(s.text, formatMtPosition(p.code, speedKmh: p.speedKmh, courseDeg: p.courseDeg), reason: 'canonical form');
      }
      // On the Westerville loop.
      final first = parseMeshTrack(sent.first.text) as MtPosition;
      expect(first.area.lat, inInclusiveRange(40.10, 40.15));
      expect(first.area.lon, inInclusiveRange(-82.96, -82.89));
    });

    test('cadence: the smart rate (first at once, then 20 s floor .. 47 km/h interval, early on corners)', () {
      final f = SimulatedFriend('Sam KD8SAM', startedAt: _t0, speedMps: 13);
      final sent = _drive(f, const Duration(minutes: 30));
      expect(sent.first.at, _t0, reason: 'first fix sends at once');
      final interval = SmartBeacon.interval(13 * 3.6);
      expect(interval.inSeconds, inInclusiveRange(100, 104));
      final gaps = [for (var i = 1; i < sent.length; i++) sent[i].at.difference(sent[i - 1].at)];
      for (final g in gaps) {
        expect(g, greaterThanOrEqualTo(const Duration(seconds: 20)), reason: 'airtime floor');
        expect(g, lessThanOrEqualTo(interval + const Duration(seconds: 1)), reason: 'never slower than the moving rate');
      }
      expect(gaps.where((g) => g < interval - const Duration(seconds: 1)), isNotEmpty, reason: 'the loop has corners');
      // 30 min at ~102 s plus some corners: inside a band.
      expect(sent.length, inInclusiveRange(18, 45));
    });

    test('ticks every 5 s (the demo radio) give the same kind of stream', () {
      final f = SimulatedFriend('Sam KD8SAM', startedAt: _t0, speedMps: 13);
      final sent = _drive(f, const Duration(minutes: 20), step: SimulatedTransport.friendTick);
      expect(sent.length, inInclusiveRange(12, 30));
      expect(sent.every((s) => parseMeshTrack(s.text) is MtPosition), isTrue);
    });
  });

  group('the parking friend', () {
    test('drives, then one s0 at the parking spot about 90 s after stopping, then quiet', () {
      final f = SimulatedFriend('Jo N8JO', startedAt: _t0, speedMps: 11, offsetM: -2500, parkAfter: const Duration(minutes: 6));
      final sent = _drive(f, const Duration(minutes: 40));
      final parkedAt = _t0.add(const Duration(minutes: 6));
      final after = sent.where((s) => !s.at.isBefore(parkedAt)).toList();
      expect(after, hasLength(1), reason: after.map((s) => s.text).join('\n'));
      final p = parseMeshTrack(after.single.text) as MtPosition;
      expect(after.single.text, endsWith(' s0'));
      expect(p.speedKmh, 0);
      expect(p.courseDeg, isNull);
      final waited = after.single.at.difference(parkedAt);
      expect(waited, _between(const Duration(seconds: 90), const Duration(seconds: 92)));
      final spot = f.positionAt(parkedAt);
      expect(distanceM(p.area.lat, p.area.lon, spot.lat, spot.lon), lessThan(5));
      expect(sent.where((s) => s.at.isBefore(parkedAt)).length, greaterThan(2), reason: 'it was sharing while driving');
    });
  });

  group('requests', () {
    test('the answering friend replies to MT1 ? and to its own name after 2-10 s, at most once per 30 s', () {
      final f = SimulatedFriend('Sam KD8SAM', startedAt: _t0, answersRequests: true);
      final rng = math.Random(3);
      final d = f.answerDelay(formatMtRequest(), _t0, rng)!;
      expect(d, _between(const Duration(seconds: 2), const Duration(seconds: 10)));
      expect(f.answerDelay(formatMtRequest(), _t0.add(const Duration(seconds: 29)), rng), isNull, reason: '30 s gap');
      final again = f.answerDelay(formatMtRequest('sam kd8sam'), _t0.add(const Duration(seconds: 31)), rng);
      expect(again, isNotNull, reason: 'its own name, any case');
      expect(f.answerDelay(formatMtRequest('Jo N8JO'), _t0.add(const Duration(minutes: 5)), rng), isNull, reason: 'not its name');
      expect(f.answerDelay('hello there', _t0.add(const Duration(minutes: 6)), rng), isNull, reason: 'plain chat');
      expect(f.answerDelay('MT1 @87G8Q2X5+7F2 s34', _t0.add(const Duration(minutes: 7)), rng), isNull, reason: 'a position');
      for (var i = 0; i < 200; i++) {
        final x = SimulatedFriend('A', startedAt: _t0, answersRequests: true).answerDelay('MT1 ?', _t0, rng)!;
        expect(x, _between(const Duration(seconds: 2), const Duration(seconds: 10)));
      }
      final ans = f.answer(_t0.add(const Duration(seconds: 7)));
      final p = parseMeshTrack(ans) as MtPosition;
      final truth = f.positionAt(_t0.add(const Duration(seconds: 7)));
      expect(distanceM(p.area.lat, p.area.lon, truth.lat, truth.lon), lessThan(5));
    });

    test('the other friend never answers', () {
      final f = SimulatedFriend('Jo N8JO', startedAt: _t0, parkAfter: const Duration(minutes: 6));
      expect(f.answerDelay('MT1 ?', _t0, math.Random(1)), isNull);
    });

    test('the demo pair: Sam answers, Jo parks', () {
      final pair = defaultSimulatedFriends(_t0);
      expect(pair.map((f) => f.answersRequests), [true, false]);
      expect(pair.map((f) => f.parkAfter), [null, const Duration(minutes: 6)]);
      expect(pair[0].offsetM, isNot(pair[1].offsetM), reason: 'offset along the route');
    });
  });

  group('the simulated radio', () {
    List<Object> frames(SimulatedTransport r, FakeAsync fa, void Function() act, Duration span) {
      final out = <Object>[];
      final sub = r.incoming.listen((b) => out.add(decodeFrame(b)));
      act();
      fa.elapse(span);
      unawaited(sub.cancel());
      return out;
    }

    test('demo mode: slot 1 is the private "Saturday crew"; positions arrive encrypted in the RX log and as channel messages',
        () {
      fakeAsync((fa) {
        final r = SimulatedTransport(seed: 1, clock: () => _t0.add(fa.elapsed), ambientTraffic: true);
        expect(r.meshTrackFriends, isTrue);
        final got = frames(r, fa, () {
          r.send(encodeGetChannel(1));
          r.send(encodeAppStart('test'));
        }, const Duration(minutes: 10));
        final info = got.whereType<ChannelInfoFrame>().single;
        expect(info.name, simulatedFriendsChannelName);
        expect(info.secret, simulatedFriendsChannelKey);
        expect(simulatedFriendsChannelKey, meshTrackTestKey, reason: 'the privacy pin tests use the same group key');
        final onGroup = [
          for (final f in got.whereType<LogRxDataPush>())
            if (MeshPacket.tryParse(f.raw) case final p? when p.payloadType == PayloadType.grpTxt && p.payload.isNotEmpty && p.payload[0] == channelHash(simulatedFriendsChannelKey))
              decryptGroupText(simulatedFriendsChannelKey, p.payload)!.text,
        ];
        expect(onGroup.length, greaterThanOrEqualTo(6), reason: 'two friends for 10 minutes');
        for (final t in onGroup) {
          final i = t.indexOf(': ');
          expect(parseMeshTrack(t.substring(i + 2)), isA<MtPosition>(), reason: t);
        }
        expect({for (final t in onGroup) t.substring(0, t.indexOf(': '))}, {'Sam KD8SAM', 'Jo N8JO'});
        expect(r.friends.map((f) => f.sent.length).reduce((a, b) => a + b), onGroup.length);
        // The radio also queued each one as a channel message on slot 1 (what the app syncs).
        final msgs = frames(r, fa, () {
          for (var i = 0; i < 40; i++) {
            r.send(encodeSyncNextMessage());
          }
        }, const Duration(seconds: 1)).whereType<ChannelMsgFrame>().toList();
        expect(msgs, isNotEmpty);
        expect(msgs.every((m) => m.channelIndex == 1 && parseMeshTrack(m.text.substring(m.text.indexOf(': ') + 2)) != null), isTrue);
        r.simulateDisconnect();
      });
    });

    test('demo mode: "MT1 ?" sent on the group is answered by Sam within 2-10 s', () {
      fakeAsync((fa) {
        final r = SimulatedTransport(seed: 2, clock: () => _t0.add(fa.elapsed), ambientTraffic: true);
        r.send(encodeAppStart('test'));
        fa.elapse(const Duration(minutes: 1));
        final sam = r.friends.firstWhere((f) => f.answersRequests);
        final before = sam.sent.length;
        final askedAt = fa.elapsed;
        r.send(encodeSendChannelText(1, 1763300000, formatMtRequest()));
        fa.elapse(const Duration(seconds: 1));
        expect(sam.sent.length, before, reason: 'not before 2 s');
        fa.elapse(const Duration(seconds: 10));
        final answers = sam.sent.skip(before).toList();
        expect(answers, isNotEmpty);
        final wait = answers.first.at.difference(_t0.add(askedAt));
        expect(wait, _between(const Duration(seconds: 2), const Duration(seconds: 10)));
        r.simulateDisconnect();
      });
    });

    test('outside the demo there are no friends and slot 1 stays empty', () {
      fakeAsync((fa) {
        final r = SimulatedTransport(seed: 1, clock: () => _t0.add(fa.elapsed));
        expect(r.meshTrackFriends, isFalse);
        final got = frames(r, fa, () {
          r.send(encodeGetChannel(1));
          r.send(encodeAppStart('test'));
        }, const Duration(minutes: 5));
        expect(got.whereType<ChannelInfoFrame>().single.isEmpty, isTrue);
        expect(r.friends, isEmpty);
        expect(r.friendsSlot, isNull);
        r.simulateDisconnect();
      });
    });

    test('the scanner passes the switch through (demo app: on; tests: off unless asked)', () async {
      final demo = SimulatedRadioScanner(ambientTraffic: true);
      final t = await demo.connect(SimulatedRadioScanner.device) as SimulatedTransport;
      expect(t.meshTrackFriends, isTrue);
      t.simulateDisconnect();
      final plain = await SimulatedRadioScanner().connect(SimulatedRadioScanner.device) as SimulatedTransport;
      expect(plain.meshTrackFriends, isFalse);
      plain.simulateDisconnect();
      final asked = await SimulatedRadioScanner(meshTrackFriends: true).connect(SimulatedRadioScanner.device) as SimulatedTransport;
      expect(asked.meshTrackFriends, isTrue);
      asked.simulateDisconnect();
    });
  });

  group('replay radio friend script (for the MeshTrack replay test)', () {
    test('friends share positions on a private slot over the route; app sends there are MeshTrack, not pings', () {
      fakeAsync((fa) {
        DateTime clock() => _t0.add(fa.elapsed);
        final radio = ScriptedTransport(clock: clock, friends: FriendScript.westerville(_t0));
        final pushed = <Object>[];
        radio.incoming.listen((b) => pushed.add(decodeFrame(b)));
        radio.send(encodeGetChannel(2));
        radio.startBackground();
        fa.elapse(const Duration(minutes: 15));
        final info = pushed.whereType<ChannelInfoFrame>().single;
        expect(info.name, simulatedFriendsChannelName);
        expect(radio.friendSent.length, greaterThanOrEqualTo(10));
        for (final s in radio.friendSent) {
          final p = MeshPacket.tryParse(s.raw)!;
          expect(p.path.length, 1, reason: 'heard through a repeater');
          final text = decryptGroupText(simulatedFriendsChannelKey, p.payload)!.text;
          expect(text, '${s.name}: ${s.text}');
          final m = parseMeshTrack(s.text) as MtPosition;
          final f = radio.friends!.friends.firstWhere((f) => f.name == s.name);
          final truth = f.positionAt(s.at);
          expect(distanceM(m.area.lat, m.area.lon, truth.lat, truth.lon), lessThan(5));
        }
        // A request on the group is MeshTrack traffic: no ping is scripted for it, and Sam answers.
        final n = radio.friendSent.length;
        radio.send(encodeSendChannelText(2, 1763300000, 'MT1 ?'));
        fa.elapse(const Duration(seconds: 11));
        expect(radio.sent, isEmpty, reason: 'not a ping');
        expect(radio.trackSent.single.text, 'MT1 ?');
        expect(radio.friendSent.skip(n).map((s) => s.name), contains('Sam KD8SAM'));
        // And both kinds of frame reach the app: encrypted RX log packets and queued channel messages.
        expect(pushed.whereType<LogRxDataPush>().length, greaterThanOrEqualTo(radio.friendSent.length));
        expect(pushed.whereType<MsgWaitingPush>(), isNotEmpty);
        unawaited(radio.disconnect());
      });
    });

    test('a key other than the default can be given', () {
      final key = Uint8List.fromList(List<int>.filled(16, 7));
      final s = FriendScript([SimulatedFriend('A', startedAt: _t0)], slot: 3, key: key);
      expect(s.key, key);
      expect(s.slot, 3);
    });
  });
}
