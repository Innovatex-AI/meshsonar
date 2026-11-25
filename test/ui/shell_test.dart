// The app shell: five tabs, rail on wide screens, tab memory, the mini drive bar and its states, text scale,
// semantics, the Chat seam and the Plan links.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/ui/map/legend_sheet.dart' show MapLegendSheet;
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/platform/accessibility_channel.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/design/app_symbols.dart';
import 'package:meshsonar/ui/drive_screen.dart';
import 'package:meshsonar/ui/onboarding/ui_prefs.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/shell/mini_drive_bar.dart';
import 'package:meshsonar/ui/shell/shell_controller.dart';

import 'fakes.dart';
import 'toast_test_kit.dart';

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
  while ((find.byType(BottomSheet).evaluate().isNotEmpty || find.byKey(const Key('app-sheet')).evaluate().isNotEmpty)) {
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
      for (final t in ['Chat', 'Drive', 'Network', 'Plan', 'More']) {
        expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(t)), findsOneWidget, reason: t);
      }
      // Build 71 order: Network | Drive | Chat | Plan | More, left to right.
      final xs = [
        for (final t in ['Network', 'Drive', 'Chat', 'Plan', 'More'])
          tester.getCenter(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(t))).dx
      ];
      expect(xs, [...xs]..sort(), reason: 'tab order');
      expect(AppTab.values.map((t) => t.name).toList(), ['network', 'drive', 'chat', 'plan', 'more']);
      // The harness restores a saved 'drive' tab (what every build before 71 opened on).
      expect(find.byType(DriveScreen), findsOneWidget);
      await tapShellTab(tester, 'Chat');
      expect(find.byKey(const Key('chat-empty')), findsOneWidget);
      await tapShellTab(tester, 'Network');
      expect(find.byKey(const Key('network-tab')), findsOneWidget);
      await tapShellTab(tester, 'Plan');
      expect(find.byKey(const Key('planner')), findsOneWidget);
      await tapShellTab(tester, 'More');
      expect(find.byKey(const Key('more-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('the tab bar is 72 pt plus the bottom safe area: the status-bar inset never adds a blank band above the icons', (tester) async {
      phone(tester);
      tester.view.padding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
      tester.view.viewPadding = const FakeViewPadding(top: 62 * 3, bottom: 34 * 3);
      addTearDown(tester.view.reset);
      final dpr = tester.view.devicePixelRatio;
      final h = Harness();
      await h.pumpApp(tester);
      final bar = tester.getRect(find.byKey(const Key('shell-tabs')));
      final bottomInset = 34 * 3 / dpr;
      expect(bar.height, closeTo(72 + bottomInset, 0.5), reason: 'no top inset inside the bar');
      final first = tester.getRect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.byType(NavigationDestination)).first);
      expect(first.top, closeTo(bar.top, 0.5), reason: 'the destinations start at the top of the bar');
      await drain(tester);
    });

    testWidgets('iPad: a navigation rail instead of the bottom bar, same five tabs', (tester) async {
      phone(tester, w: 834, h: 1194);
      final h = Harness();
      await h.pumpApp(tester);
      expect(find.byKey(const Key('shell-rail')), findsOneWidget);
      expect(find.byKey(const Key('shell-tabs')), findsNothing);
      for (final t in ['Chat', 'Drive', 'Network', 'Plan', 'More']) {
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
      expect(find.byKey(const Key('planner')), findsOneWidget);
      expect(prefs.toJson()['last_tab'], 'plan');
      await drain(tester);
    });

    test('old tab indexes land on the screen that now holds them', () {
      expect(LegacyTab.fromIndex(0).tab, AppTab.drive);
      expect(LegacyTab.fromIndex(1).tab, AppTab.network);
      expect(LegacyTab.fromIndex(1).network, NetworkSection.live);
      expect(LegacyTab.fromIndex(2).tab, AppTab.more);
      expect(LegacyTab.fromIndex(2).more, MoreItem.drives);
      expect(LegacyTab.fromIndex(3).more, MoreItem.radio);
      expect(LegacyTab.fromIndex(4).more, MoreItem.settings);
      expect(LegacyTab.fromIndex(99).tab, AppTab.drive);
      expect(AppTab.byName('analyze'), AppTab.network, reason: 'a last tab saved before build 71 still restores');
      expect(AppTab.byName('network'), AppTab.network);
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

    testWidgets('build 71: a fresh install opens Network; a tab saved by build 70 restores to the same tab by name', (tester) async {
      expect(ShellController().tab, AppTab.network);
      phone(tester);
      final fresh = Harness();
      await fresh.pumpApp(tester, lastTab: null);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('network-tab')), findsOneWidget, reason: 'fresh install: Network');
      expect(find.byType(DriveScreen), findsNothing, reason: 'Drive is built but not shown');
      await drain(tester);
      // Build 70 saved the tab by name; its order was Chat, Drive, Network, Plan, More (indexes 0..4).
      const build70 = ['chat', 'drive', 'network', 'plan', 'more'];
      for (final name in build70) {
        expect(AppTab.byName(name)!.name, name, reason: 'restores by identity, not by index');
      }
      expect(AppTab.byName('analyze'), AppTab.network, reason: 'the pre-rename name');
      expect(AppTab.byName('map'), AppTab.drive);
      await tester.pumpWidget(const SizedBox());
      final saved = Harness();
      await saved.pumpApp(tester, lastTab: 'chat');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('chat-empty')), findsOneWidget, reason: "build 70's saved Chat tab opens Chat, though Chat moved from first to third");
      expect(find.byKey(const Key('network-tab')), findsNothing);
      await drain(tester);
    });

    test('ShellController.immersive: Drive only, cleared when the tab changes', () {
      final c = ShellController(initial: AppTab.drive);
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
      expect(tester.getRect(find.byKey(const Key('planner'))).bottom, lessThanOrEqualTo(bar.top + 0.5));
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
      // Every tab draws an AppSymbol (Cupertino on Apple platforms, release 0.38); the Drive one is the car.
      expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.byType(AppSymbolIcon)), findsNWidgets(AppTab.values.length));
      final car = find.descendant(
          of: find.byKey(const Key('shell-tabs')),
          matching: find.byWidgetPredicate((w) => w is AppSymbolIcon && (w.symbol == AppSymbols.car || w.symbol == AppSymbols.carFill)));
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

    testWidgets('HomeShell(legacyTab: 2) opens More > Drives, (legacyTab: 4) opens Settings', (tester) async {
      phone(tester);
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(AppScope(state: h.state, child: const MaterialApp(home: HomeShell(legacyTab: 2))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('refresh-drives')), findsOneWidget);
      await tester.pumpWidget(AppScope(state: h.state, child: MaterialApp(home: HomeShell(key: UniqueKey(), legacyTab: 4))));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('settings-list')), findsOneWidget);
      await drain(tester);
    });

    testWidgets('Drives moved from Analyze to More; the Network tab shows the region', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await openDrivesTab(tester);
      expect(find.byKey(const Key('refresh-drives')), findsOneWidget);
      await openRegionTab(tester);
      expect(find.byKey(const Key('region-title')), findsOneWidget);
      await drain(tester);
    });

    testWidgetsT('More: every row opens something real', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      Future<void> row(String key) async {
        await tapShellTab(tester, 'More');
        final r = find.byKey(Key(key));
        await tester.scrollUntilVisible(r, 120,
            scrollable: find.descendant(of: find.byKey(const Key('more-list')), matching: find.byType(Scrollable)).first);
        Scrollable.ensureVisible(tester.element(r), alignment: 0.4); // clear of the tab bar
        await tester.pumpAndSettle();
        await tester.tap(r);
        await tester.pumpAndSettle();
      }

      await row('more-radio');
      expect(find.byKey(const Key('more-radio-screen')), findsOneWidget);
      await tester.tap(find.byKey(const Key('more-radioSettings')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('radio-list')), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('more-radio-screen')), findsOneWidget, reason: 'Back returns to More > Radio');
      await row('more-settings'); // More again: back to the list first
      await tapShellTab(tester, 'More');
      expect(find.byKey(const Key('more-list')), findsOneWidget);
      await row('more-about');
      expect(find.text('About MeshSonar'), findsWidgets);
      await tapShellTab(tester, 'More'); // re-tap pops to the list
      await row('more-help');
      await tester.tap(find.byKey(const Key('more-legend')));
      await tester.pumpAndSettle();
      expect(find.byType(MapLegendSheet), findsOneWidget);
      await tester.tapAt(const Offset(2, 2));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('more-howItWorks')));
      await tester.pumpAndSettle();
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
      expect(find.byKey(const Key('more-privacy')), findsNothing, reason: 'build 71: rows that only jump into Settings are gone');
      ShellController.active!.openMore(MoreItem.privacy);
      await tester.pumpAndSettle();
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
      expect(find.text('Connect a radio to start chatting'), findsOneWidget);
      expect(find.text('Messages go out over your MeshCore radio.'), findsOneWidget);
      await tester.tap(find.text('Connect radio'));
      await tester.pumpAndSettle();
      expect(find.text('MeshCore-Truck'), findsOneWidget); // the connect screen
      await drain(tester);
    });

    testWidgets('connected, no chat services yet: says so and points to Drive', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await h.state.connectSimulator();
      await tester.pumpAndSettle();
      await tapShellTab(tester, 'Chat');
      expect(find.text('Chat is getting ready'), findsOneWidget);
      expect(find.text('Connect radio'), findsNothing);
      await tester.tap(find.text('Open Drive'));
      await tester.pumpAndSettle();
      expect(find.byType(DriveScreen), findsOneWidget);
      await drain(tester);
    });

    testWidgets('a provider plugged into ChatTabHost shows Chats | Contacts | Channels and the unread badge; its radio lists are at More > Radio', (tester) async {
      phone(tester);
      final h = Harness();
      ChatTabHost.provider.value = DebugFixtureChat();
      addTearDown(() => ChatTabHost.provider.value = null);
      await h.pumpApp(tester);
      expect(find.byKey(const Key('chat-badge')), findsOneWidget);
      await tapShellTab(tester, 'Chat');
      expect(find.byKey(const Key('chat-segments')), findsOneWidget);
      expect(find.text('Fixture: Alex'), findsOneWidget);
      expect(find.text('Fixture: Public'), findsOneWidget);
      expect(find.byKey(const Key('segment-radio')), findsNothing, reason: 'build 71: the Radio segment moved to More > Radio');
      await tapShellTab(tester, 'More');
      await tester.tap(find.byKey(const Key('more-radio')));
      await tester.pumpAndSettle();
      expect(find.text('Fixture: North Ridge repeater'), findsOneWidget);
      await drain(tester);
    });
  });

  group('Plan tab', () {
    testWidgets('the Plan tab opens on the Planner: one map, the sheet and the four mode chips; no tool list, no browser', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Plan');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('planner')), findsOneWidget);
      expect(find.byKey(const Key('planner-map')), findsOneWidget);
      expect(find.byKey(const Key('planner-sheet')), findsOneWidget);
      for (final id in const ['link', 'coverage', 'findSites', 'whereToDrive']) {
        expect(find.byKey(Key('planner-mode-$id')), findsOneWidget, reason: id);
      }
      for (final gone in const ['link', 'painter', 'planner', 'recommended', 'sites', 'scenarios', 'tracker', 'field']) {
        expect(find.byKey(Key('plan-$gone')), findsNothing, reason: '$gone: the old tool rows are gone');
      }
      expect(h.openedUrls, isEmpty, reason: 'the planner never opens the browser');
      expect(find.text('Plan on the website'), findsNothing);
      await drain(tester);
    });

    testWidgets('build 76: each mode says what it is for in one line; tapping the Plan tab again puts the sheet down and back', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Plan');
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byKey(const Key('drive-badge')), findsNothing, reason: 'no drive is recording');
      String what() => tester.widget<Text>(find.byKey(const Key('planner-mode-what'))).data!;
      expect(what(), 'Will these two radios hear each other?');
      for (final (id, line) in const [
        ('coverage', 'How far would a radio here reach?'),
        ('findSites', 'Where would a new repeater help most?'),
        ('whereToDrive', 'Where should I drive next?'),
      ]) {
        await tester.tap(find.byKey(Key('planner-mode-$id')));
        await tester.pump(const Duration(milliseconds: 400));
        expect(what(), line, reason: id);
      }
      double h0() => tester.getSize(find.byKey(const Key('planner-sheet'))).height;
      final open = h0();
      await tapShellTab(tester, 'Plan');
      await tester.pump(const Duration(milliseconds: 600));
      expect(h0(), lessThan(open - 40), reason: 'the sheet went down: the whole map shows');
      await tapShellTab(tester, 'Plan');
      await tester.pump(const Duration(milliseconds: 600));
      expect(h0(), closeTo(open, 1), reason: 'and comes back');
      await drain(tester);
    });
  });

  group('mini drive bar', () {
    testWidgets('no bar without a drive; with one it shows on every tab except Drive', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing, reason: 'Drive tab is the drive screen');
      for (final t in ['Chat', 'Network', 'Plan', 'More']) {
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
      // Build 76: a second line says what the drive is doing, and a red dot on the Drive tab says it is recording.
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-next'))).data, contains('1 heard · '));
      expect(find.byKey(const Key('drive-badge')), findsOneWidget);
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
      expect(waiting(), anyOf('Radio problem', 'Reconnecting…'));
      expect(miniBarSummary(h.state).problem, isTrue);
      e.setStatus(const EngineStatus(EngineState.driving));
      await tester.pump(const Duration(milliseconds: 50));
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('Stop asks first; Keep driving leaves the drive running; Stop drive ends it', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      await tapShellTab(tester, 'Network');
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
      expect(find.descendant(of: find.byKey(const Key('mini-bar-stop')), matching: find.text('Stop')), findsOneWidget, reason: 'build 76: Stop is a labelled button');
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
