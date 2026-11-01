import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';

void main() {
  testWidgets('settings are grouped into sections', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await openSettingsTab(tester);
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
    // Stream 6 restructure: Wardriving + Antenna became Radio, Upload became Drives & uploads, the heard-list hold moved
    // to Units & display, Report a problem to Diagnostics, Offline maps to Map & offline maps.
    for (final (section, field) in [
      ('driver', 'key-request'),
      ('driver', 'server-url'),
      ('region', 'region-pick'),
      ('display', 'units-tile'),
      ('display', 'heard-hold'),
      ('maps', 'offline-maps'),
      ('privacy', 'telemetry-toggle'),
      ('privacy', 'privacy-what-shared'),
      ('privacy', 'privacy-location'),
      ('privacy', 'privacy-zones-website'),
      ('radio', 'radio-tab-link'),
      ('wardriving', 'channel'),
      ('wardriving', 'send-pings'),
      ('wardriving', 'ping-message'),
      ('wardriving', 'ping-airtime'),
      ('wardriving', 'interval'),
      ('wardriving', 'min-distance'),
      ('wardriving', 'listen-window'),
      ('wardriving', 'wardrive-counters'),
      ('radio', 'antenna-profile-abcdef0123'), // 0.4.0: one row per radio replaces the global type and gain
      ('drives', 'auto-sync'),
      ('drives', 'sync-during-drive'),
      ('drives', 'sync-every'),
      ('drives', 'last-upload'),
      ('storage', 'storage-drives'),
      ('storage', 'storage-region'),
      ('storage', 'refresh-repeaters'),
      ('storage', 'storage-offline-maps'),
      ('diagnostics', 'diagnostics-log'),
      ('diagnostics', 'report-problem'),
      ('about-section', 'about'),
      ('about-section', 'show-intro'),
    ]) {
      await tester.scrollUntilVisible(find.byKey(Key(field)), 120, scrollable: scroll);
      expect(find.descendant(of: find.byKey(Key('section-$section')), matching: find.byKey(Key(field))), findsOneWidget,
          reason: '$field should be in $section');
    }
    await tester.scrollUntilVisible(find.text('ACCOUNT & DRIVER KEY'), -120, scrollable: scroll);
    for (final title in [
      'ACCOUNT & DRIVER KEY',
      'REGION',
      'UNITS & DISPLAY',
      'MAP & OFFLINE MAPS',
      'PRIVACY & DATA SHARING',
      'RADIO',
      'DRIVES & UPLOADS',
      'DATA & STORAGE',
      'DIAGNOSTICS',
      'ABOUT',
    ]) {
      await tester.scrollUntilVisible(find.text(title), 120, scrollable: scroll);
      expect(find.text(title), findsOneWidget);
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
