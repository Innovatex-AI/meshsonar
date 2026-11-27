// The one place the app turns an instant into words (Round 2 N-U8). Pure Dart.
//
// Every time a person reads goes through here and follows Settings > Map & display > Time zone: the phone's own time
// (the default) or UTC. Three things stay UTC whatever the setting, and say so: totals the server counts per UTC day
// or week, the diagnostics log, and exported reports. Those use the `utc...` helpers at the bottom.
//
// Shapes (phone's time / UTC):
//   timeOfDay      6:14 PM                      / 6:14 PM UTC
//   dateOnly       Nov 10, 2026                 / Nov 10, 2026
//   dateTime       Nov 10, 2026, 6:14 PM EST    / Nov 10, 2026, 6:14 PM UTC
//   shortDateTime  Nov 10, 6:14 PM              / Nov 10, 6:14 PM UTC
//   relativeTime   5 min ago (the same in both)
//   calendarDay    Today, Yesterday, Nov 10
//   hourLabel      6 PM                         / 6 PM
// The zone is always printed in UTC mode on anything with a clock time, and on full date+time in phone mode.

/// Settings > Map & display > Time zone.
enum TimeZonePreference {
  /// "My phone's time": the phone's own zone. The default.
  phone,

  /// "UTC".
  utc;

  /// Stored name to value; anything else (a missing field in an old settings file) is the default.
  static TimeZonePreference parse(Object? v) =>
      TimeZonePreference.values.firstWhere((e) => e.name == v, orElse: () => TimeZonePreference.phone);

  /// The words on the control.
  String get label => this == utc ? 'UTC' : 'My phone\'s time';
}

/// The choice every helper below follows. The app sets it when settings load and whenever they change.
TimeZonePreference activeTimeZone = TimeZonePreference.phone;

/// True when the phone is set to a 24-hour clock ("18:14" instead of "6:14 PM"). The app shell sets it from the
/// phone's own setting; pure Dart cannot read it.
bool use24HourClock = false;

/// The phone's wall-clock fields and zone abbreviation for a UTC instant. Tests replace it to get a fixed zone.
typedef LocalClock = ({DateTime wall, String abbr}) Function(DateTime utc);

/// Test seam: when set, "the phone's time" is this instead of the real zone of the machine running the code.
LocalClock? debugLocalClock;

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const String _none = '—';

String _two(int n) => n.toString().padLeft(2, '0');

/// "EST" as the platform gives it; a long name ("Eastern Standard Time") becomes "GMT-5".
String _abbrOf(DateTime local) {
  final n = local.timeZoneName;
  if (RegExp(r'^[A-Za-z]{2,5}$').hasMatch(n) || RegExp(r'^(GMT|UTC)[+-][0-9:]+$').hasMatch(n)) return n;
  final o = local.timeZoneOffset;
  if (o == Duration.zero) return 'GMT';
  final m = o.inMinutes.abs();
  return 'GMT${o.isNegative ? '-' : '+'}${m ~/ 60}${m % 60 == 0 ? '' : ':${_two(m % 60)}'}';
}

({DateTime wall, String abbr}) _resolve(DateTime t, TimeZonePreference? zone) {
  final u = t.toUtc();
  if ((zone ?? activeTimeZone) == TimeZonePreference.utc) return (wall: u, abbr: 'UTC');
  final d = debugLocalClock;
  if (d != null) return d(u);
  final l = u.toLocal();
  return (wall: l, abbr: _abbrOf(l));
}

bool _isUtc(TimeZonePreference? zone) => (zone ?? activeTimeZone) == TimeZonePreference.utc;

String _clock(DateTime w, bool seconds) {
  final s = seconds ? ':${_two(w.second)}' : '';
  if (use24HourClock) return '${_two(w.hour)}:${_two(w.minute)}$s';
  final h = w.hour % 12 == 0 ? 12 : w.hour % 12;
  return '$h:${_two(w.minute)}$s ${w.hour < 12 ? 'AM' : 'PM'}';
}

String _date(DateTime w, {required bool weekday, required bool year}) =>
    '${weekday ? '${_days[w.weekday - 1]}, ' : ''}${_months[w.month - 1]} ${w.day}${year ? ', ${w.year}' : ''}';

/// The date and clock fields of [t] in the chosen zone, for grouping by day or hour (chat day breaks, "busiest
/// hour"). Only the fields mean anything: do not do arithmetic with the result or send it anywhere.
DateTime wallClock(DateTime t, {TimeZonePreference? zone}) => _resolve(t, zone).wall;

