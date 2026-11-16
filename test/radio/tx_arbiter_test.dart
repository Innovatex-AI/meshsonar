import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/airtime_share.dart';
import 'package:meshsonar/radio/airtime.dart';
import 'package:meshsonar/radio/command_queue.dart';
import 'package:meshsonar/radio/ping_gate.dart';
import 'package:meshsonar/radio/tx_arbiter.dart';

class FakeClock {
  DateTime now = DateTime.utc(2026, 11, 1, 12);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  late FakeClock clock;
  late TxArbiter arb;
  int? queue;

  setUp(() {
    clock = FakeClock();
    queue = 0;
    arb = TxArbiter(clock: clock.call, queueProbe: () async => queue, airParams: () => const RadioAirParams(8, 62.5, 5), senderNameBytes: () => 6);
  });

  group('idle arbiter = today\'s behaviour', () {
    test('every ping is a go, however fast and however many', () async {
      for (var i = 0; i < 500; i++) {
        final d = await arb.requestPing();
        expect(d.go, isTrue);
        arb.pingSent();
        clock.advance(const Duration(seconds: 1));
      }
    });

    test('the radio queue is not even asked while chat is off', () async {
      var asked = 0;
      arb.queueProbe = () async {
        asked++;
        return 5;
      };
      expect((await arb.requestPing()).go, isTrue);
      expect(asked, 0);
    });
  });

  group('chat bound but nobody chatting (the Oct 31 field report)', () {
    test('chatActive alone never holds a ping back: no probe, no budget, however many pings', () async {
      arb.chatActive = true;
      var asked = 0;
      arb.queueProbe = () async {
        asked++;
        return 5;
      };
      for (var i = 0; i < 500; i++) {
        expect((await arb.requestPing()).go, isTrue);
        arb.pingSent();
        clock.advance(const Duration(seconds: 3));
      }
      expect(asked, 0);
      expect(arb.snapshot().skipped, isEmpty);
    });

    test('an unknown region has no hourly cap: 2 h of pings every 10 s at SF8 all go out', () async {
      arb.chatActive = true;
      arb.admitUserSend(300); // one message long ago
      clock.advance(const Duration(minutes: 11));
      var sent = 0;
      for (var i = 0; i < 720; i++) {
        expect((await arb.requestPing()).go, isTrue, reason: 'ping $i');
        arb.pingSent();
        sent++;
        clock.advance(const Duration(seconds: 10));
      }
      expect(sent, 720);
    });

    test('the rules switch on with a message and off again 10 minutes after the last one', () async {
      arb.chatActive = true;
      queue = 3;
      expect((await arb.requestPing()).go, isTrue);
      arb.admitUserSend(300);
      clock.advance(const Duration(seconds: 3));
      expect((await arb.requestPing()).reason, PingSkipReason.radioQueueBusy);
      clock.advance(const Duration(minutes: 10));
      expect((await arb.requestPing()).go, isTrue);
    });
  });

