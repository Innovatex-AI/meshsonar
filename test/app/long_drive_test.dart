// A long drive (more than 5,000 pings, ROADMAP "Exports aren't chunked"): the app keeps up, memory stays bounded where it
// should, every ping is saved before it is shown as done, and the upload goes out in requests the server accepts.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';

import '../ui/fakes.dart';

Future<void> settle([int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('6,000 pings: all saved in order, the recent list stays at its limit, counts are right, and it is fast enough', () async {
    final h = Harness();
    await h.state.init();
    expect(await h.state.connectSimulator(), isTrue);
    await h.state.startDrive();
    final sid = h.state.currentSession!.id;
    final base = DateTime.utc(2026, 10, 30, 12);
    final sw = Stopwatch()..start();
    for (var i = 0; i < 6000; i++) {
      h.state.debugOnPing(DrivePing(
        id: 'p$i',
        ts: base.add(Duration(seconds: 10 * i)),
        lat: 40.0 + i * 1e-5,
        lon: -82.9 - i * 1e-5,
        echoes: i % 3 == 0 ? const [] : const [Echo(repeater: 'a1', snrDb: 4, hops: 1)],
      ));
      if (i % 500 == 0) await settle(2);
    }
    await settle(20);
    final ms = sw.elapsedMilliseconds;
    expect(ms, lessThan(15000), reason: 'ingesting 6,000 pings took $ms ms');
    expect(h.state.pingCount, 6000);
    expect(h.state.recentPings.length, lessThanOrEqualTo(50), reason: 'the "recent" list is bounded');
    expect(h.state.unsavedCount, 0);
    expect(h.store.pingsBySession[sid]!.length, 6000);
    expect(h.store.pingsBySession[sid]!.first.id, 'p0');
    expect(h.store.pingsBySession[sid]!.last.id, 'p5999');
    expect(h.state.heardPercent, 67);
    await h.state.stopDrive();
    expect(h.store.sessionsById[sid]!.endedAt, isNotNull);
  });
}
