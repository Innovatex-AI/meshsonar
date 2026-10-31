import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/passenger_lock.dart';

void main() {
  final now = DateTime(2026, 11, 1, 12);
  double kmh(double v) => v / 3.6;

  test('locks above 8 km/h while driving, unlocks below 6, holds in between', () {
    final l = PassengerLock();
    expect(l.update(driving: true, sessionId: 'a', speedMps: kmh(7), fixAt: now, now: now), isFalse);
    expect(l.locked, isFalse);
    expect(l.update(driving: true, sessionId: 'a', speedMps: kmh(8.5), fixAt: now, now: now), isTrue);
    expect(l.locked, isTrue);
    l.update(driving: true, sessionId: 'a', speedMps: kmh(7), fixAt: now, now: now);
    expect(l.locked, isTrue, reason: 'hysteresis');
    l.update(driving: true, sessionId: 'a', speedMps: kmh(5), fixAt: now, now: now);
    expect(l.locked, isFalse);
  });

  test('never locks when not driving, without a speed, or on a stale fix', () {
    final l = PassengerLock();
    l.update(driving: false, speedMps: kmh(90), fixAt: now, now: now);
    expect(l.locked, isFalse);
    l.update(driving: true, sessionId: 'a', speedMps: null, fixAt: now, now: now);
    expect(l.locked, isFalse);
    l.update(driving: true, sessionId: 'a', speedMps: kmh(90), fixAt: now.subtract(const Duration(minutes: 2)), now: now);
    expect(l.locked, isFalse);
  });

  test('passenger lifts the lock for this drive only', () {
    final l = PassengerLock();
    l.update(driving: true, sessionId: 'a', speedMps: kmh(60), fixAt: now, now: now);
    expect(l.locked, isTrue);
    l.setPassenger('a', true);
    l.update(driving: true, sessionId: 'a', speedMps: kmh(60), fixAt: now, now: now);
    expect(l.locked, isFalse);
    expect(l.isPassenger('a'), isTrue);
    // next drive asks again
    l.update(driving: true, sessionId: 'b', speedMps: kmh(60), fixAt: now, now: now);
    expect(l.locked, isTrue);
    expect(l.isPassenger('b'), isFalse);
    // and stopping the drive forgets it
    l.setPassenger('b', true);
    l.update(driving: false, now: now);
    l.update(driving: true, sessionId: 'b', speedMps: kmh(60), fixAt: now, now: now);
    expect(l.locked, isTrue);
  });
}
