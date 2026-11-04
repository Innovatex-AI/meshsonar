// remote_stats_history writer: one row per status read, trimmed to 7 days and 2000 rows per repeater.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/db/stats_history_repository.dart';
import 'package:meshsonar/chat/store.dart';

StatsPoint pt(int ts, {int mv = 3900}) => StatsPoint(tsMs: ts, batteryMv: mv, noiseFloor: -108, uptimeS: 1000, txAirS: 10, rxAirS: 20, recv: 5, sent: 6, lastRssi: -90, lastSnrX4: 26, errors: 2, queue: 1);

void main() {
  const day = 86400000;
  final key = 'ab' * 32;

  test('rows round-trip, oldest first, keyed per repeater', () {
    final s = ChatStore.inMemory();
    final h = s.statsHistory;
    h.insert(key, pt(1000, mv: 3800));
    h.insert(key, pt(2000, mv: 3900));
    h.insert('cd' * 32, pt(1500));
    final r = h.recent(key, nowMs: 3000);
    expect([for (final p in r) p.batteryMv], [3800, 3900]);
    expect(r.first.lastSnrX4, 26);
    expect(r.first.txAirPct, closeTo(1.0, 1e-9));
    expect(h.count('cd' * 32), 1);
    s.close();
  });

  test('anything older than 7 days is trimmed on insert and hidden from reads', () {
    final s = ChatStore.inMemory();
    final h = s.statsHistory;
    final now = 100 * day;
    h.insert(key, pt(now - 8 * day));
    h.insert(key, pt(now - 6 * day));
    h.insert(key, pt(now));
    expect(h.count(key), 2, reason: 'the 8 day old row was deleted by the newest insert');
    expect(h.recent(key, nowMs: now).length, 2);
    expect(h.recent(key, nowMs: now + 2 * day).length, 1, reason: 'reads only look back 7 days');
    s.close();
  });

  test('at most 2000 rows per repeater, keeping the newest', () {
    final s = ChatStore.inMemory();
    final h = s.statsHistory;
    final base = 50 * day;
    for (var i = 0; i < 2010; i++) {
      h.insert(key, pt(base + i * 1000, mv: 3000 + i));
    }
    h.insert('cd' * 32, pt(base));
    expect(h.count(key), 2000);
    final r = h.recent(key, nowMs: base + 2010 * 1000);
    expect(r.first.batteryMv, 3000 + 10);
    expect(r.last.batteryMv, 3000 + 2009);
    expect(h.count('cd' * 32), 1, reason: 'another repeater is not trimmed by this one');
    s.close();
  });
}
