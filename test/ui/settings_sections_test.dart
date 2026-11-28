import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

void main() {
  testWidgets('settings are grouped into sections', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    // Stream 6 restructure: Wardriving + Antenna became Radio, Upload became Drives & uploads, the heard-list hold moved
    // to Units & display, Report a problem to Diagnostics. Build 76: Map & offline maps became Map (the offline maps were removed).
    // Build 76 (Andy: "simplify the settings and group appropriately"): eight sections; rare rows are on a page of
    // their section (the third value), opened from the row `page-<id>`.
    for (final (section, page, field) in <(String, String?, String)>[
      ('driver', null, 'key-create'),
      ('driver', null, 'page-claims'),
      ('driver', null, 'delete-my-data'),
      ('driver', 'account-advanced', 'server-url'),
      ('radio', null, 'radio-tab-link'),
      ('radio', null, 'auto-connect'),
      ('radio', null, 'saved-radios'),
      ('radio', null, 'antenna-profile-abcdef0123'), // 0.4.0: one row per radio replaces the global type and gain
      ('wardriving', null, 'send-pings'),
      ('wardriving', null, 'interval'),
      ('wardriving', null, 'min-distance'),
      ('wardriving', null, 'ping-feedback'),
      ('wardriving', null, 'battery-mode'),
      ('wardriving', 'uploads', 'auto-sync'),
      ('wardriving', 'uploads', 'sync-every'),
      ('wardriving', 'uploads', 'last-upload'),
      ('wardriving', 'battery', 'battery-running'),
      ('wardriving', 'battery', 'battery-gps'),
      ('wardriving', 'driving-advanced', 'channel'), // build 77: set once, one level down
      ('wardriving', 'driving-advanced', 'heard-hold'), // build 77: "Keep repeaters lit", was Map & display > Heard list hold
      ('wardriving', 'driving-advanced', 'listen-window'),
      ('wardriving', 'driving-advanced', 'ping-message'),
      ('wardriving', 'driving-advanced', 'ping-airtime'),
      ('wardriving', 'driving-advanced', 'wardrive-counters'),
      ('display', null, 'region-pick'),
      ('display', null, 'map-follow-options'),
      ('display', null, 'units-tile'),
      ('display', null, 'colour-palette'),
      ('display', 'units', 'unit-distance'),
      ('privacy', null, 'telemetry-toggle'),
      ('privacy', null, 'privacy-location'),
      ('privacy', null, 'privacy-zones'),
      ('privacy', null, 'privacy-policy'),
      ('privacy', 'observer', 'observer-status'),
      ('privacy', 'observer', 'mqtt-add-feed'),
      ('privacy', 'sharing', 'collect-motion-toggle'),
      ('privacy', 'sharing', 'privacy-what-shared'),
      ('notifications', null, 'page-delivery'), // build 77: Messages, delivery and the chat rows first
      ('notifications', null, 'chat-quick-replies'),
      ('notifications', null, 'chat-return-sends'),
      ('notifications', null, 'chat-photos-autoload'),
      ('notifications', null, 'notif-enabled'),
      ('notifications', 'delivery', 'delivery-direct'),
      ('notifications', 'delivery', 'delivery-flood'),
      ('notifications', 'delivery', 'delivery-fallback'),
      ('notifications', 'delivery', 'delivery-confirm-twice'),
      ('storage', null, 'diagnostics-log'),
      ('storage', null, 'message-log'), // build 77: directly under the diagnostic log
      ('storage', null, 'report-problem'),
      ('storage', 'storage-items', 'storage-drives'),
      ('storage', 'storage-items', 'storage-region'),
      ('storage', 'storage-items', 'refresh-repeaters'),
      ('storage', 'diagnostics-advanced', 'map-health-overlay'),
      ('storage', 'diagnostics-advanced', 'diagnostics-power-counters'),
      ('about-section', null, 'about'),
      ('about-section', null, 'terms-of-service-link'),
    ]) {
      if (page == null) {
        await closeSettingsPage(tester);
        expect(find.byKey(Key(field)), findsOneWidget, reason: '$field should be on the first level');
        await tester.ensureVisible(find.byKey(Key(field)));
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(Key('section-$section')), matching: find.byKey(Key(field))), findsOneWidget,
            reason: '$field should be in $section');
      } else {
        await closeSettingsPage(tester);
        final opener = Key(page == 'units' ? 'units-per-quantity' : 'page-$page'); // units opens from a button in the Units row
        await tester.ensureVisible(find.byKey(opener));
        await tester.pumpAndSettle();
        expect(find.descendant(of: find.byKey(Key('section-$section')), matching: find.byKey(opener)), findsOneWidget,
            reason: 'the page $page opens from $section');
        await openSettingsPageRow(tester, page);
        expect(find.byKey(Key(field)), findsOneWidget, reason: '$field should be on the page $page');
      }
    }
    await closeSettingsPage(tester);
    final titles = ['ACCOUNT', 'RADIO', 'DRIVING', 'MAP & DISPLAY', 'SHARING & PRIVACY', 'MESSAGES', 'STORAGE & DIAGNOSTICS', 'ABOUT'];
    await tester.scrollUntilVisible(find.text(titles.first), -120, scrollable: settingsList);
    for (final title in titles) {
      await tester.scrollUntilVisible(find.text(title), 120, scrollable: settingsList);
      expect(find.text(title), findsOneWidget);
    }
    // The removed features left no row behind.
    for (final gone in ['Offline maps', 'Simple basemap while driving', 'Show the welcome tour', 'Heard list hold']) {
      expect(find.textContaining(gone), findsNothing);
    }
    // Build 77: the message log sits directly under the diagnostic log.
    await tester.ensureVisible(find.byKey(const Key('message-log')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const Key('message-log'))).dy, greaterThan(tester.getTopLeft(find.byKey(const Key('diagnostics-log'))).dy));
    expect(tester.getTopLeft(find.byKey(const Key('message-log'))).dy, lessThan(tester.getTopLeft(find.byKey(const Key('report-problem'))).dy));
  });

  testWidgets('key status is a coloured badge', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key-badge')), findsOneWidget);
    final approved = tester.widget<Text>(find.byKey(const Key('key-status'))).style!.color;
    expect(find.text('Ready to upload'), findsOneWidget);

    h.client.statusResult = (status: DriverKeyStatus.revoked, display: 'KD8XYZ');
    await tester.tap(find.byKey(const Key('key-refresh')));
    await tester.pumpAndSettle();
    final revoked = tester.widget<Text>(find.byKey(const Key('key-status'))).style!.color;
    expect(find.text('Switched off'), findsOneWidget);
    expect(revoked, isNot(approved));
  });

  testWidgets('build 77: the intro again is in Help only; searching Settings for it opens Help, and it replays from there', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('show-intro')), findsNothing, reason: 'no Settings row');
    await tester.enterText(find.byKey(const Key('settings-search')), 'welcome tour');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('search-result-show-intro')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('search-result-show-intro')), matching: find.textContaining('More > Help')), findsOneWidget);
    await tester.tap(find.byKey(const Key('search-result-show-intro')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('more-help-list')), findsOneWidget);
    await tester.tap(find.byKey(const Key('more-tour')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsNothing);
    expect(find.byKey(const Key('more-help-list')), findsOneWidget);
  });
}
