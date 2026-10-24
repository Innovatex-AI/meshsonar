import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/coverage_query.dart';
import 'package:meshsonar/core/coverage_timeline.dart';

void main() {
  test('region-timeline parses, sorts and finds the first data day', () {
    final tl = RegionTimeline.parse({
      'days': [
        {'day': '2026-10-17', 'newCells': 143, 'totalCells': 150},
        {'day': '2026-10-16', 'newCells': 7, 'totalCells': 7},
        {'day': 'junk'},
      ],
    })!;
    expect(tl.firstDay, DateTime.utc(2026, 10, 16));
    expect(tl.days.length, 2);
    expect(RegionTimeline.parse({'days': []}), isNull);
    expect(RegionTimeline.parse('x'), isNull);
  });

  group('TimelineScale', () {
    final first = DateTime.utc(2026, 10, 16);
    final now = DateTime.utc(2026, 10, 24, 17, 30);
    final sc = TimelineScale.forRange(first, now)!;

    test('steps run first day..today, last is live', () {
      expect(sc.steps, 9);
      expect(sc.liveIndex, 8);
      expect(sc.isLive(8), isTrue);
      expect(sc.untilFor(8), isNull);
      expect(sc.untilFor(0), DateTime.utc(2026, 10, 17)); // everything on Oct 16
      expect(sc.untilFor(3), DateTime.utc(2026, 10, 20));
      expect(sc.asOfLabel(0), 'Coverage as of Oct 16, 2026');
      expect(sc.asOfLabel(8), isNull);
    });

    test('nothing to scrub when data starts today', () {
      expect(TimelineScale.forRange(DateTime.utc(2026, 10, 24), now), isNull);
      expect(TimelineScale.forRange(DateTime.utc(2026, 10, 23), now), isNotNull);
    });

    test('indexOf inverts untilFor and clamps', () {
      for (var i = 0; i < sc.liveIndex; i++) {
        expect(sc.indexOf(sc.untilFor(i)), i);
      }
      expect(sc.indexOf(null), sc.liveIndex);
      expect(sc.indexOf(DateTime.utc(2020)), 0);
    });

    test('play walks to live then stops', () {
      expect(sc.nextForPlay(0), 1);
      expect(sc.nextForPlay(7), 8);
      expect(sc.nextForPlay(8), isNull);
    });
  });

  test('RateBudget caps requests per window and frees slots', () {
    var t = DateTime.utc(2026, 10, 24, 12);
    final b = RateBudget(max: 3, now: () => t);
    expect([b.tryAcquire(), b.tryAcquire(), b.tryAcquire(), b.tryAcquire()], [true, true, true, false]);
    expect(b.wait(), const Duration(minutes: 1));
    t = t.add(const Duration(seconds: 40));
    expect(b.wait(), const Duration(seconds: 20));
    t = t.add(const Duration(seconds: 20));
    expect(b.wait(), Duration.zero);
    expect(b.tryAcquire(), isTrue);
  });

  test('CoverageQuery carries until in equality and copyWith', () {
    final u = DateTime.utc(2026, 10, 20);
    const q = CoverageQuery(res: 9);
    final q2 = q.copyWith(until: u);
    expect(q2.until, u);
    expect(q2 == q, isFalse);
    expect(q2.copyWith(res: 8).until, u, reason: 'other changes keep the as-of');
    expect(q2.copyWith(clearUntil: true), q);
  });
}