/// Whether [a] and [b] fall on the same calendar day in the chosen zone.
bool sameDay(DateTime a, DateTime b, {TimeZonePreference? zone}) {
  final x = wallClock(a, zone: zone), y = wallClock(b, zone: zone);
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

/// The zone the app is showing, as an abbreviation at [at] (now when omitted): "EST", "EDT", or "UTC".
String zoneLabel({DateTime? at, TimeZonePreference? zone}) => _resolve(at ?? DateTime.now(), zone).abbr;

/// Time of day: "6:14 PM", with [seconds] "6:14:05 PM". UTC mode adds " UTC"; [showZone] forces the zone on or off.
String timeOfDay(DateTime? t, {bool seconds = false, bool? showZone, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  final r = _resolve(t, zone);
  final z = showZone ?? _isUtc(zone);
  return '${_clock(r.wall, seconds)}${z ? ' ${r.abbr}' : ''}';
}

/// A date: "Nov 10, 2026"; with [weekday] "Tue, Nov 10, 2026"; without [year] "Nov 10".
String dateOnly(DateTime? t, {bool weekday = false, bool year = true, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  return _date(wallClock(t, zone: zone), weekday: weekday, year: year);
}

/// A full date and time, zone always named: "Nov 10, 2026, 6:14 PM EST". [showZone] false drops the zone in phone
/// mode only (a row where the zone is named once nearby); UTC is always labelled.
String dateTime(DateTime? t,
    {bool seconds = false, bool weekday = false, bool showZone = true, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  final r = _resolve(t, zone);
  final z = showZone || _isUtc(zone);
  return '${_date(r.wall, weekday: weekday, year: true)}, ${_clock(r.wall, seconds)}${z ? ' ${r.abbr}' : ''}';
}

/// A date and time without the year, for recent things: "Nov 10, 6:14 PM" (UTC mode adds " UTC").
String shortDateTime(DateTime? t, {bool seconds = false, bool? showZone, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  final r = _resolve(t, zone);
  final z = showZone ?? _isUtc(zone);
  return '${_date(r.wall, weekday: false, year: false)}, ${_clock(r.wall, seconds)}${z ? ' ${r.abbr}' : ''}';
}

/// The time alone when [t] is today, otherwise the short date and time: "6:14 PM" / "Nov 10, 6:14 PM".
String timeOrShortDateTime(DateTime? t, {DateTime? now, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  return sameDay(t, now ?? DateTime.now(), zone: zone) ? timeOfDay(t, zone: zone) : shortDateTime(t, zone: zone);
}

/// How long ago, in plain words: "just now", "5 min ago", "3 h ago", "4 d ago". A time ahead of [now] (a clock that
/// is a little off) reads "just now". The same in both zones.
String relativeTime(DateTime? t, {DateTime? now, String ifNull = _none}) {
  if (t == null) return ifNull;
  return relativeDuration((now ?? DateTime.now()).toUtc().difference(t.toUtc()));
}

/// [relativeTime] for an age already known as a duration (a server "heard N seconds ago").
String relativeDuration(Duration age) {
  if (age.inSeconds < 90) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 48) return '${age.inHours} h ago';
  return '${age.inDays} d ago';
}

/// The day in words: "Today", "Yesterday", then "Nov 10", and with the year once it is not this year.
String calendarDay(DateTime? t, {DateTime? now, TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  final w = wallClock(t, zone: zone), n = wallClock(now ?? DateTime.now(), zone: zone);
  final days = DateTime.utc(n.year, n.month, n.day).difference(DateTime.utc(w.year, w.month, w.day)).inDays;
  if (days == 0) return 'Today';
  if (days == 1) return 'Yesterday';
  return _date(w, weekday: false, year: w.year != n.year);
}

/// An hour on a chart axis or in "busiest hour": "6 PM" ("18:00" on a 24-hour phone). No zone: name it once in the
/// caption with [zoneLabel].
String hourLabel(DateTime? t, {TimeZonePreference? zone, String ifNull = _none}) {
  if (t == null) return ifNull;
  return hourOfDayLabel(wallClock(t, zone: zone).hour);
}

/// [hourLabel] for an hour number 0 to 23 that is already in the right zone.
String hourOfDayLabel(int hour) {
  if (use24HourClock) return '${_two(hour)}:00';
  final h = hour % 12 == 0 ? 12 : hour % 12;
  return '$h ${hour < 12 ? 'AM' : 'PM'}';
}

/// The line under the Time zone setting: "Showing 6:14 PM EST".
String showingTimeLine(TimeZonePreference pref, {DateTime? now}) =>
    'Showing ${timeOfDay(now ?? DateTime.now(), showZone: true, zone: pref)}';

// ---------- always UTC, and labelled ----------
// For server totals counted per UTC day or week, the diagnostics log and exported reports. These never follow the
// setting: calling one of them local would be wrong.

/// Marks a caption as UTC: `utcLabel('per day')` is "per day (UTC)".
String utcLabel(String words) => '$words (UTC)';

/// Caption for totals the server counts per UTC day.
const String perDayUtc = 'per day (UTC)';

/// Caption for totals the server counts per UTC week (Monday to Sunday).
const String perWeekUtc = 'per week (UTC)';

/// A server UTC day as a label: "Nov 8 (UTC)"; with [year] "Nov 8, 2026 (UTC)". [label] false leaves the "(UTC)" off
/// for a table column whose heading already says UTC.
String utcDayLabel(DateTime? t, {bool year = false, bool label = true, String ifNull = _none}) {
  if (t == null) return ifNull;
  final d = _date(t.toUtc(), weekday: false, year: year);
  return label ? '$d (UTC)' : d;
}

/// An hour of the UTC day for server per-hour totals: "14:00 UTC".
String utcHourLabel(int hour, {bool label = true}) => '${_two(hour)}:00${label ? ' UTC' : ''}';

/// Exported reports: "2026-10-24 21:39 UTC"; with [seconds] "2026-10-24 21:39:07 UTC". [label] false leaves " UTC"
/// off for a column whose heading already says UTC.
String utcStamp(DateTime? t, {bool seconds = false, bool label = true, String ifNull = _none}) {
  if (t == null) return ifNull;
  final u = t.toUtc();
  return '${utcDate(u)} ${_two(u.hour)}:${_two(u.minute)}${seconds ? ':${_two(u.second)}' : ''}${label ? ' UTC' : ''}';
}

/// A diagnostics log line's time: "2026-11-01 10:00:00" (UTC; the log's heading says "times in UTC").
String utcLogStamp(DateTime t) => utcStamp(t, seconds: true, label: false);

/// A UTC calendar date: "2026-10-24".
String utcDate(DateTime? t, {String ifNull = _none}) {
  if (t == null) return ifNull;
  final u = t.toUtc();
  return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}';
}
