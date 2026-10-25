// Numbers behind the repeater detail's 30-day signal trend (`region-repeater` `snrDaily`). Pure Dart. Nothing is invented:
// a day without a reading is a gap, the trend sentence needs at least 7 days with readings, and an unweighted mean of
// the daily means is what is compared (each day counts once, however many adverts it had).
import 'repeater_detail_api.dart';

class SnrTrend {
  final int daysWithData; // of the days sent
  final int days;
  final int readings; // sum of n
  final double? minDb, maxDb, meanDb;
  final DailySnr? latest; // newest day WITH a reading
  final DailySnr? minDay, maxDay;

  /// How many days each side of the comparison holds; null when there are fewer than 7 days with readings.
  final int? compareDays;

  /// Mean of the newest [compareDays] days with readings minus the mean of the [compareDays] before them (dB); positive = stronger.
  final double? changeDb;
  const SnrTrend({
    required this.daysWithData,
    required this.days,
    required this.readings,
    this.minDb,
    this.maxDb,
    this.meanDb,
    this.latest,
    this.minDay,
    this.maxDay,
    this.compareDays,
    this.changeDb,
  });

  bool get hasData => daysWithData > 0;

  /// "Steady within 1 dB" / "About 2.5 dB stronger" ... over the compared days; null without enough days.
  String? get sentence {
    final c = changeDb, k = compareDays;
    if (c == null || k == null) return null;
    final what = 'The last $k days with readings against the $k before';
    if (c.abs() < 1) return '$what: steady within 1 dB.';
    return '$what: about ${c.abs().toStringAsFixed(1)} dB ${c > 0 ? 'stronger' : 'weaker'}.';
  }

  static SnrTrend of(List<DailySnr> daily) {
    final data = [for (final d in daily) if (d.meanDb != null && d.n > 0) d];
    if (data.isEmpty) return SnrTrend(daysWithData: 0, days: daily.length, readings: 0);
    var minD = data.first, maxD = data.first;
    var sum = 0.0;
    for (final d in data) {
      if (d.meanDb! < minD.meanDb!) minD = d;
      if (d.meanDb! > maxD.meanDb!) maxD = d;
      sum += d.meanDb!;
    }
    int? k;
    double? change;
    if (data.length >= 7) {
      k = data.length ~/ 2 < 7 ? data.length ~/ 2 : 7;
      double mean(Iterable<DailySnr> x) => x.map((e) => e.meanDb!).reduce((a, b) => a + b) / x.length;
      change = mean(data.sublist(data.length - k)) - mean(data.sublist(data.length - 2 * k, data.length - k));
    }
    return SnrTrend(
      daysWithData: data.length,
      days: daily.length,
      readings: data.fold(0, (a, d) => a + d.n),
      minDb: minD.meanDb,
      maxDb: maxD.meanDb,
      meanDb: sum / data.length,
      latest: data.last,
      minDay: minD,
      maxDay: maxD,
      compareDays: k,
      changeDb: change,
    );
  }
}
