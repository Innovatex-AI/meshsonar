// Battery plan A6: the observer heartbeat goes with a telemetry batch when one is due, and the 5 min timer then skips
// its own tick, so the network wakes once; the gap between heartbeats stays under the server's 10 min online window.
// Also Phase 0: every request of the app's server client is counted.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshsonar/core/cmat_client.dart';
import 'package:meshsonar/core/observer_status.dart';
import 'package:meshsonar/core/power_profile.dart';

class _Tx implements ObserverStatusTransport {
  final List<Duration> beats = [];
  Duration Function() at = () => Duration.zero;
  @override
  Future<ObserverHttpResult> heartbeat(String driverKey, Map<String, dynamic> body) async {
    beats.add(at());
    return const ObserverHttpResult(200);
  }

  @override
  Future<ObserverHttpResult> me(String driverKey) async => const ObserverHttpResult(200);
}

void main() {
  ObserverStatusService svc(_Tx tx, DateTime Function() clock) => ObserverStatusService(
        transport: () => tx,
        driverKey: () => 'k',
        observerId: () async => 'aaaabbbbccccddddeeeeffff00001111',
        active: () => true,
        connected: () => true,
        clock: clock,
      );

  test('batches every 5 min: the heartbeat rides along, the timer never beats alone; no gap reaches 10 min', () {
    final tx = _Tx();
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 17);
      tx.at = () => async.elapsed;
      final s = svc(tx, () => start.add(async.elapsed));
      s.startHeartbeat();
      async.flushMicrotasks();
      // A locked phone on Balanced: a telemetry batch every 5 min, offset from the heartbeat clock by 2 min.
      async.elapse(const Duration(minutes: 2));
      for (var i = 0; i < 12; i++) {
        s.rideAlong();
        async.elapse(const Duration(minutes: 5));
      }
      s.stopHeartbeat();
      // Start beat at 0; the timer may beat once or twice while the phases line up (6, 12 min); from then on every
      // batch carries the heartbeat and the timer never wakes the network alone.
      expect(s.heartbeatsCoalesced, greaterThanOrEqualTo(9));
      expect(tx.beats.length, lessThanOrEqualTo(s.heartbeatsCoalesced + 3));
      final tail = tx.beats.where((b) => b >= const Duration(minutes: 20)).toList();
      expect(tail.every((b) => (b - const Duration(minutes: 2)).inSeconds % 300 == 0), isTrue,
          reason: 'after the start every beat is at a batch time');
      for (var i = 1; i < tx.beats.length; i++) {
        expect(tx.beats[i] - tx.beats[i - 1], lessThan(const Duration(minutes: 10)));
      }
    });
  });

  test('no batches: the timer beats every 6 min', () {
    final tx = _Tx();
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 17);
      tx.at = () => async.elapsed;
      final s = svc(tx, () => start.add(async.elapsed));
      s.startHeartbeat();
      async.elapse(const Duration(minutes: 60, seconds: 1));
      s.stopHeartbeat();
      expect(tx.beats, hasLength(11));
      expect(s.heartbeatsCoalesced, 0);
    });
  });

  test('foreground batches every 5 s do not add heartbeats', () {
    final tx = _Tx();
    fakeAsync((async) {
      final start = DateTime.utc(2026, 11, 17);
      tx.at = () => async.elapsed;
      final s = svc(tx, () => start.add(async.elapsed));
      s.startHeartbeat();
      for (var i = 0; i < 720; i++) {
        async.elapse(const Duration(seconds: 5));
        s.rideAlong();
      }
      s.stopHeartbeat();
      expect(tx.beats.length, inInclusiveRange(13, 16), reason: 'one per 4 min at most');
    });
  });

  test('rideAlong does nothing while the heartbeat is stopped', () {
    final tx = _Tx();
    fakeAsync((async) {
      final s = svc(tx, () => DateTime.utc(2026, 11, 17).add(async.elapsed));
      s.rideAlong();
      async.flushMicrotasks();
      expect(tx.beats, isEmpty);
    });
  });

  test('PowerCounters.httpRequest counts every request of the server client', () async {
    PowerCounters.debugReset();
    final c = HttpCmatClient(Uri.parse('https://meshsonar.com'),
        client: MockClient((r) async => http.Response('{}', 200, headers: {'content-type': 'application/json'})));
    await c.heartbeat('k', {'id': 'x'});
    await c.me('k');
    expect(PowerCounters.get(PowerCounters.httpRequest), 2);
    PowerCounters.debugReset();
  });
}
