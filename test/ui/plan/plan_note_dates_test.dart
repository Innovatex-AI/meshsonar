import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/plan/plan_modes.dart' show planNoteWords;

void main() {
  test('plan notes say dates the app way (round 2 N-U8), whatever else they say', () {
    expect(planNoteWords('heard 1567 times in packets our observers heard, last 2026-11-27'),
        'heard 1567 times in packets our observers heard, last Nov 27, 2026');
    expect(planNoteWords('unobserved, estimate'), 'unobserved, estimate');
  });
}