  group('ping rules (chat active)', () {
    setUp(() {
      // These rules are the ones that apply WHILE chatting; a long chatWindow keeps a long test chatting.
      arb.policy = arb.policy.copyWith(chatWindow: const Duration(days: 2));
      arb.chatActive = true;
      arb.admitUserSend(300);
      clock.advance(const Duration(seconds: 3)); // past the 2 s gap, still chatting
    });

    test('radio outbound queue not empty: skipped with a reason', () async {
      queue = 2;
      final d = await arb.requestPing();
      expect(d.go, isFalse);
      expect(d.reason, PingSkipReason.radioQueueBusy);
      expect(d.message, isNotEmpty);
      queue = 0;
      expect((await arb.requestPing()).go, isTrue);
    });

    test('a probe that fails or times out does not block the ping', () async {
      arb.queueProbe = () async => throw StateError('radio gone');
      expect((await arb.requestPing()).go, isTrue);
      arb.queueProbe = () async => null;
      expect((await arb.requestPing()).go, isTrue);
    });

    test('no ping within 2 s of a user send, even a manual one; then fine', () async {
      arb.admitUserSend(300);
      clock.advance(const Duration(milliseconds: 1999));
      expect((await arb.requestPing()).reason, PingSkipReason.userSendRecent);
      expect((await arb.requestPing(manual: true)).reason, PingSkipReason.userSendRecent);
      clock.advance(const Duration(milliseconds: 1));
      expect((await arb.requestPing()).go, isTrue);
    });

    test('a user message that lands while the probe is in flight still blocks the ping', () async {
      arb.queueProbe = () async {
        arb.admitUserSend(300);
        return 0;
      };
      expect((await arb.requestPing()).reason, PingSkipReason.userSendRecent);
    });

    test('ping airtime over 2% of 10 minutes: skipped, and recovers as the window rolls', () async {
      // SF8 / 62.5 / name 6: 6+2+13 = 21 bytes text -> 37 bytes packet -> 386 ms (MeshCore's 32-symbol preamble). 2% of 600 s = 12 s = 31 pings.
      var sent = 0;
      while ((await arb.requestPing()).go) {
        arb.pingSent();
        sent++;
        clock.advance(const Duration(seconds: 3));
        if (sent > 1000) fail('never limited');
      }
      expect(sent, inInclusiveRange(30, 32));
      final snap = arb.snapshot();
      expect(snap.pingMsInWindow, lessThanOrEqualTo(12000));
      expect(snap.skipped[PingSkipReason.pingBudget], greaterThan(0));
      clock.advance(const Duration(minutes: 11));
      expect((await arb.requestPing()).go, isTrue);
    });

    test('hourly cap (a KNOWN region cap of 1% = 36 s): pings stop, then resume after the hour', () async {
      arb.policy = arb.policy.copyWith(capFraction: 0.01);
      // Spread pings out so the 10-minute budget never binds: one every 20 s = 30 per 10 min = 11.6 s.
      var sent = 0;
      for (var i = 0; i < 400; i++) {
        final d = await arb.requestPing();
        if (!d.go) {
          expect(d.reason, PingSkipReason.hourlyCap);
          break;
        }
        arb.pingSent();
        sent++;
        clock.advance(const Duration(seconds: 20));
      }
      expect(sent, inInclusiveRange(91, 94)); // 36 s / 0.386 s = 93, less the user message's 0.3 s
      clock.advance(const Duration(hours: 1, minutes: 1));
      expect((await arb.requestPing()).go, isTrue);
    });

    test('a bigger region cap lets more through', () async {
      arb.policy = arb.policy.copyWith(capFraction: 0.10);
      var sent = 0;
      for (var i = 0; i < 400; i++) {
        final d = await arb.requestPing();
        if (!d.go) break;
        arb.pingSent();
        sent++;
        clock.advance(const Duration(seconds: 20));
      }
      expect(sent, 400, reason: 'a 1% cap stops at about 93; at 10% nothing binds at one ping per 20 s');
    });

    test('manual ping is not held by the budgets (the driver chose it) but still waits for a busy radio', () async {
      for (var i = 0; i < 60; i++) {
        arb.pingSent();
      }
      expect((await arb.requestPing()).go, isFalse);
      expect((await arb.requestPing(manual: true)).go, isTrue);
      queue = 1;
      expect((await arb.requestPing(manual: true)).reason, PingSkipReason.radioQueueBusy);
    });

    test('user sends are never delayed or refused, even far over the cap; the caller is told', () {
      var warned = false;
      for (var i = 0; i < 200; i++) {
        warned = arb.admitUserSend(800) || warned; // never throws, never waits
      }
      expect(warned, isTrue);
      expect(arb.snapshot().userSends, 201, reason: '200 here and the one in setUp');
    });

    test('user airtime counts against the hourly cap for pings (where the cap is known)', () async {
      arb.policy = arb.policy.copyWith(capFraction: 0.01);
      for (var i = 0; i < 45; i++) {
        arb.admitUserSend(800); // 36 s: exactly the cap
      }
      clock.advance(const Duration(seconds: 5));
      expect((await arb.requestPing()).reason, PingSkipReason.hourlyCap);
    });
  });

