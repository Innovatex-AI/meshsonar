// Settings > Account without a driver key (build 76): one small card on the first level, not a form. "Create my key"
// opens the form (name, callsign, email, all optional) on its own page; "I already have a key" opens the paste field;
// Devices and keys is a normal row; the privacy policy is on the form and once on the first level (its own row).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/api.dart';
import 'package:meshsonar/core/server_url.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/account_section.dart';
import 'package:meshsonar/ui/settings/settings_kit.dart';

import 'fakes.dart';
import 'settings_test_kit.dart';

Future<Harness> open(WidgetTester tester, {double w = 402, double h = 874, double scale = 1.0}) async {
  tester.view.devicePixelRatio = 3.0;
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final harness = Harness();
  await harness.state.init();
  await tester.pumpWidget(MeshSonarApp(state: harness.state));
  await tester.pump();
  await openSettingsTab(tester);
  await tester.pumpAndSettle();
  return harness;
}

Future<void> search(WidgetTester tester, String q) async {
  await tester.scrollUntilVisible(find.byKey(const Key('settings-search')), -300, scrollable: settingsList);
  await tester.enterText(find.byKey(const Key('settings-search')), q);
  await tester.pumpAndSettle();
}

Future<void> openForm(WidgetTester tester) async {
  await showSetting(tester, 'key-create');
  await tester.tap(find.byKey(const Key('key-create')));
  await tester.pumpAndSettle();
  expect(find.byType(CreateKeyScreen), findsOneWidget);
}

