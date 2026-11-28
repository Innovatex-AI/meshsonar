// Settings > Map & display > Time zone (Round 2 N-U8, Round 5 S2): directly under Units, "My phone's time" by default
// or "UTC", with a line showing the result; the choice is saved with the other settings.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/time_format.dart';
import 'package:meshsonar/ui/settings/display_section.dart';

import '../settings_controls_test.dart' show openSettings, show;

({DateTime wall, String abbr}) _est(DateTime utc) {
  final w = utc.subtract(const Duration(hours: 5));
  return (wall: DateTime(w.year, w.month, w.day, w.hour, w.minute, w.second), abbr: 'EST');
}

void main() {
  setUp(() => debugLocalClock = _est);
  tearDown(() {
    debugLocalClock = null;
    activeTimeZone = TimeZonePreference.phone;
  });

  testWidgets('sits directly under Units, defaults to the phone\'s time and shows the result', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'time-zone-tile');
    expect(h.settings.saved.timeZone, TimeZonePreference.phone);

    final tile = find.byKey(const Key('time-zone-tile'));
    expect(find.descendant(of: tile, matching: find.text('Time zone')), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('My phone\'s time')), findsOneWidget);
    expect(find.descendant(of: tile, matching: find.text('UTC')), findsOneWidget);
    final seg = tester.widget<SegmentedButton<TimeZonePreference>>(find.byKey(const Key('time-zone-selector')));
    expect(seg.selected, {TimeZonePreference.phone});
    final line = tester.widget<Text>(find.byKey(const Key('time-zone-showing'))).data!;
    expect(line, matches(RegExp(r'^Showing \d{1,2}:\d\d (AM|PM) EST$')));

    // Row order in Map & display: Units, then Time zone, then Colour palette.
    final rows = displaySectionRows(tester.element(tile));
    final ids = [for (final r in rows) (r as dynamic).id as String];
    expect(ids.indexOf('time-zone'), ids.indexOf('units-tile') + 1);
    expect(tester.getTopLeft(tile).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('units-tile'))).dy));
    expect(tester.getTopLeft(tile).dy, lessThan(tester.getTopLeft(find.byKey(const Key('colour-palette'))).dy));
  });

  testWidgets('choosing UTC saves it and the line says UTC; choosing the phone again goes back', (tester) async {
    final h = await openSettings(tester);
    await show(tester, 'time-zone-tile');
    await tester.tap(find.byKey(const Key('time-zone-utc')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.timeZone, TimeZonePreference.utc);
    expect(h.settings.saved.toJson()['time_zone'], 'utc');
    expect(tester.widget<Text>(find.byKey(const Key('time-zone-showing'))).data!, matches(RegExp(r'^Showing \d{1,2}:\d\d (AM|PM) UTC$')));

    await tester.tap(find.byKey(const Key('time-zone-phone')));
    await tester.pumpAndSettle();
    expect(h.settings.saved.timeZone, TimeZonePreference.phone);
    expect(tester.widget<Text>(find.byKey(const Key('time-zone-showing'))).data!, endsWith(' EST'));
  });

  testWidgets('a saved UTC choice is shown selected when Settings opens', (tester) async {
    await openSettings(tester, settings: const Settings(timeZone: TimeZonePreference.utc));
    await show(tester, 'time-zone-tile');
    final seg = tester.widget<SegmentedButton<TimeZonePreference>>(find.byKey(const Key('time-zone-selector')));
    expect(seg.selected, {TimeZonePreference.utc});
  });

  testWidgets('the line is worked out from the setting: 6:14 PM EST, or 11:14 PM UTC', (tester) async {
    expect(showingTimeLine(TimeZonePreference.phone, now: DateTime.utc(2026, 11, 10, 23, 14)), 'Showing 6:14 PM EST');
    expect(showingTimeLine(TimeZonePreference.utc, now: DateTime.utc(2026, 11, 10, 23, 14)), 'Showing 11:14 PM UTC');
  });
}
