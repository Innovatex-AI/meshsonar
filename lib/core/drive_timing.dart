// How well a drive kept its schedule: sent vs expected, the gap between consecutive pings (p50 / p95 / max), how late each ping
// went out against its due time, and why pings were skipped. Pure Dart; fed by DefaultWardriveEngine from its monotonic clock, shown on
// the drive-end screen and written to the shared trace. Honest by construction: every number is counted from what happened, none is
// a target.
import 'dart:math' as math;

/// The immutable result of [DriveTiming.summary].
class DriveTimingSummary {
  final int sent;

  /// Pings the interval called for over the time driven (rounded up: the first goes at once).
  final int expected;
  final double? gapP50S, gapP95S, gapMaxS;
  final double? lateP50S, lateP95S, lateMaxS;

  /// Seconds from starting the drive to the first ping; null when none went out.
  final double? firstPingS;

  /// Why pings were skipped or held, by reason: `no_fix`, `distance`, `budget`, ... Each entry counts one episode, not every check.
  final Map<String, int> skipped;

  /// Fixes the GPS delivered that the policy refused (cached on arrival, worse than the gate), for the drive.
  final int fixesRefused;

  /// Pings sent from a fix worse than 50 m.
  final int lowAccuracyPings;
  const DriveTimingSummary({
    required this.sent,
    required this.expected,
    this.gapP50S,
    this.gapP95S,
    this.gapMaxS,
    this.lateP50S,
    this.lateP95S,
    this.lateMaxS,
    this.firstPingS,
    this.skipped = const {},
    this.fixesRefused = 0,
    this.lowAccuracyPings = 0,
  });

  static String _s(double? v) => v == null ? '-' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} s';

  /// One plain-English line for the drive-end screen.
  String get line {
    if (sent == 0) return 'No pings were sent.';
    final parts = <String>['Sent $sent of $expected expected'];
    if (gapP50S != null) parts.add('typical gap ${_s(gapP50S)}, worst ${_s(gapMaxS)}');
    return parts.join('. ');
  }

  /// A second line when something was held back, else null.
  String? get skippedLine {
    if (skipped.isEmpty) return null;
    final names = {
      'no_fix': 'waiting for GPS',
      'first_fix': 'waiting for a good first fix',
      'distance': 'waiting to move',
      'budget': 'radio airtime budget',
      'radio_busy': 'radio busy',
    };
    return 'Held back: ${skipped.entries.map((e) => '${e.value}x ${names[e.key] ?? e.key}').join(', ')}';
  }

  Map<String, Object?> toJson() => {
        'sent': sent,
        'expected': expected,
        'gap_p50_s': gapP50S,
        'gap_p95_s': gapP95S,
        'gap_max_s': gapMaxS,
        'late_p50_s': lateP50S,
        'late_p95_s': lateP95S,
        'late_max_s': lateMaxS,
        'first_ping_s': firstPingS,
        'skipped': skipped,
        'fixes_refused': fixesRefused,
        'low_accuracy_pings': lowAccuracyPings,
      };
}

/// Reads back what [DriveTimingSummary.toJson] wrote (a `timing` record of the trace).
DriveTimingSummary timingFromJson(Map<String, dynamic> j) {
  double? d(String k) => (j[k] as num?)?.toDouble();
  int i(String k) => (j[k] as num?)?.toInt() ?? 0;
  final sk = j['skipped'];
  return DriveTimingSummary(
    sent: i('sent'),
    expected: i('expected'),
    gapP50S: d('gap_p50_s'),
    gapP95S: d('gap_p95_s'),
    gapMaxS: d('gap_max_s'),
    lateP50S: d('late_p50_s'),
    lateP95S: d('late_p95_s'),
    lateMaxS: d('late_max_s'),
    firstPingS: d('first_ping_s'),
    skipped: sk is Map ? {for (final e in sk.entries) '${e.key}': (e.value as num).toInt()} : const {},
    fixesRefused: i('fixes_refused'),
    lowAccuracyPings: i('low_accuracy_pings'),
  );
}

double? _q(List<double> sorted, double p) => sorted.isEmpty ? null : sorted[((sorted.length - 1) * p).round()];

class DriveTiming {
  final List<double> _gaps = [];
  final List<double> _late = [];
  final Map<String, int> _skipped = {};
  Duration? _startedAt;
  Duration? _firstSentAt;
  Duration? _lastSentAt;
  int _sent = 0;
  int _lowAcc = 0;
  int fixesRefused = 0;

  // Expected count: banked from earlier interval settings plus the running segment.
  double _bank = 0;
  Duration? _segStart;
  int _segIntervalSec = 0;

  /// The drive began at monotonic [now] with [intervalSec] (0 = manual only).
  void begin(Duration now, int intervalSec) {
    _startedAt = now;
    _segStart = now;
    _segIntervalSec = intervalSec;
  }

  /// The interval changed mid-drive.
  void intervalChanged(Duration now, int intervalSec) {
    if (_segStart == null) return;
    _bank += _segExpected(now);
    _segStart = now;
    _segIntervalSec = intervalSec;
  }

  double _segExpected(Duration now) {
    final s = _segStart;
    if (s == null || _segIntervalSec <= 0) return 0;
    return (now - s).inMilliseconds / 1000.0 / _segIntervalSec;
  }

  /// A tx ping went out at [at], [late] after it was due (never negative).
  void sent(Duration at, {required Duration late, bool lowAccuracy = false}) {
    final last = _lastSentAt;
    if (last != null) _gaps.add((at - last).inMilliseconds / 1000.0);
    _firstSentAt ??= at;
    _lastSentAt = at;
    _late.add(math.max(0, late.inMilliseconds) / 1000.0);
    _sent++;
    if (lowAccuracy) _lowAcc++;
  }

  /// One held-back episode of [reason].
  void skipped(String reason) => _skipped[reason] = (_skipped[reason] ?? 0) + 1;

  int get sentCount => _sent;

  DriveTimingSummary summary(Duration now) {
    final gaps = [..._gaps]..sort();
    final late = [..._late]..sort();
    final expected = (_bank + _segExpected(now)).ceil();
    final started = _startedAt, first = _firstSentAt;
    return DriveTimingSummary(
      sent: _sent,
      expected: math.max(expected, _sent == 0 ? expected : 1),
      gapP50S: _q(gaps, .5),
      gapP95S: _q(gaps, .95),
      gapMaxS: _q(gaps, 1),
      lateP50S: _q(late, .5),
      lateP95S: _q(late, .95),
      lateMaxS: _q(late, 1),
      firstPingS: started == null || first == null ? null : (first - started).inMilliseconds / 1000.0,
      skipped: Map.unmodifiable(_skipped),
      fixesRefused: fixesRefused,
      lowAccuracyPings: _lowAcc,
    );
  }
}
