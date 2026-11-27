// Round 5 D-1 (decision 7): the drive verdict and its cut-offs, and the signal words used beside the numbers (D-2).
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/drive_stats.dart';
import 'package:meshsonar/core/model.dart';

void main() {
  group('DriveVerdict', () {
    DriveVerdict v(int tx, int heard, [List<double?> snr = const []]) => DriveVerdict.of(pings: tx, txPings: tx, heard: heard, pingSnr: snr);

    test('Good at 80% heard or more, Patchy from 40 to 79%, Poor below 40%', () {
      expect(v(10, 8).kind, DriveVerdictKind.good);
      expect(v(10, 10).kind, DriveVerdictKind.good);
      expect(v(100, 79).kind, DriveVerdictKind.patchy);
      expect(v(10, 4).kind, DriveVerdictKind.patchy);
      expect(v(100, 39).kind, DriveVerdictKind.poor);
      expect(v(30, 1).kind, DriveVerdictKind.poor);
    });

    test('the line: word, heard of sent, and the strength of the median reply', () {
      expect(v(3, 3, [10.5, 6, 7]).line, 'Good: heard on 3 of 3 pings, mostly strong');
      expect(v(30, 12).line, 'Patchy: heard on 12 of 30 pings');
      expect(v(30, 5, [-7, -8, null]).line, 'Poor: heard on 5 of 30 pings, mostly weak');
      expect(v(1, 1, [0.5]).line, 'Good: heard on 1 of 1 ping, mostly good');
    });

    test('nothing answered, listen-only and empty drives', () {
      expect(v(12, 0).line, 'Nothing answered');
      expect(DriveVerdict.of(pings: 40, txPings: 0, heard: 0).line, 'Listen-only drive');
      expect(DriveVerdict.of(pings: 0, txPings: 0, heard: 0).kind, DriveVerdictKind.empty);
    });

    test('from DriveStats: the same line the report computes', () {
      final t0 = DateTime.utc(2026, 11, 1, 12);
      final pings = [
        DrivePing(id: 'a', ts: t0, lat: 40, lon: -83, echoes: const [Echo(repeater: 'f5', snrDb: 9, hops: 1)]),
        DrivePing(id: 'b', ts: t0.add(const Duration(seconds: 30)), lat: 40, lon: -83),
      ];
      final st = DriveStats.of(DriveSession(id: 's', startedAt: t0), pings);
      expect(DriveVerdict.ofStats(st).line, 'Patchy: heard on 1 of 2 pings, mostly strong');
    });
  });

  test('signal words: strong from +5 dB, good from 0, fair from -5, weak below', () {
    expect(signalWord(5), 'Strong');
    expect(signalWord(4.9), 'Good');
    expect(signalWord(0), 'Good');
    expect(signalWord(-5), 'Fair');
    expect(signalWord(-5.1), 'Weak');
    expect(signalWords(10.5), 'Strong (10.5 dB)');
    expect(signalWords(null), '—');
  });
}
