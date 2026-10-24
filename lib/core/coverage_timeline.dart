// Coverage-growth timeline (the "as of" slider on the network-coverage layer). Pure Dart.
//
// Where the region's first-data date comes from: `GET <region host>/api/cmh/region-timeline?res=9` answers
// `{status, days:[{day:'YYYY-MM-DD', newCells, totalCells}], res}` (verified live 2026-10-24 on cmh). The first
// entry's `day` is the first day with a measured cell. (The earliest cell `lastAt` was rejected: it is the LAST
// time a cell was measured, so it overstates the first-data date.) If the endpoint fails the slider is hidden
// behind an honest "timeline unavailable" note rather than guessing a start.
//
// The slider is day-stepped in UTC: step i means "everything measured before the end of day i", sent as
// `until = start of day i+1 (UTC)`. The last step (today) is live = no `until`. Day-aligned instants are already
// on the server's rounding grid (5 min inside the last 24 h, hourly before), so the same step always asks for
// the same bound and the cache key stays stable.
import 'package:flutter/foundation.dart' show immutable;

@immutable
class TimelineDay {
  final DateTime day; // UTC midnight
  final int newCells;
  final int totalCells;
  const TimelineDay(this.day, this.newCells, this.totalCells);
}

@immutable
class RegionTimeline {
  final List<TimelineDay> days;
  const RegionTimeline(this.days);

  DateTime? get firstDay => days.isEmpty ? null : days.first.day;

  /// Parses the region-timeline answer; null when there are no usable days.
  static RegionTimeline? parse(Object? json) {
    if (json is! Map) return null;
    final raw = json['days'];
    if (raw is! List) return null;
    final out = <TimelineDay>[];
    for (final d in raw) {
      if (d is! Map) continue;
      final s = d['day'];
      final t = s is String ? DateTime.tryParse(s) : null;
      if (t == null) continue;
      out.add(TimelineDay(
        DateTime.utc(t.year, t.month, t.day),
        d['newCells'] is num ? (d['newCells'] as num).toInt() : 0,
        d['totalCells'] is num ? (d['totalCells'] as num).toInt() : 0,
      ));
    }
    if (out.isEmpty) return null;
    out.sort((a, b) => a.day.compareTo(b.day));
    return RegionTimeline(out);
  }
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Oct 18, 2026" for a UTC day.
String timelineDayLabel(DateTime day) => '${_months[day.month - 1]} ${day.day}, ${day.year}';

/// Maps slider steps to `until` instants. Step 0 is the first data day, the last step is today (live).
@immutable
class TimelineScale {
  final DateTime first; // UTC midnight of the first data day
  final int steps; // number of day steps, first..today inclusive
  const TimelineScale._(this.first, this.steps);

  /// null when the slider would have nothing to scrub (first day is today or in the future).
  static TimelineScale? forRange(DateTime firstDay, DateTime now) {
    final f = DateTime.utc(firstDay.year, firstDay.month, firstDay.day);
    final n = now.toUtc();
    final today = DateTime.utc(n.year, n.month, n.day);
    final steps = today.difference(f).inDays + 1;
    return steps < 2 ? null : TimelineScale._(f, steps);
  }

  int get liveIndex => steps - 1;
  bool isLive(int i) => i >= liveIndex;

  int clamp(int i) => i < 0 ? 0 : (i > liveIndex ? liveIndex : i);

  /// The UTC day step i stands for.
  DateTime dayAt(int i) => DateTime.utc(first.year, first.month, first.day + clamp(i));

  /// Exclusive upper bound sent as `until`; null at the live step.
  DateTime? untilFor(int i) {
    if (isLive(i)) return null;
    final d = dayAt(i);
    return DateTime.utc(d.year, d.month, d.day + 1);
  }

  /// Step for a stored `until` (null = live).
  int indexOf(DateTime? until) {
    if (until == null) return liveIndex;
    final u = until.toUtc();
    final startOfDay = DateTime.utc(u.year, u.month, u.day);
    final day = startOfDay == u ? DateTime.utc(u.year, u.month, u.day - 1) : startOfDay;
    return clamp(day.difference(first).inDays);
  }

  /// "Coverage as of Oct 18, 2026" (UTC end of that day), or null at live.
  String? asOfLabel(int i) => isLive(i) ? null : 'Coverage as of ${timelineDayLabel(dayAt(i))}';

  /// The next step for play; null when playback has reached live.
  int? nextForPlay(int i) => isLive(i) ? null : i + 1;
}

/// Sliding-window request budget (the server allows 120 req/min per client; we keep headroom for the map's own
/// zoom/filter fetches). Injected clock so tests are deterministic.
class RateBudget {
  final int max;
  final Duration window;
  final DateTime Function() now;
  final List<DateTime> _stamps = [];
  RateBudget({this.max = 90, this.window = const Duration(minutes: 1), DateTime Function()? now}) : now = now ?? DateTime.now;

  void _trim() {
    final cut = now().subtract(window);
    _stamps.removeWhere((t) => !t.isAfter(cut));
  }

  /// Takes one slot if there is one.
  bool tryAcquire() {
    _trim();
    if (_stamps.length >= max) return false;
    _stamps.add(now());
    return true;
  }

  /// How long until a slot frees (zero when one is free now).
  Duration wait() {
    _trim();
    if (_stamps.length < max) return Duration.zero;
    return _stamps.first.add(window).difference(now());
  }
}
