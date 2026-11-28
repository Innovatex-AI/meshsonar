import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/app_state.dart';
import 'package:meshsonar/ui/app.dart' show AppTab, ShellController;
import 'package:meshsonar/ui/connect_screen.dart';
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
    // Build 77 (round 5 O4): "Next", not "Later" (it means the next page; Skip is there to leave).
    expect(find.text('Later'), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('onboarding-next')), matching: find.text('Next')), findsOneWidget);
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

  group('build 77 (round 5 O1 to O3)', () {
    Future<(Harness, UiPrefs)> firstRun(WidgetTester tester) async {
      useTallScreen(tester);
      final h = Harness();
      final prefs = UiPrefs(telemetryDisclosed: false);
      attachUiPrefs(h.state, prefs);
      await h.pumpApp(tester);
      return (h, prefs);
    }

    testWidgets('"What MeshSonar collects" is the last intro page, answered before the intro closes; no sheet after', (tester) async {
      final (_, prefs) = await firstRun(tester);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('onboarding-next')));
        await tester.pumpAndSettle();
      }
      expect(find.text('Nothing to sign up for'), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('onboarding-next')), matching: find.text('Next')), findsOneWidget,
          reason: 'one more page follows');
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding-page-collects')), findsOneWidget);
      expect(find.text('What MeshSonar collects'), findsOneWidget);
      expect(find.byKey(const Key('onboarding-skip')), findsNothing, reason: 'it is answered, not skipped');
      expect(find.byKey(const Key('onboarding-next')), findsNothing, reason: 'its own two buttons answer it');
      await tester.tap(find.byKey(const Key('telemetry-keep')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding')), findsNothing);
      expect(prefs.onboardingSeen && prefs.telemetryDisclosed, isTrue);
      expect(find.byKey(const Key('telemetry-sheet')), findsNothing, reason: 'the shell does not raise it again');
    });

    testWidgets('Skip goes to the collects page first, then leaves', (tester) async {
      final (_, prefs) = await firstRun(tester);
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding-page-collects')), findsOneWidget);
      expect(prefs.onboardingSeen, isFalse);
      await tester.tap(find.byKey(const Key('telemetry-off')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding')), findsNothing);
      expect(prefs.telemetryDisclosed, isTrue);
    });

    testWidgets('Connect radio: the collects page, then the Connect screen alone; a connect lands on Drive', (tester) async {
      final (h, _) = await firstRun(tester);
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding-connect')));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectScreen), findsNothing, reason: 'not three things at once');
      expect(find.byKey(const Key('onboarding-page-collects')), findsOneWidget);
      await tester.tap(find.byKey(const Key('telemetry-keep')));
      await tester.pumpAndSettle();
      expect(find.byType(ConnectScreen), findsOneWidget);
      expect(find.byKey(const Key('telemetry-sheet')), findsNothing);
      await tester.tap(find.byKey(ValueKey('device-${h.bt.devices.first.id}')));
      await tester.pumpAndSettle();
      expect(h.state.connected, isTrue);
      expect(find.byType(ConnectScreen), findsNothing);
      expect(ShellController.active?.tab, AppTab.drive, reason: 'O2: a radio connected from the intro lands on Drive');
    });

    testWidgets('Try a demo connects the simulator and lands on Drive', (tester) async {
      final (h, _) = await firstRun(tester);
      await tester.tap(find.byKey(const Key('onboarding-next')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('onboarding-simulator')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('telemetry-keep')));
      await tester.pumpAndSettle();
      expect(h.state.radioKind, RadioKind.simulator);
      expect(ShellController.active?.tab, AppTab.drive);
    });

    testWidgets('the status bar is light on the dark intro, in the light theme too', (tester) async {
      await firstRun(tester);
      final region = tester.widget<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.ancestor(of: find.byKey(const Key('onboarding')), matching: find.byType(AnnotatedRegion<SystemUiOverlayStyle>)).first);
      expect(region.value.statusBarBrightness, Brightness.dark, reason: 'iOS: dark bar background = light content');
      expect(region.value.statusBarIconBrightness, Brightness.light);
    });

    testWidgets('the collects page fits an iPhone SE (375x667) without overflow', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final h = Harness();
      attachUiPrefs(h.state, UiPrefs(telemetryDisclosed: false));
      await h.pumpApp(tester);
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('telemetry-keep')).hitTestable(), findsOneWidget);
    });
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