  test('estimates: ping 386 ms at SF8/62.5 with a 6-byte name; unknown radio is budgeted at 500 ms', () {
    expect(arb.estimatePingMs().round(), 386);
    arb.airParams = () => null;
    expect(arb.estimatePingMs(), 500);
  });

  group('property: random traffic, fake clocks, deterministic', () {
    // Independent bookkeeping of what was granted, checked against the rules after every step.
    Future<List<String>> run(int seed) async {
      final rng = math.Random(seed);
      final c = FakeClock();
      var q = 0;
      final a = TxArbiter(
          clock: c.call,
          policy: const TxPolicy(capFraction: 0.01, chatWindow: Duration(days: 2)),
          queueProbe: () async => q,
          airParams: () => const RadioAirParams(8, 62.5, 5),
          senderNameBytes: () => 6)
        ..chatActive = true;
      final est = a.estimatePingMs();
      final pings = <(DateTime, double)>[];
      final others = <(DateTime, double)>[];
      DateTime? lastUser;
      final trace = <String>[];
      for (var step = 0; step < 1500; step++) {
        c.advance(Duration(milliseconds: 100 + rng.nextInt(20000)));
        switch (rng.nextInt(10)) {
          case 0 || 1 || 2:
            // a user send, any size, any time: must always be accepted at once
            final ms = 100.0 + rng.nextInt(900);
            a.admitUserSend(ms);
            others.add((c.now, ms));
            lastUser = c.now;
            trace.add('u');
          case 3:
            q = rng.nextInt(3) == 0 ? 1 + rng.nextInt(3) : 0;
          default:
            final manual = rng.nextInt(8) == 0;
            final d = await a.requestPing(manual: manual);
            trace.add(d.go ? 'g' : d.reason!.name[0]);
            if (!d.go) break;
            // (a) never within 2 s of a user send
            if (lastUser != null) {
              expect(c.now.difference(lastUser).inMilliseconds, greaterThanOrEqualTo(2000), reason: 'seed $seed step $step');
            }
            // the radio queue was empty when it was granted
            // (the rules below hold once the person has chatted; before the first message the arbiter is idle by design)
            if (lastUser == null) {
              a.pingSent();
              pings.add((c.now, est));
              break;
            }
            expect(q, 0, reason: 'seed $seed step $step');
            if (!manual) {
              final from10 = c.now.subtract(const Duration(minutes: 10));
              final used10 = pings.where((p) => !p.$1.isBefore(from10)).fold<double>(0, (s, p) => s + p.$2);
              // (b) automatic pings: 2% of 10 minutes
              expect(used10 + est, lessThanOrEqualTo(12000 + 1e-6), reason: 'seed $seed step $step');
              final from60 = c.now.subtract(const Duration(hours: 1));
              final total = [...pings, ...others].where((p) => !p.$1.isBefore(from60)).fold<double>(0, (s, p) => s + p.$2);
              // (c) a granted automatic ping never takes the hour over the 1% cap
              expect(total + est, lessThanOrEqualTo(36000 + 1e-6), reason: 'seed $seed step $step');
            }
            a.pingSent();
            pings.add((c.now, est));
        }
      }
      // (d) chat never starved: after all that, a user send is still accepted immediately
      a.admitUserSend(500);
      expect(a.snapshot().userSends, greaterThan(100));
      return trace;
    }

    test('invariants hold for 60 seeds', () async {
      for (var seed = 1; seed <= 60; seed++) {
        await run(seed);
      }
    });

    test('same seed, same decisions', () async {
      expect(await run(7), await run(7));
      expect(await run(7), isNot(await run(8)));
    });
  });

