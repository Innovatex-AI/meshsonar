// Times in a region's own IANA zone with its abbreviation ("Nov 10, 2026, 10:50 PM EST"), the way the website shows
// them (docs/analyze-contract.md "Time"). Pure Dart (the `timezone` package is pure Dart). A missing or unknown zone
// falls back to UTC and SAYS so ("UTC"); it never silently uses the phone's zone.
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _ready = false;
void _init() {
  if (_ready) return;
  tzdata.initializeTimeZones();
  _ready = true;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

tz.Location? _location(String? zone) {
  if (zone == null || zone.isEmpty) return null;
  _init();
  try {
    return tz.getLocation(zone);
  } catch (_) {
    return null;
  }
}

/// The zone abbreviation at [at] ("EST", "EDT"); "UTC" when [zone] is missing or unknown.
String zoneAbbr(String? zone, DateTime at) {
  final loc = _location(zone);
  if (loc == null) return 'UTC';
  return tz.TZDateTime.from(at.toUtc(), loc).timeZone.abbreviation;
}

/// "Nov 10, 2026, 10:50 PM EST" in [zone] (UTC when unknown). Null input gives "—".
String formatInZone(DateTime? at, String? zone) {
  if (at == null) return '—';
  final loc = _location(zone);
  final d = loc == null ? at.toUtc() : tz.TZDateTime.from(at.toUtc(), loc);
  final abbr = loc == null ? 'UTC' : (d as tz.TZDateTime).timeZone.abbreviation;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  return '${_months[d.month - 1]} ${d.day}, ${d.year}, $h:$m ${d.hour < 12 ? 'AM' : 'PM'} $abbr';
}
