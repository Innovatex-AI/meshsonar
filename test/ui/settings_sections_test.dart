import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';

import 'fakes.dart';

void main() {
  testWidgets('settings are grouped into sections', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
    for (final (section, field) in [
      ('driver', 'key-request'),
      ('driver', 'server-url'),
      ('wardriving', 'interval'),
      ('antenna', 'antenna-gain'),
      ('sync', 'auto-sync'),
      ('about-section', 'about'),
    ]) {
      await tester.scrollUntilVisible(find.byKey(Key(field)), 120, scrollable: scroll);
      expect(find.descendant(of: find.byKey(Key('section-$section')), matching: find.byKey(Key(field))), findsOneWidget,
          reason: '$field should be in $section');
    }
    for (final title in ['DRIVER & SERVER', 'WARDRIVING', 'ANTENNA', 'SYNC', 'ABOUT']) {
      await tester.scrollUntilVisible(find.text(title), -120, scrollable: scroll);
      expect(find.text(title), findsOneWidget);
    }
  });

  testWidgets('key status is a coloured badge', (tester) async {
    useTallScreen(tester);
    final h = Harness()..approveKey();
    await h.pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key-badge')), findsOneWidget);
    final approved = tester.widget<Text>(find.byKey(const Key('key-status'))).style!.color;
    expect(find.text('Approved'), findsOneWidget);

    h.client.statusResult = (status: DriverKeyStatus.revoked, display: 'KD8XYZ');
    await tester.tap(find.byKey(const Key('key-refresh')));
    await tester.pumpAndSettle();
    final revoked = tester.widget<Text>(find.byKey(const Key('key-status'))).style!.color;
    expect(find.text('Revoked'), findsOneWidget);
    expect(revoked, isNot(approved));
  });

  testWidgets('welcome tour can be reopened from Settings', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    await h.pumpApp(tester);
    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    final scroll = find.descendant(of: find.byKey(const Key('settings-list')), matching: find.byType(Scrollable)).first;
    await tester.drag(scroll, const Offset(0, -3000));
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
