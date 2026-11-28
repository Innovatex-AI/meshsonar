// Times on the Findings page. Until build 77 these were shown in the region's own IANA zone; Findings now follows
// Settings > Map & display > Time zone like every other screen (Round 2 decision 3), so both functions hand over to
// lib/core/time_format.dart. The zone argument is kept so current callers compile; it no longer changes the result.
import 'time_format.dart';

/// The abbreviation of the zone the app is showing at [at] ("EST", "EDT" or "UTC"). [zone] (the region's zone) is
/// no longer used.
String zoneAbbr(String? zone, DateTime at) => zoneLabel(at: at);

/// "Nov 10, 2026, 10:50 PM EST" in the zone the app is showing. Null input gives "—". [zone] (the region's zone) is
/// no longer used.
String formatInZone(DateTime? at, String? zone) => dateTime(at);
