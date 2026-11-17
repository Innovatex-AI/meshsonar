// Battery plan A10: a radio lost mid-drive is retried quickly, then every 20 s, then every 60 s after 5 min of failing;
// a new drop (after a success) starts quick again.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/radio/session_manager.dart';

void main() {
  test('1 s, 2 s per try up to 20 s, 60 s after 5 min of failing, quick again after reset', () {
    var now = DateTime.utc(2026, 11, 17, 12);
    final b = ReconnectBackoff(clock: () => now)..reset();
    final waits = <Duration>[];
    var elapsed = Duration.zero;
    for (var n = 1; elapsed < const Duration(minutes: 15); n++) {
      final d = b.delay(n);
      waits.add(d);
      elapsed += d;
      now = now.add(d);
    }
    expect(waits.take(4), const [Duration(seconds: 1), Duration(seconds: 4), Duration(seconds: 6), Duration(seconds: 8)]);
    expect(waits.where((d) => d > const Duration(seconds: 60)), isEmpty);
    // Before 5 min: never above 20 s; after: always 60 s.
    var t = Duration.zero;
    for (final d in waits) {
      if (t < const Duration(minutes: 5)) {
        expect(d, lessThanOrEqualTo(const Duration(seconds: 20)));
      } else {
        expect(d, const Duration(seconds: 60));
      }
      t += d;
    }
    // About 10 min at 60 s instead of 30 tries at 20 s.
    expect(waits.where((d) => d == const Duration(seconds: 60)).length, inInclusiveRange(9, 11));

    b.reset(); // reconnected, then lost again
    expect(b.delay(1), const Duration(seconds: 1));
    expect(b.delay(12), const Duration(seconds: 20));
  });
}
