// Personal progress (stream 5 D2/D6): ISO weeks in phone local time (incl. a year boundary and a drive late on a
// Sunday), weeks without holes, "new" cells and repeaters across drives (prefix rule), records, noise floor by local
// hour, TX power per drive, empty input, and a large store under a time budget.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/core/personal_progress.dart';

DateTime edt(DateTime t) => t.subtract(const Duration(hours: 4));

DrivePing ping(String id, DateTime ts, {double lat = 40.101, double lon = -82.93, List<Echo> echoes = const [], double? noise, double? tx}) =>
    DrivePing(id: id, ts: ts, lat: lat, lon: lon, echoes: echoes, noiseFloorDbm: noise, txDbm: tx);

(DriveSession, List<DrivePing>) drive(String id, DateTime start, List<DrivePing> pings) =>
    (DriveSession(id: id, startedAt: start, endedAt: start.add(const Duration(minutes: 30))), pings);

void main() {
  test('ISO week numbers, Monday start, across a year boundary', () {
    expect(isoWeekOf(DateTime.utc(2026, 10, 19)), (2026, 43));
    expect(isoWeekOf(DateTime.utc(2026, 10, 25)), (2026, 43)); // Sunday still week 43
    expect(isoWeekOf(DateTime.utc(2026, 12, 31)), (2026, 53)); // 2026 starts on a Thursday: 53 weeks
    expect(isoWeekOf(DateTime.utc(2027, 1, 3)), (2026, 53));
    expect(isoWeekOf(DateTime.utc(2027, 1, 4)), (2027, 1));
    expect(isoWeekOf(DateTime.utc(2024, 12, 30)), (2025, 1)); // a Monday in December that is week 1 of next year
    expect(isoMonday(DateTime.utc(2026, 10, 25)), DateTime.utc(2026, 10, 19));
    expect(isoMonday(DateTime.utc(2026, 10, 19)), DateTime.utc(2026, 10, 19));
  });

  test('a drive at 23:30 on a Sunday local time counts in that week, not the next (UTC is already Monday)', () {
    final sundayNightUtc = DateTime.utc(2026, 10, 19, 3, 30); // Sun Oct 18 23:30 EDT
    final p = PersonalProgress.compute([drive('a', sundayNightUtc, [ping('1', sundayNightUtc)])], wall: edt);
    expect(p.weeks.single.monday, DateTime.utc(2026, 10, 12));
    expect(p.weeks.single.isoWeek, 42);
  });

  test('weeks run without holes to now; distance, heard and novelty roll up per week', () {
    final w1 = DateTime.utc(2026, 10, 13, 15); // Tue Oct 13 (week 42)
    final w3 = DateTime.utc(2026, 10, 27, 15); // Tue Oct 27 (week 44)
    final p = PersonalProgress.compute([
      drive('b', w3, [
        ping('b1', w3, echoes: const [Echo(repeater: 'a1b2', snrDb: 2)]), // same repeater as 'a1' (prefix): not new
        ping('b2', w3.add(const Duration(minutes: 1)), lat: 40.201, echoes: const [Echo(repeater: 'ff', snrDb: 7.5)]), // new cell + new repeater
        ping('b3', w3.add(const Duration(minutes: 2)), lat: 40.201), // heard nothing
      ]),
      drive('a', w1, [
        ping('a1', w1, echoes: const [Echo(repeater: 'A1', snrDb: -3)]),
        ping('a2', w1.add(const Duration(minutes: 1)), lat: 40.1012),
      ]),
    ], now: DateTime.utc(2026, 11, 4, 12), wall: edt);

    expect(p.drives.map((d) => d.session.id), ['a', 'b']); // oldest first whatever the input order
    expect([for (final w in p.weeks) w.isoWeek], [42, 43, 44, 45]);
    expect([for (final w in p.weeks) w.drives], [1, 0, 1, 0]);
    final a = p.drives[0], b = p.drives[1];
    expect(a.newCells, 1); // both pings in one cell
    expect(a.newRepeaters, 1);
    expect(b.newCells, 1); // the 40.101 cell was seen before, 40.201 is new
    expect(b.newRepeaters, 1); // only 'ff'
    expect(p.totalCells, 2);
    expect(p.totalRepeaters, 2);
    expect([for (final w in p.weeks) w.totalCells], [1, 1, 2, 2]);
    expect(p.weeks[2].heardPercent, 67);
    expect(p.weeks[1].heardPercent, isNull); // no pings, not 0%
    expect(p.weeks[2].distanceM, greaterThan(11000)); // 0.1 degree north
    expect(p.heardPercent, 60);
    expect(p.bestSnr, 7.5);
    expect(p.record('best-snr')!.drive.session.id, 'b');
    expect(p.record('longest-distance')!.drive.session.id, 'b');
    expect(p.record('best-heard'), isNull, reason: 'no drive has 10 pings');
    expect(p.record('most-new-cells')!.drive.session.id, 'a', reason: 'tie: the earlier drive keeps it');
  });

  test('best heard % needs at least $minPingsForHeardRecord pings', () {
    final t = DateTime.utc(2026, 10, 20, 12);
    final small = drive('s', t, [ping('s1', t, echoes: const [Echo(repeater: 'aa')])]); // 100% of 1
    final big = drive('g', t.add(const Duration(days: 1)), [
      for (var i = 0; i < 10; i++)
        ping('g$i', t.add(Duration(days: 1, minutes: i)), echoes: i < 6 ? const [Echo(repeater: 'bb')] : const []),
    ]);
    final p = PersonalProgress.compute([small, big], wall: edt);
    expect(p.record('best-heard')!.drive.session.id, 'g');
  });

  test('my radio: noise floor median per drive, by local hour, and the TX power most pings used', () {
    final t = DateTime.utc(2026, 10, 20, 13); // 09:00 EDT
    final p = PersonalProgress.compute([
      drive('n', t, [
        ping('1', t, noise: -110, tx: 22),
        ping('2', t.add(const Duration(minutes: 1)), noise: -100, tx: 22),
        ping('3', t.add(const Duration(hours: 1)), noise: -90, tx: 20), // 10:00 EDT
      ]),
      drive('q', t.add(const Duration(days: 1)), [ping('4', t.add(const Duration(days: 1)))]), // radio reported nothing
    ], wall: edt);
    final n = p.drives.first;
    expect(n.noiseMedianDbm, -100);
    expect(n.noiseReadings, 3);
    expect(n.txDbm, 22);
    expect(p.drives.last.noiseMedianDbm, isNull);
    expect(p.drives.last.txDbm, isNull);
    expect(p.drivesWithNoise.map((d) => d.session.id), ['n']);
    expect([for (final h in p.noiseByHour) (h.hour, h.meanDbm, h.n)], [(9, -105.0, 2), (10, -90.0, 1)]);
  });

  test('no drives: empty, no weeks, no records', () {
    final p = PersonalProgress.compute(const []);
    expect(p.isEmpty, isTrue);
    expect(p.weeks, isEmpty);
    expect(p.records, isEmpty);
    expect(p.heardPercent, isNull);
  });

  test('100 drives of 1,000 pings each roll up in well under 2 s', () {
    final start = DateTime.utc(2026, 1, 5, 12);
    final drives = [
      for (var d = 0; d < 100; d++)
        drive('d$d', start.add(Duration(days: d * 2)), [
          for (var i = 0; i < 1000; i++)
            ping('d$d-$i', start.add(Duration(days: d * 2, seconds: i * 10)),
                lat: 40 + (d * 1000 + i) * 0.00005,
                echoes: i.isEven ? [Echo(repeater: ((i ~/ 2) % 200).toRadixString(16).padLeft(4, '0'), snrDb: 1)] : const [],
                noise: -105),
        ]),
    ];
    final sw = Stopwatch()..start();
    final p = PersonalProgress.compute(drives, wall: edt);
    sw.stop();
    expect(p.drives, hasLength(100));
    expect(p.totalRepeaters, 200);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
