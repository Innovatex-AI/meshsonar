// Round 2 N-U8 (build 77): the Network screens' times go through the app's one formatter and follow Settings > Map &
// display > Time zone; ages read the same everywhere; server per-day totals stay UTC and say so.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/region_cache.dart' show asOfLabel;
import 'package:meshsonar/core/time_format.dart';
import 'package:meshsonar/ui/network/channels/channel_ui.dart' show messageTimeText;
import 'package:meshsonar/ui/region/region_common.dart' show agoText;
import 'package:meshsonar/ui/tools/tool_kit.dart' show fmtAgo, fmtClock;

void main() {
  tearDown(() {
    activeTimeZone = TimeZonePreference.phone;
    use24HourClock = false;
  });
  final at = DateTime.utc(2026, 11, 25, 23, 13, 45);

  testWidgets('UTC setting: channel messages, radio tools and Trace Viewer times say UTC once', (t) async {
    activeTimeZone = TimeZonePreference.utc;
    late BuildContext ctx;
    await t.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    expect(messageTimeText(ctx, at, now: at.add(const Duration(minutes: 3))), '11:13 PM UTC');
    expect(messageTimeText(ctx, at, now: at.add(const Duration(days: 2))), 'Nov 25, 11:13 PM UTC');
    expect(fmtClock(at), '11:13:45 PM UTC');
    expect(timeOfDay(at, seconds: true), '11:13:45 PM UTC');
    use24HourClock = true;
    expect(fmtClock(at), '23:13:45 UTC');
  });

  test('ages: one wording everywhere', () {
    final now = at.add(const Duration(hours: 5));
    expect(asOfLabel(at, now, offline: true), 'Offline - as of 5 h ago');
    expect(asOfLabel(at, at.add(const Duration(minutes: 5)), offline: false), 'Updated 5 min ago');
    expect(asOfLabel(at, at, offline: true), 'Offline - just now');
    expect(agoText(at, now: now), '5 h ago');
    expect(agoText(null), 'never');
    expect(fmtAgo(const Duration(seconds: 40)), '40 s ago', reason: 'radio tools keep their seconds');
    expect(fmtAgo(const Duration(hours: 3)), '3 h ago');
  });

  test('server per-day totals stay UTC whatever the setting, and say so', () {
    expect(utcDayLabel(at), 'Nov 25 (UTC)');
    expect(utcLabel('Packets per day'), 'Packets per day (UTC)');
  });
}