  // ---------------------------------------------------------------- MeshTrack (meshtrack plan sections 3-4, MT-4)
  group('MeshTrack airtime (meshTrackAirtimeMs)', () {
    // "KE4BFI: MT1 @87G8Q2X5+7F2 s34 c270" = 34 text bytes -> 53-byte packet; ping "KE4BFI: MS:xxxxxxxxxx" = 21 -> 37.
    const position = 'KE4BFI: MT1 @87G8Q2X5+7F2 s34 c270';
    const ping = 'KE4BFI: MS:xxxxxxxxxx';

    test('the example position is 34 text bytes and a 53-byte packet', () {
      expect(position.length, 34);
      expect(groupTextPacketBytes(position.length), 53);
      expect(groupTextPacketBytes(ping.length), 37);
    });

    test('pins the plan table (exact values from loraAirtimeMs; the plan rounds them)', () {
      final rows = <(LoraRadio, double, double, double, double)>[
        // preset, position exact, ping exact, plan position, plan ping (ms)
        (const LoraRadio(7, 62.5, 5), 254.464, 213.504, 255, 214),
        (const LoraRadio(8, 62.5, 5), 467.968, 386.048, 468, 386),
        (const LoraRadio(10, 250, 5), 340.992, 279.552, 341, 280),
        (const LoraRadio(11, 250, 5), 641.024, 518.144, 641, 518),
        (const LoraRadio(12, 125, 5), 2727.936, 2236.416, 2730, 2240),
      ];
      for (final (r, pos, png, planPos, planPing) in rows) {
        final mt = meshTrackAirtimeMs(position.length, r);
        final pg = meshTrackAirtimeMs(ping.length, r);
        expect(mt, closeTo(pos, 1e-6), reason: 'SF${r.sf}/${r.bwKhz}');
        expect(pg, closeTo(png, 1e-6), reason: 'SF${r.sf}/${r.bwKhz}');
        expect(mt, loraAirtimeMs(payloadBytes: 53, sf: r.sf, bwKhz: r.bwKhz, cr: r.cr));
        // The plan's table agrees within its rounding (1 ms; the SF12 row is given in seconds to 2 places).
        final tol = r.sf == 12 ? 5.0 : 1.0;
        expect(mt, closeTo(planPos, tol), reason: 'plan position SF${r.sf}');
        expect(pg, closeTo(planPing, tol), reason: 'plan ping SF${r.sf}');
      }
    });

    test('the US default preset and a scoped flood', () {
      expect(meshTrackAirtimeMs(34, LoraRadio.meshcoreUs), closeTo(254.464, 1e-6));
      expect(meshTrackAirtimeMs(34, LoraRadio.meshcoreUs, transportCodes: true), greaterThan(meshTrackAirtimeMs(34, LoraRadio.meshcoreUs)));
    });
  });

