import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/camera_follow.dart';

void main() {
  test('follows by default; a gesture pauses at once and the camera holds still with a finger down', () {
    final f = CameraFollow();
    expect(f.shouldDrive, isTrue);
    f.pointerDown();
    expect(f.following, isTrue, reason: 'a touch alone is not a move (taps on buttons) ...');
    expect(f.shouldDrive, isFalse, reason: '... but the camera holds still while a finger is down');
    f.userMoved();
    expect(f.following, isFalse);
    expect(f.shouldDrive, isFalse, reason: 'never fights a finger');
    f.pointerUp();
    expect(f.shouldDrive, isFalse);
  });

  test('no auto-resume: a moved map stays paused however long nothing touches it; only resume() (Recenter) brings it back', () {
    final f = CameraFollow();
    f.pointerDown();
    f.userMoved();
    f.pointerUp();
    for (var i = 0; i < 1000; i++) {
      expect(f.shouldDrive, isFalse);
    }
    f.resume();
    expect(f.shouldDrive, isTrue);
  });

  test('notifies on pause and resume only', () {
    final f = CameraFollow();
    var n = 0;
    f.addListener(() => n++);
    f.userMoved();
    f.userMoved();
    expect(n, 1);
    f.resume();
    f.resume();
    expect(n, 2);
  });

  test('keepInView: an offset inside the visible area is untouched; one under an overlay comes back inside', () {
    // 400 x 800 map, a 300 px panel at the bottom, 48 px margin: visible y from -400+48 to 400-300-48 = 52.
    final inside = keepInView(dx: 30, dy: -100, width: 400, height: 800, bottom: 300);
    expect(inside.dx, 30);
    expect(inside.dy, -100);
    final under = keepInView(dx: 0, dy: 200, width: 400, height: 800, bottom: 300);
    expect(under.dy, closeTo(52, 1e-9));
    final left = keepInView(dx: -300, dy: 0, width: 400, height: 800);
    expect(left.dx, closeTo(-200 + 48, 1e-9));
    // a tiny free area: the margin shrinks to a quarter of it, never inverts
    final tiny = keepInView(dx: 0, dy: 500, width: 400, height: 800, top: 380, bottom: 380);
    expect(tiny.dy, closeTo(10, 1e-9));
  });

  test('speed zoom: nothing in town, a gentle zoom-out on the highway, smooth in between', () {
    expect(speedZoomOffset(0), 0);
    expect(speedZoomOffset(5), 0);
    expect(speedZoomOffset(29), closeTo(-1.3, 1e-9));
    expect(speedZoomOffset(60), closeTo(-1.3, 1e-9));
    var prev = 0.0;
    for (var v = 6.0; v <= 29; v += 0.5) {
      final z = speedZoomOffset(v);
      expect(z, lessThanOrEqualTo(prev + 1e-12), reason: 'monotonic');
      expect((z - prev).abs(), lessThan(0.1), reason: 'no kink');
      prev = z;
    }
  });

  test('anchor: the middle of the free area by default (Recenter), overlays respected', () {
    final a = followAnchor(width: 400, height: 800);
    expect(a.dx, 0);
    expect(a.dy, 0);
    final b = followAnchor(width: 400, height: 800, bottom: 200, left: 100);
    expect(b.dx, closeTo(50, 1e-9));
    expect(b.dy, closeTo(600 * 0.5 - 400, 1e-9));
    expect(followAnchor(width: 400, height: 800, fromTop: 0.66).dy, closeTo(800 * 0.66 - 400, 1e-9));
  });

  test('easeToward converges and never overshoots', () {
    var v = 0.0;
    for (var i = 0; i < 600; i++) {
      v = easeToward(v, 1, 0.016, 1.5);
      expect(v, lessThanOrEqualTo(1));
    }
    expect(v, closeTo(1, 0.01));
    expect(headingUpRotation(90), -90);
  });
}
