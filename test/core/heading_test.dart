import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/heading.dart';

void main() {
  test('normalizeDeg and shortestArc wrap at north', () {
    expect(normalizeDeg(-10), 350);
    expect(normalizeDeg(370), 10);
    expect(shortestArc(359, 1), closeTo(2, 1e-9));
    expect(shortestArc(1, 359), closeTo(-2, 1e-9));
    expect(shortestArc(10, 190).abs(), closeTo(180, 1e-9));
    expect(shortestArc(90, 90), 0);
  });

  test('the smoother crosses north the short way and never spins', () {
    final h = HeadingSmoother();
    h.step(350, 0.016);
    final seen = <double>[];
    for (var i = 0; i < 120; i++) {
      seen.add(h.step(10, 0.016)); // target is 20 degrees clockwise, through north
    }
    for (var i = 1; i < seen.length; i++) {
      expect(shortestArc(seen[i - 1], seen[i]).abs(), lessThan(8), reason: 'small steps only, at frame $i');
    }
    expect(shortestArc(seen.last, 10).abs(), lessThan(0.5));
    // the path went 350 -> 360/0 -> 10, never down through 180
    expect(seen.every((d) => d > 340 || d < 20), isTrue);
  });

  test('turn rate is capped', () {
    final h = HeadingSmoother(maxRateDegPerS: 100);
    h.set(0);
    final v = h.step(180, 0.1);
    expect(v, closeTo(10, 1e-9));
  });

  group('compassHeading (tilt compensated)', () {
    // Field of the northern hemisphere: north component 20, down component 40 (microtesla).
    test('flat, top edge to the north / east / south / west', () {
      double? h(double mx, double my) => compassHeading(ax: 0, ay: 0, az: 9.8, mx: mx, my: my, mz: -40);
      expect(h(0, 20), closeTo(0, 0.01)); // top points at the field: north
      expect(h(-20, 0), closeTo(90, 0.01)); // facing east: the field is to the left of the phone
      expect(h(0, -20), closeTo(180, 0.01));
      expect(h(20, 0), closeTo(270, 0.01));
    });

    test('upright on a dash: the back of the phone decides', () {
      // Portrait, screen toward the driver: gravity along +y. Field = north component 20 + down component 40 (down = -y).
      // Back (-z) facing north => north is -z; facing east => the driver's right (x) is south, so north is -x.
      double? h(double mx, double mz) => compassHeading(ax: 0, ay: 9.8, az: 0, mx: mx, my: -40, mz: mz);
      expect(h(0, -20), closeTo(0, 0.01));
      expect(h(-20, 0), closeTo(90, 0.01));
      expect(h(0, 20), closeTo(180, 0.01));
      expect(h(20, 0), closeTo(270, 0.01));
    });

    test('rejects nonsense', () {
      expect(compassHeading(ax: 0, ay: 0, az: 0, mx: 1, my: 1, mz: 1), isNull);
      expect(compassHeading(ax: 0, ay: 0, az: 9.8, mx: 0, my: 0, mz: -40), isNull, reason: 'field parallel to gravity');
    });
  });
}
