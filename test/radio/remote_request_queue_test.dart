import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/command_queue.dart';
import 'package:meshsonar/radio/protocol.dart' show SentFrame;
import 'package:meshsonar/radio/remote_request_queue.dart';

const _key = 'df' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab';

const fast = RemoteTimeouts(
  ack: Duration(milliseconds: 40),
  floor: Duration(milliseconds: 60),
  floodCeiling: Duration(milliseconds: 200),
  directCeiling: Duration(milliseconds: 100),
  margin: Duration(milliseconds: 10),
);

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  group('one in flight', () {
    for (var seed = 1; seed <= 25; seed++) {
      test('property: never two jobs at once, every result arrives (seed $seed)', () async {
        final rnd = math.Random(seed);
        final pauses = <bool>[];
        final q = RemoteRequestQueue(timeouts: fast, onRxPause: pauses.add);
        var running = 0, maxRunning = 0;
        final handles = <RemoteRequest<int>>[];
        final expected = <int, RemoteState>{};
        for (var i = 0; i < 30; i++) {
          final prio = [CommandPriority.user, CommandPriority.admin, CommandPriority.ping, CommandPriority.background][rnd.nextInt(4)];
          final mode = rnd.nextInt(5); // 0,1 ok, 2 noReply, 3 refused, 4 other error
          final ms = rnd.nextInt(6);
          final r = q.enqueue<int>(
            kind: RemoteKind.values[rnd.nextInt(RemoteKind.values.length)],
            target: _key,
            priority: prio,
            run: (ctx) async {
              running++;
              maxRunning = math.max(maxRunning, running);
              try {
                await Future<void>.delayed(Duration(milliseconds: ms));
                if (mode == 2) throw const RemoteNoReply();
                if (mode == 3) throw const RemoteRefused();
                if (mode == 4) throw StateError('boom');
                return i;
              } finally {
                running--;
              }
            },
          );
          handles.add(r);
          if (r.state != RemoteState.dropped) {
            expected[r.id] = switch (mode) {
              2 => RemoteState.noReply,
              3 => RemoteState.refused,
              4 => RemoteState.failed,
              _ => RemoteState.done,
            };
          }
          if (rnd.nextInt(4) == 0) await Future<void>.delayed(Duration(milliseconds: rnd.nextInt(4)));
          if (rnd.nextInt(10) == 0 && r.state == RemoteState.queued) {
            q.cancel(r.id);
            expected[r.id] = RemoteState.cancelled;
          }
        }
        await Future.wait(handles.map((h) => h.result));
        expect(maxRunning, 1, reason: 'seed $seed');
        for (final h in handles) {
          expect(h.isFinished, isTrue);
          if (expected.containsKey(h.id)) expect(h.state, expected[h.id], reason: 'request ${h.id} seed $seed');
        }
        expect(q.busy, isFalse);
        expect(q.waiting, 0);
        expect(q.rxPaused, isFalse);
        // pause/resume strictly alternate and end resumed
        for (var i = 0; i < pauses.length; i++) {
          expect(pauses[i], i.isEven);
        }
        if (pauses.isNotEmpty) expect(pauses.last, isFalse);
      });
    }
  });

  group('order', () {
    test('user goes ahead of admin and ping that are already waiting; a running request is not interrupted', () async {
      final q = RemoteRequestQueue();
      final order = <String>[];
      final gate = Completer<void>();
      Future<void> job(String n) async => order.add(n);
      final first = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async {
        order.add('first-start');
        await gate.future;
        order.add('first-end');
      });
      await settle();
      expect(first.state, RemoteState.sending);
      q.enqueue<void>(kind: RemoteKind.cli, target: _key, priority: CommandPriority.ping, run: (_) => job('ping'));
      q.enqueue<void>(kind: RemoteKind.cli, target: _key, priority: CommandPriority.admin, run: (_) => job('admin1'));
      q.enqueue<void>(kind: RemoteKind.cli, target: _key, priority: CommandPriority.admin, run: (_) => job('admin2'));
      final user = q.enqueue<void>(kind: RemoteKind.cli, target: _key, priority: CommandPriority.user, run: (_) => job('user'));
      expect(q.requests.value.map((r) => r.kind).length, 5);
      expect(q.requests.value.first, first);
      expect(q.requests.value[1], user, reason: 'the list shows run order');
      gate.complete();
      await user.result;
      await settle();
      expect(order, ['first-start', 'first-end', 'user', 'admin1', 'admin2', 'ping']);
    });
  });

  group('timeouts', () {
    test('a silent enforced request becomes noReply (not failed) and the slot is released for the next', () async {
      final q = RemoteRequestQueue(timeouts: fast);
      final hung = q.enqueue<int>(kind: RemoteKind.status, target: _key, enforceDeadline: true, run: (_) => Completer<int>().future);
      final next = q.enqueue<int>(kind: RemoteKind.status, target: _key, run: (_) async => 7);
      final res = await hung.result;
      expect(res, isA<RemoteNoReplyResult<int>>());
      expect(hung.state, RemoteState.noReply);
      final r2 = await next.result;
      expect((r2 as RemoteDone<int>).value, 7);
    });

    test('est_timeout from SENT sets the reply deadline: x1.25 + 3 s, floor 8 s, ceiling 45 s flood / 20 s direct', () {
      const t = RemoteTimeouts();
      expect(t.replyFor(1200, flood: false), const Duration(seconds: 8)); // 1.5 + 3 = 4.5 -> floor
      expect(t.replyFor(6000, flood: false), const Duration(milliseconds: 10500)); // 7.5 + 3
      expect(t.replyFor(30000, flood: false), const Duration(seconds: 20));
      expect(t.replyFor(30000, flood: true), const Duration(milliseconds: 40500));
      expect(t.replyFor(100000, flood: true), const Duration(seconds: 45));
    });

    test('SENT moves to waitingForReply, records est_timeout and flood, and re-arms the deadline', () async {
      final q = RemoteRequestQueue(timeouts: fast);
      late RemoteContext ctx;
      final got = Completer<void>();
      final r = q.enqueue<int>(kind: RemoteKind.login, target: _key, enforceDeadline: true, run: (c) async {
        ctx = c;
        got.complete();
        return Completer<int>().future;
      });
      await got.future;
      expect(r.state, RemoteState.sending);
      ctx.reportSentFrame(const SentFrame(flood: true, tag: 1, estTimeoutMs: 20));
      expect(r.state, RemoteState.waitingForReply);
      expect(r.estTimeout, const Duration(milliseconds: 20));
      expect(r.flood, isTrue);
      final sw = Stopwatch()..start();
      await r.result;
      // fast.floor is 60 ms: the 40 ms ack deadline was replaced by the longer reply deadline
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(55));
      expect(r.state, RemoteState.noReply);
    });

    test('no SENT within the ack time is also noReply', () async {
      final q = RemoteRequestQueue(timeouts: fast);
      final r = q.enqueue<int>(kind: RemoteKind.status, target: _key, enforceDeadline: true, run: (_) => Completer<int>().future);
      expect(await r.result, isA<RemoteNoReplyResult<int>>());
    });
  });

  group('cancel', () {
    test('a waiting request never runs', () async {
      final q = RemoteRequestQueue();
      final gate = Completer<void>();
      var ran = false;
      q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) => gate.future);
      final w = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async => ran = true);
      expect(q.cancel(w.id), isTrue);
      expect(w.state, RemoteState.cancelled);
      expect(await w.result, isA<RemoteCancelledResult<void>>());
      gate.complete();
      await settle();
      expect(ran, isFalse);
      expect(q.cancel(w.id), isFalse, reason: 'already finished');
    });

    test('a running request answers cancelled at once but keeps the slot until its job returns', () async {
      final q = RemoteRequestQueue();
      final gate = Completer<int>();
      final running = q.enqueue<int>(kind: RemoteKind.status, target: _key, run: (_) => gate.future);
      var secondStarted = false;
      final second = q.enqueue<int>(kind: RemoteKind.status, target: _key, run: (_) async {
        secondStarted = true;
        return 2;
      });
      await settle();
      q.cancel(running.id);
      expect(await running.result, isA<RemoteCancelledResult<int>>());
      await settle();
      expect(secondStarted, isFalse, reason: 'the firmware slot is still taken');
      gate.complete(1);
      expect(((await second.result) as RemoteDone<int>).value, 2);
      expect(running.state, RemoteState.cancelled);
    });

    test('submit throws RemoteRequestAborted for cancelled and dropped', () async {
      final q = RemoteRequestQueue();
      final gate = Completer<void>();
      q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) => gate.future);
      final f = q.submit<void>(kind: RemoteKind.status, target: _key, priority: CommandPriority.background, run: (_) async {});
      await expectLater(f, throwsA(isA<RemoteRequestAborted>().having((e) => e.state, 'state', RemoteState.dropped)));
      gate.complete();
    });
  });

  group('auto refresh', () {
    test('a background request is dropped when a request runs or waits, and when auto refresh is off', () async {
      final q = RemoteRequestQueue();
      final gate = Completer<void>();
      final user = q.enqueue<void>(kind: RemoteKind.login, target: _key, run: (_) => gate.future);
      final bg = q.enqueue<void>(kind: RemoteKind.status, target: _key, priority: CommandPriority.background, run: (_) async {});
      expect(bg.state, RemoteState.dropped);
      expect(await bg.result, isA<RemoteDroppedResult<void>>());
      expect(q.waiting, 0, reason: 'dropped, not queued');
      gate.complete();
      await user.result;
      await settle();
      final ok = q.enqueue<int>(kind: RemoteKind.status, target: _key, priority: CommandPriority.background, run: (_) async => 5);
      expect(((await ok.result) as RemoteDone<int>).value, 5);
      q.autoRefreshEnabled = false; // driving (D7)
      final off = q.enqueue<int>(kind: RemoteKind.status, target: _key, priority: CommandPriority.background, run: (_) async => 5);
      expect(off.state, RemoteState.dropped);
      final tap = q.enqueue<int>(kind: RemoteKind.status, target: _key, run: (_) async => 6);
      expect(((await tap.result) as RemoteDone<int>).value, 6, reason: 'user taps still run');
    });
  });

  group('rx log pause', () {
    test('paused when the first request starts, resumed only when the queue is empty', () async {
      final events = <String>[];
      final q = RemoteRequestQueue(onRxPause: (p) => events.add(p ? 'pause' : 'resume'));
      expect(q.rxPaused, isFalse);
      final a = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async => events.add('a'));
      final b = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async => events.add('b'));
      await Future.wait([a.result, b.result]);
      await settle();
      expect(events, ['pause', 'a', 'b', 'resume'], reason: 'no resume flicker between two queued requests');
      expect(q.rxPaused, isFalse);
    });

    test('resumes after a timeout and after close', () async {
      final events = <bool>[];
      final q = RemoteRequestQueue(timeouts: fast, onRxPause: events.add);
      await q.enqueue<int>(kind: RemoteKind.status, target: _key, enforceDeadline: true, run: (_) => Completer<int>().future).result;
      await settle();
      expect(events, [true, false]);
      q.close();
    });
  });

  group('retries', () {
    test('a login is never auto-retried, even if asked', () async {
      final q = RemoteRequestQueue();
      var calls = 0;
      final r = q.enqueue<int>(kind: RemoteKind.login, target: _key, autoRetries: 3, run: (_) async {
        calls++;
        throw const RemoteNoReply();
      });
      expect(await r.result, isA<RemoteNoReplyResult<int>>());
      expect(calls, 1);
      expect(r.autoRetries, 0);
    });

    test('an idempotent read gets its one retry after silence, then answers', () async {
      final q = RemoteRequestQueue();
      var calls = 0;
      final r = q.enqueue<int>(kind: RemoteKind.status, target: _key, autoRetries: 1, run: (_) async {
        if (++calls == 1) throw const RemoteNoReply();
        return 9;
      });
      expect(((await r.result) as RemoteDone<int>).value, 9);
      expect(calls, 2);
      expect(r.attempt, 2);
    });

    test('retries stop at the limit and end as noReply', () async {
      final q = RemoteRequestQueue();
      var calls = 0;
      final r = q.enqueue<int>(kind: RemoteKind.status, target: _key, autoRetries: 1, run: (_) async {
        calls++;
        throw const RemoteNoReply();
      });
      expect(await r.result, isA<RemoteNoReplyResult<int>>());
      expect(calls, 2);
    });

    test('refused is not retried and is not noReply (wrong password is not silence)', () async {
      final q = RemoteRequestQueue();
      var calls = 0;
      final r = q.enqueue<int>(kind: RemoteKind.status, target: _key, autoRetries: 2, run: (_) async {
        calls++;
        throw const RemoteRefused('0x86');
      });
      expect(await r.result, isA<RemoteRefusedResult<int>>());
      expect(r.state, RemoteState.refused);
      expect(calls, 1);
    });
  });

  group('matching replies', () {
    Future<(RemoteRequestQueue, RemoteRequest<Object?>)> inFlight({String? prefix, int? tag}) async {
      final q = RemoteRequestQueue();
      final started = Completer<void>();
      final r = q.enqueue<Object?>(kind: RemoteKind.status, target: _key, run: (ctx) async {
        ctx.expect(prefixHex: prefix, tag: tag);
        started.complete();
        return ctx.reply;
      });
      await started.future;
      return (q, r);
    }

    test('login / status match by the 6-byte key prefix, case-insensitively; others are counted and ignored', () async {
      final (q, r) = await inFlight(prefix: _key.substring(0, 12));
      expect(q.offerPush(prefixHex: 'aabbccddeeff', payload: 'other node'), isFalse);
      expect(q.offerPush(tag: 5), isFalse);
      expect(q.unmatchedPushes, 2);
      expect(r.state, RemoteState.sending);
      expect(q.offerPush(prefixHex: _key.substring(0, 12).toUpperCase(), payload: 'mine'), isTrue);
      expect(((await r.result) as RemoteDone<Object?>).value, 'mine');
      expect(q.offerPush(prefixHex: _key.substring(0, 12)), isFalse, reason: 'nothing in flight any more');
      expect(q.unmatchedPushes, 3);
    });

    test('binary and trace match by tag only', () async {
      final (q, r) = await inFlight(tag: 0x01020304);
      expect(q.offerPush(prefixHex: _key.substring(0, 12)), isFalse, reason: 'a prefix does not answer a tag request');
      expect(q.offerPush(tag: 0x01020305), isFalse);
      expect(q.offerPush(tag: 0x01020304, payload: 42), isTrue);
      expect(((await r.result) as RemoteDone<Object?>).value, 42);
    });
  });

  group('observable list and close', () {
    test('requests notifies on every change', () async {
      final q = RemoteRequestQueue();
      var n = 0;
      q.requests.addListener(() => n++);
      final r = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async {});
      await r.result;
      await settle();
      expect(n, greaterThanOrEqualTo(3));
      expect(q.requests.value, isEmpty);
    });

    test('close cancels everything waiting and refuses new requests', () async {
      final q = RemoteRequestQueue();
      final gate = Completer<void>();
      q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) => gate.future);
      final w = q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async {});
      q.close();
      expect(w.state, RemoteState.cancelled);
      expect(q.enqueue<void>(kind: RemoteKind.status, target: _key, run: (_) async {}).state, RemoteState.cancelled);
      gate.complete();
    });
  });
}
