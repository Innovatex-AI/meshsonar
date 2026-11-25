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
      ('driver', null, 'key-request'),
      ('driver', null, 'page-claims'),
      ('driver', null, 'delete-my-data'),
      ('driver', 'account-advanced', 'server-url'),
      ('radio', null, 'radio-tab-link'),
      ('radio', null, 'auto-connect'),
      ('radio', null, 'saved-radios'),
      ('radio', null, 'antenna-profile-abcdef0123'), // 0.4.0: one row per radio replaces the global type and gain
      ('wardriving', null, 'send-pings'),
      ('wardriving', null, 'channel'),
      ('wardriving', null, 'interval'),
      ('wardriving', null, 'min-distance'),
      ('wardriving', null, 'ping-feedback'),
      ('wardriving', null, 'battery-mode'),
      ('wardriving', 'uploads', 'auto-sync'),
      ('wardriving', 'uploads', 'sync-during-drive'),
      ('wardriving', 'uploads', 'sync-every'),
      ('wardriving', 'uploads', 'last-upload'),
      ('wardriving', 'battery', 'battery-running'),
      ('wardriving', 'battery', 'battery-gps'),
      ('wardriving', 'driving-advanced', 'listen-window'),
      ('wardriving', 'driving-advanced', 'ping-message'),
      ('wardriving', 'driving-advanced', 'ping-airtime'),
      ('wardriving', 'driving-advanced', 'wardrive-counters'),
      ('display', null, 'region-pick'),
      ('display', null, 'map-follow-options'),
      ('display', null, 'units-tile'),
      ('display', null, 'colour-palette'),
      ('display', null, 'heard-hold'),
      ('display', 'units', 'unit-distance'),
      ('privacy', null, 'telemetry-toggle'),
      ('privacy', null, 'privacy-location'),
      ('privacy', null, 'privacy-zones'),
      ('privacy', null, 'privacy-policy'),
      ('privacy', 'observer', 'observer-status'),
      ('privacy', 'observer', 'mqtt-add-feed'),
      ('privacy', 'sharing', 'collect-motion-toggle'),
      ('privacy', 'sharing', 'privacy-what-shared'),
      ('storage', null, 'diagnostics-log'),
      ('storage', null, 'report-problem'),
      ('storage', 'storage-items', 'storage-drives'),
      ('storage', 'storage-items', 'storage-region'),
      ('storage', 'storage-items', 'refresh-repeaters'),
      ('storage', 'diagnostics-advanced', 'map-health-overlay'),
      ('storage', 'diagnostics-advanced', 'diagnostics-power-counters'),
      ('about-section', null, 'about'),
      ('about-section', null, 'show-intro'),
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
    final titles = ['ACCOUNT', 'RADIO', 'DRIVING', 'MAP & DISPLAY', 'SHARING & PRIVACY', 'NOTIFICATIONS', 'STORAGE & DIAGNOSTICS', 'ABOUT'];
    await tester.scrollUntilVisible(find.text(titles.first), -120, scrollable: settingsList);
    for (final title in titles) {
      await tester.scrollUntilVisible(find.text(title), 120, scrollable: settingsList);
      expect(find.text(title), findsOneWidget);
    }
    // The removed features left no row behind.
    for (final gone in ['Offline maps', 'Simple basemap while driving']) {
      expect(find.textContaining(gone), findsNothing);
    }
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

  testWidgets('welcome tour can be reopened from Settings', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.byKey(const Key('show-intro')), 300, scrollable: scroll);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('show-intro')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsNothing);
    expect(find.byKey(const Key('settings-list')), findsOneWidget);
  });
}
