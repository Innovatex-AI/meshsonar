import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';

import 'fakes.dart';

void main() {
  testWidgets('first run shows the intro; Next through all pages; not shown again', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    final prefs = UiPrefs();
    attachUiPrefs(h.state, prefs);
    await h.pumpApp(tester);
    expect(find.byKey(const Key('onboarding')), findsOneWidget);
    expect(find.text('Map where your mesh reaches'), findsOneWidget);

    // Build 76: the radio page is second, so Connect is one tap from the first page.
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Connect your radio'), findsOneWidget);
    expect(find.byKey(const Key('onboarding-connect')), findsOneWidget);
    expect(find.text('Later'), findsOneWidget, reason: 'the radio can wait: the button says so');
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Find your way around'), findsOneWidget);
    for (final tab in ['Chat', 'Drive', 'Network', 'Plan', 'More']) {
      expect(find.text(tab), findsWidgets);
    }
    expect(find.text('Record a drive and see coverage'), findsOneWidget, reason: 'one line per tab');
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.text('Nothing to sign up for'), findsOneWidget);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsNothing);
    expect(prefs.onboardingSeen, isTrue);
    expect(find.text('Drive'), findsWidgets);

    // A fresh app with the same prefs goes straight in.
    final h2 = Harness();
    attachUiPrefs(h2.state, prefs);
    await h2.pumpApp(tester);
    expect(find.byKey(const Key('onboarding')), findsNothing);
  });

  testWidgets('every page fits an iPhone SE (375x667) without overflow', (tester) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = Harness();
    attachUiPrefs(h.state, UiPrefs());
    await h.pumpApp(tester);
    for (var i = 0; i < 3; i++) {
      expect(tester.takeException(), isNull, reason: 'page ${i + 1}');
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    expect(find.text('Get started'), findsOneWidget);
  });

  testWidgets('intro is skippable', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    final prefs = UiPrefs();
    attachUiPrefs(h.state, prefs);
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('onboarding-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('onboarding')), findsNothing);
    expect(prefs.onboardingSeen, isTrue);
  });

  testWidgets('"Try the Simulator" connects the simulator', (tester) async {
    useTallScreen(tester);
    final h = Harness();
    attachUiPrefs(h.state, UiPrefs());
    await h.pumpApp(tester);
    await tester.tap(find.byKey(const Key('onboarding-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('onboarding-simulator')));
    await tester.pumpAndSettle();
    expect(h.state.radioKind, RadioKind.simulator);
    expect(h.state.connected, isTrue);
  });

  test('file prefs persist the seen flag and drive names; damaged file = first run', () async {
    final dir = await Directory.systemTemp.createTemp('uiprefs');
    addTearDown(() => dir.delete(recursive: true));
    final f = File('${dir.path}/ui_prefs.json');
    final a = FileUiPrefs(f);
    await a.load();
    expect(a.onboardingSeen, isFalse);
    await a.markOnboardingSeen();
    await a.setLabel('s1', 'Morning run');
    final b = FileUiPrefs(f);
    await b.load();
    expect(b.onboardingSeen, isTrue);
    expect(b.labelFor('s1'), 'Morning run');
    await f.writeAsString('{not json');
    final c = FileUiPrefs(f);
    await c.load();
    expect(c.onboardingSeen, isFalse);
  });
}
