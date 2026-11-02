// The app shell: five tabs, rail on wide screens, tab memory, the mini drive bar and its states, text scale,
// semantics, the Chat seam and the Plan links.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/platform/accessibility_channel.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/app_symbols.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';
import 'package:meshsonar/ui/shell/plan_tab.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'fakes.dart';

/// Lets snackbars time out so no timers are left pending.
Future<void> drain(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 10));
  await tester.pump(const Duration(seconds: 1));
}

void phone(WidgetTester tester, {double scale = 1.0, double w = 390, double h = 844}) {
  tester.view.physicalSize = Size(w * 3, h * 3);
  tester.view.devicePixelRatio = 3.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<Harness> startDriving(WidgetTester tester, {Harness? harness}) async {
  final h = harness ?? (Harness()..approveKey());
  await h.pumpApp(tester);
  await h.state.connectSimulator();
  await tester.pumpAndSettle();
  // The first connect opens the antenna sheet; the tests are about the shell, so close it.
  while (find.byType(BottomSheet).evaluate().isNotEmpty) {
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
  }
  await h.state.startDrive();
  await tester.pump(const Duration(milliseconds: 100));
  return h;
}

void main() {
  group('tabs', () {
    testWidgets('phone: five tabs in a bottom bar, each opens its screen', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      expect(find.byKey(const Key('shell-tabs')), findsOneWidget);
      expect(find.byKey(const Key('shell-rail')), findsNothing);
      for (final t in ['Chat', 'Drive', 'Analyze', 'Plan', 'More']) {
        expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(t)), findsOneWidget, reason: t);
      }
      // Fresh install opens on the Drive tab.
      expect(find.byType(DriveScreen), findsOneWidget);
      await tapShellTab(tester, 'Chat');
      expect(find.byKey(const Key('chat-empty')), findsOneWidget);
      await tapShellTab(tester, 'Analyze');
      expect(find.byKey(const Key('analyze-segments')), findsOneWidget);
      await tapShellTab(tester, 'Plan');
      expect(find.byKey(const Key('plan-list')), findsOneWidget);
      await tapShellTab(tester, 'More');
      expect(find.byKey(const Key('more-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('iPad: a navigation rail instead of the bottom bar, same five tabs', (tester) async {
      phone(tester, w: 834, h: 1194);
      final h = Harness();
      await h.pumpApp(tester);
      expect(find.byKey(const Key('shell-rail')), findsOneWidget);
      expect(find.byKey(const Key('shell-tabs')), findsNothing);
      for (final t in ['Chat', 'Drive', 'Analyze', 'Plan', 'More']) {
        expect(find.descendant(of: find.byKey(const Key('shell-rail')), matching: find.text(t)), findsOneWidget, reason: t);
      }
      await openSettingsTab(tester);
      expect(find.byKey(const Key('settings-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('rotating between rail and bar keeps the screen you were on', (tester) async {
      phone(tester, w: 390, h: 844);
      final h = Harness();
      await h.pumpApp(tester);
      await openRadioTab(tester);
      expect(find.byKey(const Key('radio-list')), findsOneWidget);
      tester.view.physicalSize = const Size(844 * 3, 390 * 3); // landscape: rail
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('shell-rail')), findsOneWidget);
      expect(find.byKey(const Key('radio-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the last tab is remembered, by name', (tester) async {
      phone(tester);
      final h = Harness();
      final prefs = UiPrefs(seen: true);
      attachUiPrefs(h.state, prefs);
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Plan');
      expect(prefs.lastTab, 'plan');
      // A new shell with the same prefs opens on Plan.
      final h2 = Harness();
      attachUiPrefs(h2.state, prefs);
      await h2.pumpApp(tester);
      expect(find.byKey(const Key('plan-list')), findsOneWidget);
      expect(prefs.toJson()['last_tab'], 'plan');
      await drain(tester);
    });

    test('old tab indexes land on the screen that now holds them', () {
      expect(LegacyTab.fromIndex(0).tab, AppTab.drive);
      expect(LegacyTab.fromIndex(1).tab, AppTab.analyze);
      expect(LegacyTab.fromIndex(1).analyze, AnalyzeView.region);
      expect(LegacyTab.fromIndex(2).analyze, AnalyzeView.drives);
      expect(LegacyTab.fromIndex(3).more, MoreItem.radio);
      expect(LegacyTab.fromIndex(4).more, MoreItem.settings);
      expect(LegacyTab.fromIndex(99).tab, AppTab.drive);
      expect(AppTab.byName('analyze'), AppTab.analyze);
      expect(AppTab.byName('nope'), isNull);
    });

    test('a saved "map" (pre-rename) restores the Drive tab; new writes use "drive"', () async {
      expect(AppTab.byName('map'), AppTab.drive);
      expect(AppTab.byName('drive'), AppTab.drive);
      expect(AppTab.drive.name, 'drive');
      expect(AppTab.drive.label, 'Drive');
      final prefs = UiPrefs(seen: true);
      await prefs.setLastTab('map');
      expect(AppTab.byName(prefs.lastTab), AppTab.drive);
    });

    testWidgets('a stored lastTab "map" opens Drive, and the next tab change stores "drive"', (tester) async {
      phone(tester);
      final h = Harness();
      final prefs = UiPrefs(seen: true);
      await prefs.setLastTab('map');
      attachUiPrefs(h.state, prefs);
      await h.pumpApp(tester);
      expect(find.byType(DriveScreen), findsOneWidget);
      await tapShellTab(tester, 'Plan');
      await tapShellTab(tester, 'Drive');
      expect(prefs.lastTab, 'drive');
      await drain(tester);
    });

    test('ShellController.immersive: Drive only, cleared when the tab changes', () {
      final c = ShellController();
      expect(c.tab, AppTab.drive);
      expect(c.immersive, isFalse);
      c.setImmersive(true);
      expect(c.immersive, isTrue);
      c.select(AppTab.plan);
      expect(c.immersive, isFalse);
      c.setImmersive(true); // not on Drive: ignored
      expect(c.immersive, isFalse);
      c.select(AppTab.drive);
      expect(c.immersive, isFalse, reason: 'leaving Drive cleared it');
      var n = 0;
      c.addListener(() => n++);
      c.setImmersive(true);
      c.setImmersive(true);
      expect(n, 1);
    });

    testWidgets('phone: immersive hides the tab bar and the mini bar; the Drive page runs behind a translucent bar', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      final shell = ShellScope.maybeOf(tester.element(find.byType(DriveScreen)))!;
      expect(find.byKey(const Key('shell-tabs')), findsOneWidget);
      // Drive extends behind the bar: it spans the whole screen height (the bar overlays its bottom).
      expect(tester.getSize(find.byType(DriveScreen)).height, 844);
      shell.setImmersive(true);
      await tester.pump();
      expect(find.byKey(const Key('shell-tabs')), findsNothing);
      shell.setImmersive(false);
      await tester.pump();
      expect(find.byKey(const Key('shell-tabs')), findsOneWidget);
      // Other tabs stay above the bar, never under it.
      await tapShellTab(tester, 'Plan');
      final bar = tester.getRect(find.byKey(const Key('shell-tabs')));
      expect(tester.getRect(find.byKey(const Key('plan-list'))).bottom, lessThanOrEqualTo(bar.top + 0.5));
      await drain(tester);
    });

    testWidgets('the tab bar is blurred, opaque under Reduce Transparency, and the Drive icon is the car', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      // Unknown platform answer (tests) = opaque.
      AccessibilitySignals.reduceTransparency = null;
      await tester.pump();
      expect(find.byKey(const Key('blur-bar-opaque')), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      AccessibilitySignals.reduceTransparency = false;
      addTearDown(() => AccessibilitySignals.reduceTransparency = null);
      await tapShellTab(tester, 'Plan');
      expect(find.byKey(const Key('blur-bar-blurred')), findsOneWidget);
      expect(find.ancestor(of: find.byKey(const Key('shell-tabs')), matching: find.byType(BackdropFilter)), findsOneWidget);
      AccessibilitySignals.reduceTransparency = true;
      await tapShellTab(tester, 'Chat');
      expect(find.byKey(const Key('blur-bar-opaque')), findsOneWidget);
      // Drive is unselected here (Chat is open): the outline car; selected it is car.fill.
      final car = find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.byType(AppSymbolIcon));
      expect(tester.widget<AppSymbolIcon>(car).symbol, AppSymbols.car);
      await tapShellTab(tester, 'Drive');
      expect(tester.widget<AppSymbolIcon>(car).symbol, AppSymbols.carFill);
      await drain(tester);
    });

    testWidgets('iPad: immersive hides the rail', (tester) async {
      phone(tester, w: 834, h: 1194);
      final h = Harness();
      await h.pumpApp(tester);
      final shell = ShellScope.maybeOf(tester.element(find.byType(DriveScreen)))!;
      expect(find.byKey(const Key('shell-rail')), findsOneWidget);
      shell.setImmersive(true);
      await tester.pump();
      expect(find.byKey(const Key('shell-rail')), findsNothing);
      shell.setImmersive(false);
      await tester.pump();
      expect(find.byKey(const Key('shell-rail')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('HomeShell(legacyTab: 2) opens Analyze > Drives, (legacyTab: 4) opens Settings', (tester) async {
      phone(tester);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(AppScope(state: h.state, child: const MaterialApp(home: HomeShell(legacyTab: 2))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('analyze-segments')), findsOneWidget);
      expect(tester.widget<SegmentedButton<AnalyzeView>>(find.byKey(const Key('analyze-segments'))).selected, {AnalyzeView.drives});
      await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(home: HomeShell(key: UniqueKey(), legacyTab: 4))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('tapping the Analyze segments switches between Region and Drives', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await openDrivesTab(tester);
      expect(tester.widget<SegmentedButton<AnalyzeView>>(find.byKey(const Key('analyze-segments'))).selected, {AnalyzeView.drives});
      await openRegionTab(tester);
      expect(find.byKey(const Key('region-title')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('More: every row opens something real', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      Future<void> row(String key) async {
        await tapShellTab(tester, 'More');
        final r = find.byKey(Key(key));
        await tester.scrollUntilVisible(r, 120,
            scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
        await tester.tap(r);
        await tester.pumpAndSettle();
      }

      await row('more-radio');
      expect(find.byKey(const Key('radio-list')), findsOneWidget);
      await row('more-settings'); // More again: back to the list first
      await tapShellTab(tester, 'More');
      expect(find.byKey(const Key('more-list')), findsOneWidget);
      await row('more-about');
      expect(find.text('About MeshSonar'), findsWidgets);
      await tapShellTab(tester, 'More'); // re-tap pops to the list
      await row('more-legend');
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await row('more-howItWorks');
      expect(find.byKey(const Key('howitworks-list')), findsOneWidget);
      await tester.scrollUntilVisible(find.byKey(const Key('howitworks-tour')), 200);
      await tester.tap(find.byKey(const Key('howitworks-tour')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('onboarding')), findsOneWidget);
      expect(find.byKey(const Key('onboarding-connect')), findsNothing, reason: 'replay has no connect button');
      await tester.tap(find.byKey(const Key('onboarding-skip')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('howitworks-list')), findsOneWidget);
      await tapShellTab(tester, 'More'); // re-tap pops to the list
      expect(find.byKey(const Key('more-list')), findsOneWidget);
      await row('more-privacy');
      expect(find.byKey(const Key('settings-list')), findsOneWidget);
      await drain(tester);
    });
  });

  group('Chat tab', () {
    testWidgets('not connected: honest first-run state with a connect button', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Chat');
      expect(find.text('Messages arrive here once you connect a radio'), findsOneWidget);
      await tester.tap(find.byKey(const Key('chat-connect')));
      await tester.pumpAndSettle();
      expect(find.text('MeshCore-Truck'), findsOneWidget); // the connect screen
      await drain(tester);
    });

    testWidgets('connected, no chat services yet: says so and points to the map', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connectSimulator();
      await tester.pumpAndSettle();
      await tapShellTab(tester, 'Chat');
      expect(find.text('Chat is coming to this tab'), findsOneWidget);
      expect(find.byKey(const Key('chat-connect')), findsNothing);
      await tester.tap(find.byKey(const Key('chat-open-map')));
      await tester.pumpAndSettle();
      expect(find.byType(DriveScreen), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a provider plugged into ChatTabHost shows Contacts | Channels and the unread badge', (tester) async {
      phone(tester);
      final h = Harness();
      ChatTabHost.provider.value = DebugFixtureChat();
      addTearDown(() => ChatTabHost.provider.value = null);
      await h.pumpApp(tester);
      expect(find.byKey(const Key('chat-badge')), findsOneWidget);
      await tapShellTab(tester, 'Chat');
      expect(find.byKey(const Key('chat-segments')), findsOneWidget);
      expect(find.text('Fixture: Alex'), findsOneWidget);
      await tester.tap(find.text('Channels'));
      await tester.pumpAndSettle();
      expect(find.text('Fixture: Public'), findsOneWidget);
      await drain(tester);
    });
  });

  group('Plan tab', () {
    testWidgets('native tools open a screen (no browser, no external-link icon); the rest open the website page for the region', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Plan');
      final list = find.descendant(of: find.byKey(const Key('plan-list')), matching: find.byType(Scrollable)).first;
      Future<void> clearBar(Finder f) async {
        while (tester.getCenter(f).dy > 640) {
          await tester.drag(list, const Offset(0, -100));
          await tester.pump();
        }
      }

      final web = planTools.where((t) => t.native == null).toList();
      final native = planTools.where((t) => t.native != null).toList();
      expect(native.map((t) => t.id), containsAll(['planner', 'recommended', 'sites', 'scenarios', 'tracker', 'link', 'painter', 'airtime', 'presets', 'check', 'field']));
      expect(plannedInApp, isEmpty, reason: 'every planned in-app tool is now native');
      for (final t in native) {
        await tester.scrollUntilVisible(find.byKey(Key('plan-${t.id}')), 120, scrollable: list);
        await clearBar(find.byKey(Key('plan-${t.id}')));
        final tile = find.byKey(Key('plan-${t.id}'));
        expect(find.descendant(of: tile, matching: find.byIcon(Icons.open_in_new)), findsNothing, reason: t.id);
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('plan-list')), findsNothing, reason: '${t.id} opened a screen over the Plan tab');
        if (const ['link', 'painter', 'airtime', 'presets', 'check', 'field'].contains(t.id)) {
          expect(find.byKey(Key('plan-page-${t.id}')), findsOneWidget, reason: t.id);
        }
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      for (final t in web) {
        await tester.scrollUntilVisible(find.byKey(Key('plan-${t.id}')), 120, scrollable: list);
        await clearBar(find.byKey(Key('plan-${t.id}'))); // clear the bottom bar
        await tester.tap(find.byKey(Key('plan-${t.id}')));
        await tester.pump();
        expect(h.openedUrls.last.path, t.path, reason: t.id);
      }
      expect(h.openedUrls.length, web.length, reason: 'a native tool never opens the browser');
      expect(find.text('Coming next, inside the app'), findsNothing);
      await drain(tester);
    });
  });

  group('mini drive bar', () {
    testWidgets('no bar without a drive; with one it shows on every tab except Drive', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing, reason: 'Drive tab is the drive screen');
      for (final t in ['Chat', 'Analyze', 'Plan', 'More']) {
        await tapShellTab(tester, t);
        expect(find.byKey(const Key('mini-drive-bar')), findsOneWidget, reason: t);
      }
      await tapShellTab(tester, 'Drive');
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing);
      await h.state.stopDrive();
      await tapShellTab(tester, 'Plan');
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing, reason: 'drive over');
      await drain(tester);
    });

    testWidgets('shows the last ping result and elapsed time; tapping it opens the Drive tab', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
      await tester.pump(const Duration(milliseconds: 100));
      await tapShellTab(tester, 'Plan');
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-hero'))).data, '1 heard');
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-elapsed'))).data, matches(RegExp(r'^\d+:\d\d$')));
      await tester.tap(find.byKey(const Key('mini-bar-open')));
      await settleLive(tester);
      expect(find.byType(DriveScreen), findsOneWidget);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing);
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('a silent ping reads "No echo"', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      h.engines.single.emit(silentPing('p1'));
      await tester.pump(const Duration(milliseconds: 100));
      await tapShellTab(tester, 'Plan');
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-hero'))).data, 'No echo');
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('Pause pings (state) stops the automatic pings (interval 0) and the bar shows the paused dot', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      final e = h.engines.single;
      await tapShellTab(tester, 'Plan');
      h.state.setPingsPaused(true);
      await tester.pump(const Duration(milliseconds: 100));
      expect(e.updates.last.intervalSec, 0);
      expect(miniBarSummary(h.state).waiting, 'Pings paused');
      expect(find.byIcon(Icons.pause_circle_outline_rounded), findsOneWidget);
      h.state.setPingsPaused(false);
      await tester.pump(const Duration(milliseconds: 100));
      expect(e.updates.last.intervalSec, h.state.settings.intervalSec);
      await h.state.stopDrive();
      await drain(tester);
    });

    test('miniBarElapsed formats m:ss and h:mm:ss', () {
      expect(miniBarElapsed(const Duration(seconds: 7)), '0:07');
      expect(miniBarElapsed(const Duration(minutes: 18, seconds: 5)), '18:05');
      expect(miniBarElapsed(const Duration(hours: 1, minutes: 5, seconds: 7)), '1:05:07');
      expect(miniBarElapsed(const Duration(seconds: -3)), '0:00');
    });

    testWidgets('spoken sentence names repeaters heard on the last ping and the minutes driven', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1), Echo(repeater: 'c3d4', snrDb: 2, hops: 1)]));
      await tester.pump(const Duration(milliseconds: 100));
      expect(miniBarHero(h.state, elapsed: const Duration(minutes: 18)).spoken,
          'Drive in progress, 2 repeaters heard last ping, 18 minutes');
      expect(miniBarHero(h.state, elapsed: const Duration(seconds: 20)).spoken, endsWith('less than a minute'));
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('waiting text: next ping countdown, distance, GPS, listening, paused', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      final e = h.engines.single;
      String waiting() => miniBarSummary(h.state).waiting;
      final now = h.state.services.clock();
      e.setStatus(EngineStatus(EngineState.driving, nextPingAt: now.add(const Duration(seconds: 14)), waitingFor: PingWait.time));
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting(), 'Next ping 14 s');
      e.setStatus(const EngineStatus(EngineState.driving, waitingFor: PingWait.distance, metresToGo: 40));
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting(), startsWith('Move '));
      e.setStatus(const EngineStatus(EngineState.driving, waitingFor: PingWait.gps));
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting(), 'Waiting for GPS');
      e.setStatus(const EngineStatus(EngineState.pinging));
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting(), 'Listening for echoes');
      e.setStatus(const EngineStatus(EngineState.error, message: 'Radio disconnected'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(waiting(), anyOf('Radio problem', 'Radio reconnecting'));
      expect(miniBarSummary(h.state).problem, isTrue);
      e.setStatus(const EngineStatus(EngineState.driving));
      await tester.pump(const Duration(milliseconds: 50));
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('Stop asks first; Keep driving leaves the drive running; Stop drive ends it', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      await tapShellTab(tester, 'Analyze');
      await tester.tap(find.byKey(const Key('mini-bar-stop')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('stop-drive-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('stop-drive-keep')));
      await tester.pumpAndSettle();
      expect(h.state.driving, isTrue);
      await tester.tap(find.byKey(const Key('mini-bar-stop')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('stop-drive-confirm')));
      await tester.pumpAndSettle();
      expect(h.state.driving, isFalse);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing);
      await drain(tester);
    });

    testWidgets('bar is 56 pt, Stop is 44 pt, one spoken sentence plus a separate Stop button', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      await tapShellTab(tester, 'Plan');
      final stop = tester.getSize(find.byKey(const Key('mini-bar-stop')));
      expect(stop.width, greaterThanOrEqualTo(44));
      expect(stop.height, greaterThanOrEqualTo(44));
      expect(tester.getSize(find.byKey(const Key('mini-drive-bar'))).height, miniDriveBarHeight);
      expect(miniDriveBarHeight, 56);
      expect(find.byKey(const Key('mini-bar-pause')), findsNothing, reason: 'Pause lives in the Drive controls only');
      final handle = tester.ensureSemantics();
      final sem = tester.getSemantics(find.byKey(const Key('mini-bar-open')));
      expect(sem.label, startsWith('Drive in progress, '));
      expect(sem.label, contains('no pings yet'));
      expect(sem.hint, 'Opens the Drive tab');
      expect(tester.getSemantics(find.byKey(const Key('mini-bar-stop'))).tooltip, 'Stop drive');
      handle.dispose();
      await h.state.stopDrive();
      await drain(tester);
    });

    for (final scale in [1.0, 2.5]) {
      for (final width in [320.0, 390.0, 834.0]) {
        testWidgets('${width.toInt()} dp wide at ${scale}x text: no overflow, bar stays compact', (tester) async {
          phone(tester, scale: scale, w: width, h: width > 700 ? 1194 : 760);
          final h = await startDriving(tester);
          h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
          await tester.pump(const Duration(milliseconds: 100));
          await tapShellTab(tester, 'Plan');
          expect(tester.takeException(), isNull);
          final bar = tester.getSize(find.byKey(const Key('mini-drive-bar')));
          expect(bar.height, lessThanOrEqualTo(130), reason: 'a persistent bar must not swallow the screen');
          expect(find.byKey(const Key('mini-bar-stop')), findsOneWidget);
          await h.state.stopDrive();
          await drain(tester);
        });
      }
    }

    testWidgets('dark mode renders', (tester) async {
      phone(tester);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final h = await startDriving(tester);
      await tapShellTab(tester, 'More');
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('mini-drive-bar')), findsOneWidget);
      await h.state.stopDrive();
      await drain(tester);
    });
  });
}