void main() {
  for (final w in [320.0, 375.0, 402.0, 430.0]) {
    testWidgets('no key at ${w.toInt()} pt: a small card, no form on the first level', (tester) async {
      await open(tester, w: w);
      expect(tester.takeException(), isNull);
      final card = find.byType(DriverKeySection);
      expect(card, findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('Driver key')), findsOneWidget);
      expect(find.descendant(of: card, matching: find.text('No key')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('key-line'))).data, 'Lets this phone upload drives. Without one, drives stay on this phone.');
      expect(find.textContaining('Without one, drives stay on this phone'), findsOneWidget, reason: 'said once, not above the card as well');
      for (final k in ['key-name', 'key-callsign', 'key-email', 'key-request', 'key-paste', 'key-privacy-policy']) {
        expect(find.byKey(Key(k)), findsNothing, reason: '$k is not on the first level');
      }
      expect(find.descendant(of: card, matching: find.byType(TextField)), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Create my key'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('key-have')), matching: find.text('I already have a key')), findsOneWidget);
      for (final k in ['key-create', 'key-have', 'key-website']) {
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: '$k is a 48 pt target');
      }
      // Devices and keys is a normal row with a chevron.
      final row = tester.widget<ListTile>(find.byKey(const Key('key-website')));
      expect((row.title! as Text).data, 'Devices and keys');
      expect(row.trailing, isNotNull);
      // The whole card with its row. The test font is about twice as wide as the phone's, so the texts wrap twice as
      // often here: on a phone this is about 290 pt (the form was more than a full screen, 700 pt and up in this font).
      expect(tester.getSize(card).height, lessThan(500));
      // The privacy policy shows once on the first level: its own row under Sharing & privacy.
      expect(find.text('Privacy policy'), findsOneWidget);
      expect(find.byKey(const Key('privacy-policy')), findsOneWidget);
    });
  }

  testWidgets('no key at 1.3x text on 320 pt: lays out', (tester) async {
    await open(tester, w: 320, h: 568, scale: 1.3);
    expect(tester.takeException(), isNull);
    await openForm(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Create my key opens the form; all three fields are optional; the page closes when the key is there', (tester) async {
    final h = await open(tester);
    await openForm(tester);
    expect(find.textContaining('All three fields are optional; only the callsign is public.'), findsOneWidget);
    expect(find.text('Name (optional)'), findsOneWidget);
    expect(find.text('Callsign (optional)'), findsOneWidget);
    expect(find.text('Email (optional)'), findsOneWidget);
    expect(find.text('Shown in public. Empty: "Driver N".'), findsOneWidget);
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(h.client.lastRequest, {'name': 'MeshSonar driver', 'callsign': null, 'email': null});
    expect(find.byType(CreateKeyScreen), findsNothing, reason: 'back in Settings');
    expect(h.state.hasKey, isTrue);
    expect(find.byKey(const Key('key-badge')), findsOneWidget);
    expect(find.byKey(const Key('key-create')), findsNothing);
    expect(find.byKey(const Key('forget-key')), findsOneWidget, reason: 'the key can be removed');
  });

  testWidgets('the form sends name, callsign and email; a bad email is caught before anything is sent', (tester) async {
    final h = await open(tester);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('key-name')), 'Andy');
    await tester.enterText(find.byKey(const Key('key-callsign')), 'KD8XYZ');
    await tester.enterText(find.byKey(const Key('key-email')), 'andy');
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(find.text('That doesn\'t look like an email'), findsOneWidget);
    expect(h.client.lastRequest, isNull);
    await tester.enterText(find.byKey(const Key('key-email')), 'andy@example.org');
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(h.client.lastRequest, {'name': 'Andy', 'callsign': 'KD8XYZ', 'email': 'andy@example.org'});
    expect(find.byType(CreateKeyScreen), findsNothing);
  });

  testWidgets('a failed request stays on the form with what was typed; Back returns to the card', (tester) async {
    final h = await open(tester);
    h.client.requestError = const CmatException('', status: 503);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('key-callsign')), 'KD8XYZ');
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateKeyScreen), findsOneWidget);
    expect(find.descendant(of: find.byType(CreateKeyScreen), matching: find.textContaining('The server had a problem (503)')), findsOneWidget);
    expect(find.text('KD8XYZ'), findsOneWidget);
    h.client.requestError = null;
    await tester.tap(find.byKey(const Key('key-request')));
    await tester.pumpAndSettle();
    expect(find.byType(CreateKeyScreen), findsNothing);
    expect(h.settings.saved.driverKey, isNotNull);
  });

  testWidgets('the privacy policy is one tap from the form', (tester) async {
    final h = await open(tester);
    await openForm(tester);
    await tester.tap(find.byKey(const Key('key-privacy-policy')));
    await tester.pumpAndSettle();
    expect(h.openedUrls.map((u) => u.toString()), contains(privacyPolicyUrl));
  });

  testWidgets('I already have a key opens the paste field in the card; Devices and keys opens its screen', (tester) async {
    final h = await open(tester);
    await showSetting(tester, 'key-have');
    await tester.tap(find.byKey(const Key('key-have')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key-paste')), findsOneWidget);
    expect(find.byKey(const Key('key-use')), findsOneWidget);
    expect(find.byKey(const Key('key-create')), findsOneWidget, reason: 'creating one is still offered');
    h.client.statusResult = (status: DriverKeyStatus.approved, display: 'KE4BFI');
    await tester.enterText(find.byKey(const Key('key-paste')), 'ms_websiteKey0123456789abcdefghijklmnopqrstuv9876');
    await showSetting(tester, 'key-use');
    await tester.tap(find.byKey(const Key('key-use')));
    await tester.pumpAndSettle();
    expect(h.state.hasKey, isTrue);
    await showSetting(tester, 'forget-key');
    await tester.tap(find.byKey(const Key('forget-key')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('forget-key-confirm')));
    await tester.pumpAndSettle();
    expect(h.state.hasKey, isFalse);
    await showSetting(tester, 'key-website');
    await tester.tap(find.byKey(const Key('key-website')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-screen')), findsOneWidget);
  });

  testWidgets('search still finds the driver key card and the privacy policy row', (tester) async {
    await open(tester);
    for (final q in ['driver key', 'create', 'paste', 'callsign']) {
      await search(tester, q);
      expect(find.byKey(const Key('search-result-driver-key')), findsOneWidget, reason: q);
    }
    await tester.tap(find.byKey(const Key('search-result-driver-key')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('key-create')).hitTestable(), findsOneWidget);
    expect(tester.widget<SettingsAnchors>(find.byType(SettingsAnchors)).highlighted, 'driver-key');
    await search(tester, 'privacy policy');
    expect(find.byKey(const Key('search-result-privacy-policy')), findsOneWidget);
    expect(find.byKey(const Key('search-result-key-privacy-policy')), findsNothing, reason: 'one privacy policy row, one result');
  });
}