  group('TxPriority.track', () {
    // Body "MT1 @87G8Q2X5+7F2 s34 c270" (26 bytes) + name 6 + ": " = 34 -> 53 bytes -> 467.968 ms at SF8/BW62.5.
    const body = 26;
    const trackMs = 467.968;

    test('same queue value as a ping, its own ledger rows', () {
      expect(TxPriority.track.value, TxPriority.ping.value);
      expect(TxPriority.track.value, CommandPriority.ping);
      expect(arb.estimateTrackMs(body), closeTo(trackMs, 1e-6));
      arb.trackSent(arb.estimateTrackMs(body));
      final s = arb.snapshot();
      expect(s.trackMsInWindow, closeTo(trackMs, 1e-6));
      expect(s.pingMsInWindow, 0, reason: 'track airtime is not ping airtime');
      expect(s.totalMsInCapWindow, closeTo(trackMs, 1e-6), reason: 'but it is own transmit time');
      expect(s.trackSent, 1);
      expect(s.pingsSent, 0);
      expect(s.userSends, 0);
    });

    test('budget: at most 1% of the rolling 10 minutes, then skipped (never queued), back when the window rolls', () {
      // 6000 ms allowed: 12 x 467.968 = 5615.6 fits, the 13th (6083.6) does not.
      for (var i = 0; i < 12; i++) {
        final d = arb.requestTrack(body);
        expect(d.go, isTrue, reason: 'send $i');
        arb.trackSent(d.estimateMs);
        clock.advance(const Duration(seconds: 5));
      }
      final d = arb.requestTrack(body);
      expect(d.go, isFalse);
      expect(d.reason, TrackSkipReason.budget);
      expect(d.airtimeLimited, isTrue);
      expect(d.message, 'Sharing slower: airtime limit');
      expect(arb.trackSlowedByBudget(), isTrue);
      expect(arb.lastTrackSkipReason, TrackSkipReason.budget);
      expect(arb.snapshot().trackSkipped[TrackSkipReason.budget], 1);
      expect(arb.snapshot().trackSent, 12, reason: 'a skip is not a send and nothing was queued');
      // Asking again and again changes nothing on the ledger.
      for (var i = 0; i < 50; i++) {
        expect(arb.requestTrack(body).go, isFalse);
      }
      expect(arb.snapshot().trackMsInWindow, closeTo(12 * trackMs, 1e-6));
      // The first sends fall out of the 10-minute window.
      clock.advance(const Duration(minutes: 10));
      final again = arb.requestTrack(body);
      expect(again.go, isTrue);
      arb.trackSent(again.estimateMs);
      expect(arb.trackSlowedByBudget(), isFalse, reason: 'cleared once one goes');
      expect(arb.lastTrackSkipReason, isNull);
    });

    test('the track budget applies with chat idle too (unlike the ping budget)', () {
      expect(arb.chatActive, isFalse);
      for (var i = 0; i < 12; i++) {
        arb.trackSent(trackMs);
      }
      clock.advance(const Duration(seconds: 3));
      expect(arb.requestTrack(body).reason, TrackSkipReason.budget);
    });

    test('track sends do not use up the ping budget', () async {
      arb.chatActive = true;
      arb.admitUserSend(10);
      clock.advance(const Duration(seconds: 3));
      for (var i = 0; i < 12; i++) {
        arb.trackSent(trackMs);
      }
      clock.advance(const Duration(seconds: 3));
      expect((await arb.requestPing()).go, isTrue);
    });

    test('a known region hour cap holds track sends back like pings; an unknown one does not', () {
      arb.recordTx(TxPriority.admin, 3000000); // 50 min of other own airtime in the hour
      clock.advance(const Duration(seconds: 3));
      expect(arb.requestTrack(body).go, isTrue, reason: 'no cap known: only the track budget counts');
      arb.policy = arb.policy.copyWith(capFraction: 0.01); // 36 s per hour
      final d = arb.requestTrack(body);
      expect(d.go, isFalse);
      expect(d.reason, TrackSkipReason.regionCap);
      expect(d.airtimeLimited, isTrue);
      expect(arb.snapshot().trackSkipped[TrackSkipReason.regionCap], 1);
    });

    test('region cap counts track airtime toward the hour (pings see it)', () async {
      arb.policy = arb.policy.copyWith(capFraction: 0.01); // 36000 ms per hour
      arb.chatActive = true;
      arb.admitUserSend(1);
      clock.advance(const Duration(seconds: 3));
      arb.recordTx(TxPriority.admin, 36000 - 500 - 200);
      arb.trackSent(500);
      clock.advance(const Duration(seconds: 3));
      final d = await arb.requestPing();
      expect(d.go, isFalse);
      expect(d.reason, PingSkipReason.hourlyCap);
    });

    test('gap: no track send within 2 s of a user message or a ping', () {
      arb.admitUserSend(100);
      var d = arb.requestTrack(body);
      expect(d.go, isFalse);
      expect(d.reason, TrackSkipReason.gap);
      expect(d.airtimeLimited, isFalse);
      expect(arb.trackSlowedByBudget(), isFalse, reason: 'a gap is not an airtime limit');
      clock.advance(const Duration(seconds: 2));
      expect(arb.requestTrack(body).go, isTrue);
      arb.pingSent();
      d = arb.requestTrack(body);
      expect(d.reason, TrackSkipReason.gap);
      clock.advance(const Duration(milliseconds: 2001));
      expect(arb.requestTrack(body).go, isTrue);
    });

    test('pings get the same 2 s gap after a track send as after a user send, chat idle or not', () async {
      arb.trackSent(trackMs);
      var d = await arb.requestPing();
      expect(d.go, isFalse);
      expect(d.reason, PingSkipReason.userSendRecent);
      expect(d.message, 'Ping skipped: a position was just shared');
      d = await arb.requestPing(manual: true);
      expect(d.go, isFalse, reason: 'a manual ping waits too, as after a user send');
      clock.advance(const Duration(seconds: 2));
      expect((await arb.requestPing()).go, isTrue);
    });

    test('a track send during the radio-queue probe holds the ping back', () async {
      arb.chatActive = true;
      arb.admitUserSend(10);
      clock.advance(const Duration(seconds: 3));
      arb.queueProbe = () async {
        arb.trackSent(trackMs);
        return 0;
      };
      final d = await arb.requestPing();
      expect(d.go, isFalse);
      expect(d.message, 'Ping skipped: a position was just shared');
    });

    test('runTrackSend: the session\'s own admitUserSend inside it is recorded as track, never as a user message', () async {
      final ts = await arb.runTrackSend(body, () async {
        await Future<void>.delayed(Duration.zero); // the session awaits before and after recording
        final warned = arb.admitUserSend(arb.estimateChannelMs(body)); // what RadioSessionImpl.sendChannelMessage does
        expect(warned, isFalse);
        await Future<void>.delayed(Duration.zero);
        return 1234;
      });
      expect(ts, 1234);
      final s = arb.snapshot();
      expect(s.userSends, 0);
      expect(s.trackSent, 1, reason: 'recorded once, not again after the send');
      expect(s.trackMsInWindow, closeTo(trackMs, 1e-6));
      // No user send happened, so the next track is gated only by its own rules (and pings by the track gap).
      clock.advance(const Duration(seconds: 3));
      expect(arb.requestTrack(body).go, isTrue);
    });

    test('runTrackSend: a user message sent at the same time outside it stays a user message', () async {
      final done = arb.runTrackSend(body, () async {
        await Future<void>.delayed(const Duration(milliseconds: 1));
        arb.admitUserSend(trackMs);
        return 1;
      });
      arb.admitUserSend(300); // outside the zone
      await done;
      final s = arb.snapshot();
      expect(s.userSends, 1);
      expect(s.trackSent, 1);
    });

    test('runTrackSend: a transport that records nothing gets the estimate; a send that throws records nothing', () async {
      await arb.runTrackSend(body, () async => 7);
      expect(arb.snapshot().trackSent, 1);
      expect(arb.snapshot().trackMsInWindow, closeTo(trackMs, 1e-6));
      await expectLater(arb.runTrackSend(body, () async => throw StateError('radio gone')), throwsStateError);
      expect(arb.snapshot().trackSent, 1);
      // A second arbiter's zone does not capture this one's sends.
      final other = TxArbiter(clock: clock.call);
      await other.runTrackSend(4, () async {
        arb.admitUserSend(100);
        return 0;
      });
      expect(arb.snapshot().userSends, 1);
      expect(other.snapshot().trackSent, 1);
    });

    test('requestTrackText counts UTF-8 bytes', () {
      expect(arb.requestTrackText('MT1 @87G8Q2X5+7F2 s34 c270').estimateMs, closeTo(trackMs, 1e-6));
    });
  });
}
