// The app shell: five tabs, rail on wide screens, tab memory, the mini drive bar and its states, text scale,
// semantics, the Chat seam and the Plan links.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/core/model.dart';
import 'package:meshsonar/radio/radio_api.dart';
import 'package:meshsonar/ui/app.dart';
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
      for (final t in ['Chat', 'Map', 'Analyze', 'Plan', 'More']) {
        expect(find.descendant(of: find.byKey(const Key('shell-tabs')), matching: find.text(t)), findsOneWidget, reason: t);
      }
      // Fresh install opens on the Map tab.
      expect(find.byKey(const Key('map-mode')), findsOneWidget);
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
      for (final t in ['Chat', 'Map', 'Analyze', 'Plan', 'More']) {
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
      expect(LegacyTab.fromIndex(0).tab, AppTab.map);
      expect(LegacyTab.fromIndex(1).tab, AppTab.analyze);
      expect(LegacyTab.fromIndex(1).analyze, AnalyzeView.region);
      expect(LegacyTab.fromIndex(2).analyze, AnalyzeView.drives);
      expect(LegacyTab.fromIndex(3).more, MoreItem.radio);
      expect(LegacyTab.fromIndex(4).more, MoreItem.settings);
      expect(LegacyTab.fromIndex(99).tab, AppTab.map);
      expect(AppTab.byName('analyze'), AppTab.analyze);
      expect(AppTab.byName('nope'), isNull);
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
      expect(find.byKey(const Key('map-mode')), findsOneWidget);
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
    testWidgets('every tool opens the website page for the region; planned in-app tools have no button', (tester) async {
      phone(tester);
      final h = Harness();
      await h.pumpApp(tester);
      await tapShellTab(tester, 'Plan');
      final list = find.descendant(of: find.byKey(const Key('plan-list')), matching: find.byType(Scrollable)).first;
      for (final t in planTools) {
        await tester.scrollUntilVisible(find.byKey(Key('plan-${t.id}')), 120, scrollable: list);
        await tester.tap(find.byKey(Key('plan-${t.id}')));
        await tester.pump();
        expect(h.openedUrls.last.path, t.path, reason: t.id);
      }
      expect(h.openedUrls.length, planTools.length);
      await tester.scrollUntilVisible(find.text('Coming next, inside the app'), 120, scrollable: list);
      for (final p in plannedInApp) {
        expect(tester.widget<ListTile>(find.widgetWithText(ListTile, p.$1)).enabled, isFalse);
      }
      await drain(tester);
    });
  });

  group('mini drive bar', () {
    testWidgets('no bar without a drive; with one it shows on every tab except Map', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing, reason: 'Map tab is the drive screen');
      for (final t in ['Chat', 'Analyze', 'Plan', 'More']) {
        await tapShellTab(tester, t);
        expect(find.byKey(const Key('mini-drive-bar')), findsOneWidget, reason: t);
      }
      await tapShellTab(tester, 'Map');
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing);
      await h.state.stopDrive();
      await tapShellTab(tester, 'Plan');
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing, reason: 'drive over');
      await drain(tester);
    });

    testWidgets('shows pings sent / heard and the last SNR; tapping it opens the Map tab', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      h.engines.single.emit(heardPing('p1', const [Echo(repeater: 'a1b2', snrDb: 6.5, hops: 1)]));
      await tester.pump(const Duration(milliseconds: 100));
      await tapShellTab(tester, 'Plan');
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-counts'))).data, '1 ping · 1 heard');
      final waiting = tester.widget<Text>(find.byKey(const Key('mini-bar-waiting'))).textSpan!.toPlainText();
      expect(waiting, contains('SNR +6.5 dB'));
      await tester.tap(find.byKey(const Key('mini-bar-open')));
      await settleLive(tester);
      expect(find.byKey(const Key('map-mode')), findsOneWidget);
      expect(find.byKey(const Key('mini-drive-bar')), findsNothing);
      await h.state.stopDrive();
      await drain(tester);
    });

    testWidgets('a silent ping reads "none", not a strength', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      h.engines.single.emit(silentPing('p1'));
      await tester.pump(const Duration(milliseconds: 100));
      await tapShellTab(tester, 'Plan');
      expect(tester.widget<Text>(find.byKey(const Key('mini-bar-waiting'))).textSpan!.toPlainText(), contains('SNR none'));
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

    testWidgets('Pause pings stops the automatic pings (interval 0) and Resume brings them back', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      final e = h.engines.single;
      await tapShellTab(tester, 'Plan');
      expect(find.byTooltip('Pause pings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mini-bar-pause')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.state.pingsPaused, isTrue);
      expect(e.updates.last.intervalSec, 0);
      expect(miniBarSummary(h.state).waiting, 'Pings paused');
      expect(h.state.statusLine, contains('paused'));
      expect(find.byTooltip('Resume pings'), findsOneWidget);
      await tester.tap(find.byKey(const Key('mini-bar-pause')));
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.state.pingsPaused, isFalse);
      expect(e.updates.last.intervalSec, h.state.settings.intervalSec);
      // A new drive starts unpaused even if the last one ended paused.
      h.state.setPingsPaused(true);
      await h.state.stopDrive();
      expect(h.state.pingsPaused, isFalse);
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

    testWidgets('controls are at least 48 square and have spoken labels', (tester) async {
      phone(tester);
      final h = await startDriving(tester);
      await tapShellTab(tester, 'Plan');
      for (final k in ['mini-bar-pause', 'mini-bar-stop']) {
        final size = tester.getSize(find.byKey(Key(k)));
        expect(size.width, greaterThanOrEqualTo(48), reason: k);
        expect(size.height, greaterThanOrEqualTo(48), reason: k);
      }
      expect(tester.getSize(find.byKey(const Key('mini-drive-bar'))).height, greaterThanOrEqualTo(miniDriveBarHeight));
      final handle = tester.ensureSemantics();
      final sem = tester.getSemantics(find.byKey(const Key('mini-bar-open')));
      expect(sem.label, startsWith('Drive in progress.'));
      expect(sem.label, contains('0 pings'));
      expect(tester.getSemantics(find.byKey(const Key('mini-bar-pause'))).tooltip, 'Pause pings');
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
