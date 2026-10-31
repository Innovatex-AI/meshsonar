import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
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

  group('ping rules (chat active)', () {
    setUp(() => arb.chatActive = true);

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

    test('hourly cap (unknown region 1% = 36 s): pings stop, then resume after the hour', () async {
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
      expect(sent, inInclusiveRange(92, 94)); // 36 s / 0.386 s = 93
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
      expect(sent, 400, reason: 'the default 1% cap stops at about 93; at 10% nothing binds at one ping per 20 s');
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
      expect(arb.snapshot().userSends, 200);
    });

    test('user airtime counts against the hourly cap for pings', () async {
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
      final a = TxArbiter(clock: c.call, queueProbe: () async => q, airParams: () => const RadioAirParams(8, 62.5, 5), senderNameBytes: () => 6)
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
}
