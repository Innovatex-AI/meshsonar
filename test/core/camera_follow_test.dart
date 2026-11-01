import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/camera_follow.dart';

final _t = DateTime.utc(2026, 11, 1, 12);
DateTime at(num s) => _t.add(Duration(milliseconds: (s * 1000).round()));

void main() {
  test('follows by default; a gesture pauses at once and stays paused with a finger down', () {
    final f = CameraFollow(autoResume: const Duration(seconds: 10));
    expect(f.shouldDrive(at(0)), isTrue);
    f.pointerDown();
    expect(f.following, isTrue, reason: 'a touch alone is not a move (taps on buttons) ...');
    expect(f.shouldDrive(at(0.1)), isFalse, reason: '... but the camera holds still while a finger is down');
    f.userMoved(at(0.2));
    expect(f.following, isFalse);
    expect(f.shouldDrive(at(0.3)), isFalse, reason: 'never fights a finger');
    f.pointerUp(at(1));
    expect(f.shouldDrive(at(5)), isFalse);
  });

  test('auto-resume 10 s after the last touch, not before, not while a finger is down', () {
    final f = CameraFollow(autoResume: const Duration(seconds: 10));
    f.pointerDown();
    f.userMoved(at(0));
    f.pointerUp(at(2));
    expect(f.shouldDrive(at(11.9)), isFalse);
    expect(f.resumeIn(at(8))!.inSeconds, 4);
    expect(f.shouldDrive(at(12.0)), isTrue);
    expect(f.following, isTrue);
    // another gesture restarts the clock
    f.pointerDown();
    f.userMoved(at(20));
    expect(f.shouldDrive(at(60)), isFalse, reason: 'finger still down');
    f.pointerUp(at(61));
    expect(f.shouldDrive(at(70)), isFalse);
    expect(f.shouldDrive(at(71.1)), isTrue);
  });

  test('autoResume null: only resume() brings it back', () {
    final f = CameraFollow(autoResume: null);
    f.userMoved(at(0));
    expect(f.shouldDrive(at(1000)), isFalse);
    expect(f.resumeIn(at(1000)), isNull);
    f.resume();
    expect(f.shouldDrive(at(1001)), isTrue);
  });

  test('notifies on pause and resume only', () {
    final f = CameraFollow();
    var n = 0;
    f.addListener(() => n++);
    f.userMoved(at(0));
    f.userMoved(at(1));
    expect(n, 1);
    f.resume();
    f.resume();
    expect(n, 2);
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

  test('anchor: lower third of the free area, overlays respected', () {
    final a = followAnchor(width: 400, height: 800);
    expect(a.dx, 0);
    expect(a.dy, closeTo(800 * 0.66 - 400, 1e-9));
    final b = followAnchor(width: 400, height: 800, bottom: 200, left: 100);
    expect(b.dx, closeTo(50, 1e-9));
    expect(b.dy, closeTo(600 * 0.66 - 400, 1e-9));
    expect(followAnchor(width: 400, height: 800, fromTop: 0.5).dy, 0);
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
