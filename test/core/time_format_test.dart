// The one time formatter (Round 2 N-U8): every helper in the phone's time and in UTC, the legacy shapes in
// lib/ui/widgets.dart and lib/core/zone_time.dart that now sit on top of it, and the always-UTC labels.
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/time_format.dart';
import 'package:meshsonar/core/zone_time.dart';
import 'package:meshsonar/ui/widgets.dart' show formatDateTime, formatTime;

/// A fixed "phone" five hours behind UTC, called EST, so results do not depend on the machine running the test.
({DateTime wall, String abbr}) _est(DateTime utc) {
  final w = utc.subtract(const Duration(hours: 5));
  return (wall: DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second), abbr: 'EST');
}

void main() {
  final t = DateTime.utc(2026, 11, 10, 23, 14, 5); // 6:14:05 PM EST
  setUp(() {
    debugLocalClock = _est;
    activeTimeZone = TimeZonePreference.phone;
    use24HourClock = false;
  });
  tearDown(() {
    debugLocalClock = null;
    activeTimeZone = TimeZonePreference.phone;
    use24HourClock = false;
  });

  group('the setting', () {
    test('defaults to the phone, and anything unknown parses as the default', () {
      expect(activeTimeZone, TimeZonePreference.phone);
      expect(TimeZonePreference.parse(null), TimeZonePreference.phone);
      expect(TimeZonePreference.parse('nonsense'), TimeZonePreference.phone);
      expect(TimeZonePreference.parse('utc'), TimeZonePreference.utc);
      expect(TimeZonePreference.phone.label, 'My phone\'s time');
      expect(TimeZonePreference.utc.label, 'UTC');
    });

    test('the line under the setting shows the result with its zone', () {
      expect(showingTimeLine(TimeZonePreference.phone, now: t), 'Showing 6:14 PM EST');
      expect(showingTimeLine(TimeZonePreference.utc, now: t), 'Showing 11:14 PM UTC');
    });
  });

  group('phone time (default)', () {
    test('time of day', () {
      expect(timeOfDay(t), '6:14 PM');
      expect(timeOfDay(t, seconds: true), '6:14:05 PM');
      expect(timeOfDay(t, showZone: true), '6:14 PM EST');
      expect(timeOfDay(DateTime.utc(2026, 11, 10, 5, 3)), '12:03 AM');
      expect(timeOfDay(DateTime.utc(2026, 11, 10, 17, 0)), '12:00 PM');
      expect(timeOfDay(null), '—');
      expect(timeOfDay(null, ifNull: 'unknown'), 'unknown');
    });

    test('date, date and time', () {
      expect(dateOnly(t), 'Nov 10, 2026');
      expect(dateOnly(t, weekday: true), 'Tue, Nov 10, 2026');
      expect(dateOnly(t, year: false), 'Nov 10');
      expect(dateTime(t), 'Nov 10, 2026, 6:14 PM EST');
      expect(dateTime(t, seconds: true, weekday: true), 'Tue, Nov 10, 2026, 6:14:05 PM EST');
      expect(dateTime(t, showZone: false), 'Nov 10, 2026, 6:14 PM');
      expect(shortDateTime(t), 'Nov 10, 6:14 PM');
      expect(shortDateTime(t, seconds: true), 'Nov 10, 6:14:05 PM');
      expect(dateTime(null), '—');
    });

    test('the day is the phone\'s day, not the UTC day', () {
      final late = DateTime.utc(2026, 11, 11, 3, 50); // still Nov 10 in EST
      expect(dateOnly(late), 'Nov 10, 2026');
      expect(dateTime(late), 'Nov 10, 2026, 10:50 PM EST');
      expect(sameDay(late, t), isTrue);
      expect(wallClock(late).day, 10);
    });

    test('a local DateTime gives the same answer as the same instant in UTC', () {
      expect(timeOfDay(t.toLocal(), seconds: true), timeOfDay(t, seconds: true));
    });

    test('24-hour phones get a 24-hour clock', () {
      use24HourClock = true;
      expect(timeOfDay(t), '18:14');
      expect(timeOfDay(t, seconds: true), '18:14:05');
      expect(dateTime(t), 'Nov 10, 2026, 18:14 EST');
      expect(hourLabel(t), '18:00');
    });

    test('zone label and hour label', () {
      expect(zoneLabel(at: t), 'EST');
      expect(hourLabel(t), '6 PM');
      expect(hourOfDayLabel(0), '12 AM');
      expect(hourOfDayLabel(12), '12 PM');
    });

    test('without the test seam it follows the machine\'s own zone', () {
      debugLocalClock = null;
      final l = t.toLocal();
      expect(wallClock(t).hour, l.hour);
      expect(wallClock(t).day, l.day);
      expect(zoneLabel(at: t), isNotEmpty);
      expect(zoneLabel(at: t).contains(' '), isFalse, reason: 'an abbreviation or GMT offset, never a long name');
    });
  });

  group('UTC', () {
    setUp(() => activeTimeZone = TimeZonePreference.utc);

    test('every clock time says UTC, once', () {
      expect(timeOfDay(t), '11:14 PM UTC');
      expect(timeOfDay(t, seconds: true), '11:14:05 PM UTC');
      expect(dateTime(t), 'Nov 10, 2026, 11:14 PM UTC');
      expect(dateTime(t, showZone: false), 'Nov 10, 2026, 11:14 PM UTC', reason: 'UTC is always labelled');
      expect(shortDateTime(t), 'Nov 10, 11:14 PM UTC');
      expect(zoneLabel(at: t), 'UTC');
      for (final s in [timeOfDay(t), dateTime(t), shortDateTime(t, seconds: true)]) {
        expect('UTC'.allMatches(s).length, 1, reason: s);
      }
    });

    test('the day is the UTC day', () {
      final late = DateTime.utc(2026, 11, 11, 3, 50);
      expect(dateOnly(late), 'Nov 11, 2026');
      expect(sameDay(late, t), isFalse);
    });

    test('a single call can ask for the other zone', () {
      expect(timeOfDay(t, zone: TimeZonePreference.phone), '6:14 PM');
      activeTimeZone = TimeZonePreference.phone;
      expect(timeOfDay(t, zone: TimeZonePreference.utc), '11:14 PM UTC');
    });
  });

  group('relative and day words', () {
    final now = DateTime.utc(2026, 11, 10, 23, 14, 5);
    test('"5 min ago"', () {
      expect(relativeTime(now.subtract(const Duration(seconds: 30)), now: now), 'just now');
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
      expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now), '3 h ago');
      expect(relativeTime(now.subtract(const Duration(days: 4)), now: now), '4 d ago');
      expect(relativeTime(now.add(const Duration(minutes: 2)), now: now), 'just now', reason: 'a clock a little ahead');
      expect(relativeTime(null), '—');
      expect(relativeDuration(const Duration(minutes: 59)), '59 min ago');
      activeTimeZone = TimeZonePreference.utc;
      expect(relativeTime(now.subtract(const Duration(minutes: 5)), now: now), '5 min ago');
    });

    test('Today, Yesterday, then the date', () {
      expect(calendarDay(now, now: now), 'Today');
      expect(calendarDay(now.subtract(const Duration(days: 1)), now: now), 'Yesterday');
      expect(calendarDay(DateTime.utc(2026, 11, 2, 15), now: now), 'Nov 2');
      expect(calendarDay(DateTime.utc(2025, 12, 31, 15), now: now), 'Dec 31, 2025');
      // 03:50 UTC on the 11th is still "today" on an EST phone at 6:14 PM on the 10th, and tomorrow's date in UTC.
      final late = DateTime.utc(2026, 11, 11, 3, 50);
      expect(calendarDay(late, now: now), 'Today');
      expect(timeOrShortDateTime(late, now: now), '10:50 PM');
      expect(timeOrShortDateTime(DateTime.utc(2026, 11, 2, 15), now: now), 'Nov 2, 10:00 AM');
    });
  });

  group('always UTC, whatever the setting', () {
    test('server totals, log and export labels', () {
      for (final z in TimeZonePreference.values) {
        activeTimeZone = z;
        expect(utcLabel('per day'), 'per day (UTC)');
        expect(perDayUtc, 'per day (UTC)');
        expect(perWeekUtc, 'per week (UTC)');
        expect(utcDayLabel(t), 'Nov 10 (UTC)');
        expect(utcDayLabel(t, year: true), 'Nov 10, 2026 (UTC)');
        expect(utcDayLabel(t, label: false), 'Nov 10');
        expect(utcHourLabel(14), '14:00 UTC');
        expect(utcStamp(DateTime.utc(2026, 10, 24, 21, 39, 7)), '2026-10-24 21:39 UTC');
        expect(utcStamp(t, seconds: true), '2026-11-10 23:14:05 UTC');
        expect(utcStamp(t, label: false), '2026-11-10 23:14');
        expect(utcLogStamp(DateTime.utc(2026, 11, 1, 10)), '2026-11-01 10:00:00');
        expect(utcDate(t), '2026-11-10');
        expect(utcStamp(null), '—');
      }
    });

    test('a local DateTime is converted, not relabelled', () {
      expect(utcStamp(t.toLocal(), seconds: true), '2026-11-10 23:14:05 UTC');
    });
  });

  group('older functions follow the setting', () {
    test('formatTime and formatDateTime keep their shape (callers slice them)', () {
      expect(formatTime(t), '18:14:05');
      expect(formatTime(t).substring(0, 5), '18:14');
      expect(formatDateTime(t), 'Tue 10 Nov 2026, 18:14');
      activeTimeZone = TimeZonePreference.utc;
      expect(formatTime(t), '23:14:05 UTC');
      expect(formatTime(t).substring(0, 5), '23:14');
      expect(formatDateTime(t), 'Tue 10 Nov 2026, 23:14 UTC');
    });

    test('Findings times (formatInZone, zoneAbbr) follow the setting, not the region zone', () {
      final late = DateTime.utc(2026, 11, 11, 3, 50);
      expect(formatInZone(late, 'America/Los_Angeles'), 'Nov 10, 2026, 10:50 PM EST');
      expect(zoneAbbr('America/Los_Angeles', late), 'EST');
      expect(formatInZone(null, 'America/New_York'), '—');
      activeTimeZone = TimeZonePreference.utc;
      expect(formatInZone(late, 'America/Los_Angeles'), 'Nov 11, 2026, 3:50 AM UTC');
      expect(zoneAbbr(null, late), 'UTC');
    });
  });
}
