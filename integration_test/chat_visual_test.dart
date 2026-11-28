// Screenshot flow for the redesigned Chat tab (chat plan WP2 Design Checkpoint) on the real app with the simulated radio.
// scripts/verify_sim.sh grabs a simulator screenshot at every "SCREEN <name>" line:
//
//   FLOW_TEST=integration_test/chat_visual_test.dart DEVICES="iPhone 17 Pro" scripts/verify_sim.sh <worktree>
//
// Light/dark and text size are set on the simulator between runs (`xcrun simctl ui <udid> appearance dark`,
// `xcrun simctl ui <udid> content_size accessibility-extra-large` for AX3). Debug builds only.
// Build 77: the run always ends with VERIFY_DONE (chat_harness.dart runHarness); a throw prints STEPFAIL first, and a frame
// whose subject moved prints NOTE and is shot at its replacement.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';

import 'chat_harness.dart';
import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat tab redesign', (t) async {
    await runHarness('chat_visual', () async {
      await app.main();
      if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
        for (var i = 0; i < 4; i++) {
          await t.tap(find.byKey(const Key('onboarding-next')));
          await pumpFor(t, const Duration(milliseconds: 600));
        }
      }
      // Build 77 (round 5 O1): the intro ends on "What MeshSonar collects"; Keep sharing closes it.
      if (await waitFor(t, find.byKey(const Key('telemetry-keep')), timeout: const Duration(seconds: 6))) {
        await t.tap(find.byKey(const Key('telemetry-keep')));
        await pumpFor(t, const Duration(seconds: 1));
      }
      expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue, reason: 'the shell');
      final keep = find.byKey(const Key('telemetry-keep'));
      if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
        await t.tap(keep);
        await pumpFor(t, const Duration(seconds: 1));
      }

      final state = AppScope.of(t.element(find.byType(Scaffold).first));
      final scanner = state.services.simulatorScanner as SimulatedRadioScanner;

      // Before any radio: the honest first-run state.
      await openChatSegment(t, 'chats');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chats-no-radio');

      // Connect the simulated radio and play the mesh: a channel message, two DMs.
      expect(await state.connectSimulator(), isTrue, reason: 'simulated radio connects');
      await pumpFor(t, const Duration(seconds: 3));
      // Decision 4: the first connect opens the antenna sheet; close it (it covered every later frame at AX sizes).
      await closeAntennaSheet(t);
      while (find.byType(BottomSheet).evaluate().isNotEmpty) {
        await t.tapAt(const Offset(2, 2));
        await pumpFor(t, const Duration(seconds: 1));
      }
      await openChatSegment(t, 'chats');
      await pumpFor(t, const Duration(seconds: 2));
      await shot(t, 'chats-connected-empty-or-syncing');
      final radio = scanner.lastTransport!;
      radio.injectChannelMessage(0, 'Maya', 'Net check-in at 8, anyone near the bridge?');
      radio.injectDirectMessage('Ann KE8ANN', 'Yes! Up there by 10. Bring the long antenna.');
      radio.injectDirectMessage('Sam W8SAM', 'Copy that, see you on the hill.');
      await pumpFor(t, const Duration(seconds: 6));
      // A chat row of the list (the swipe, the menu and the open conversation below all use the first one).
      final first = keyPrefix('slide-');
      expect(await waitFor(t, first, timeout: const Duration(seconds: 15)), isTrue, reason: 'chat rows after the injected messages');
      // Build 77 (C-U5): with unread chats the list shows the Unread chip beside search and a labelled Mark all read.
      if (find.byKey(const Key('chat-unread-filter')).evaluate().isEmpty) note('chats-list: no Unread chip (nothing unread)');
      await shot(t, 'chats-list');

      // Search, then clear.
      final search = find.byKey(const Key('chat-search-field'));
      await t.ensureVisible(search);
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.tap(search);
      await t.enterText(search, 'hill');
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chats-search');
      await t.enterText(search, 'zzzz');
      await pumpFor(t, const Duration(seconds: 1));
      expect(find.byKey(const Key('chats-no-results')), findsOneWidget, reason: 'no results for zzzz');
      await shot(t, 'chats-no-results');
      await t.enterText(search, '');
      await pumpFor(t, const Duration(milliseconds: 600));
      await hideKeyboard(t);
      expect(await waitFor(t, first, timeout: const Duration(seconds: 5)), isTrue, reason: 'the rows are back after clearing the search');

      // Swipe both ways on the first row.
      await t.ensureVisible(first.first);
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.drag(first.first, const Offset(220, 0));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chats-swipe-pin');
      await t.drag(first.first, const Offset(-500, 0));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chats-swipe-mute-delete');
      // Close the swipe on the large title (a fixed point landed on a row at large text sizes).
      await tapChatTitle(t);

      // Long-press: the context menu with its preview.
      await t.ensureVisible(first.first);
      await pumpFor(t, const Duration(milliseconds: 400));
      final g = await t.startGesture(t.getCenter(first.first));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chats-context-menu');
      await g.up();
      await pumpFor(t, const Duration(seconds: 1));
      await t.tapAt(const Offset(10, 60));
      await pumpFor(t, const Duration(seconds: 1));
      await closeRouteHolding(t, 'chat-preview');

      // Segments.
      // Build 71: three segments; the radio's lists (the old Radio segment) are at More > Radio.
      await openChatSegment(t, 'channels');
      await shot(t, 'channels-segment');
      await openTab(t, 'More');
      if (find.byKey(const Key('more-list')).hitTestable().evaluate().isEmpty) await openTab(t, 'More');
      expect(await tapFirstOf(t, ['more-radio']), isTrue, reason: 'More > Radio row');
      await pumpFor(t, const Duration(seconds: 1));
      expect(await waitFor(t, find.byKey(const Key('more-radio-screen')), timeout: const Duration(seconds: 8)), isTrue, reason: 'More > Radio opened');
      await shot(t, 'network');
      await popToRoots(t);
      await openChatSegment(t, 'contacts');
      await shot(t, 'contacts-segment');
      await openChatSegment(t, 'chats');

      // New, then one tap into a conversation.
      await t.tap(find.byKey(const Key('chat-new')));
      await pumpFor(t, const Duration(seconds: 1));
      final sheetKeys = ['new-to', 'new-message', 'add-public', 'new-contact'];
      expect(await waitFor(t, anyKey(sheetKeys), timeout: const Duration(seconds: 6)), isTrue, reason: 'the New sheet');
      await shot(t, 'chats-new-sheet');
      for (final k in sheetKeys) {
        await closeRouteHolding(t, k);
      }
      await hideKeyboard(t);
      await t.ensureVisible(first.first);
      await pumpFor(t, const Duration(milliseconds: 400));
      await t.tap(first.first);
      await pumpFor(t, const Duration(seconds: 2));
      expect(find.byKey(const Key('composer-field')), findsOneWidget, reason: 'the conversation opened');
      // Build 77 (round 3): the first send raises the alerts pre-prompt; nothing is sent here, so it is only answered if up.
      await answerAlertsPrePrompt(t, wait: const Duration(milliseconds: 500));
      await shot(t, 'chats-opened-conversation');
      await t.pageBack();
      await pumpFor(t, const Duration(seconds: 1));
    });
  }, timeout: const Timeout(Duration(minutes: 15)));
}
