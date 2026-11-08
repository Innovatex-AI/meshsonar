// Screenshot flow for the redesigned Chat tab (chat plan WP2 Design Checkpoint) on the real app with the simulated radio.
// scripts/verify_sim.sh grabs a simulator screenshot at every "SCREEN <name>" line:
//
//   FLOW_TEST=integration_test/chat_visual_test.dart DEVICES="iPhone 17 Pro" scripts/verify_sim.sh <worktree>
//
// Light/dark and text size are set on the simulator between runs (`xcrun simctl ui <udid> appearance dark`,
// `xcrun simctl ui <udid> content_size accessibility-extra-large` for AX3). Debug builds only.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/main.dart' as app;
import 'package:meshsonar/radio/simulator.dart';
import 'package:meshsonar/ui/app.dart';

import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat tab redesign', (t) async {
    await app.main();
    if (await waitFor(t, find.text('Skip'), timeout: const Duration(seconds: 10))) {
      for (var i = 0; i < 4; i++) {
        await t.tap(find.byKey(const Key('onboarding-next')));
        await pumpFor(t, const Duration(milliseconds: 600));
      }
    }
    expect(await waitFor(t, find.byWidgetPredicate((w) => w.key == const Key('shell-tabs') || w.key == const Key('shell-rail'))), isTrue);
    final keep = find.byKey(const Key('telemetry-keep'));
    if (await waitFor(t, keep, timeout: const Duration(seconds: 4))) {
      await t.tap(keep);
      await pumpFor(t, const Duration(seconds: 1));
    }

    final state = AppScope.of(t.element(find.byType(Scaffold).first));
    final scanner = state.services.simulatorScanner as SimulatedRadioScanner;

    // Before any radio: the honest first-run state.
    await openShellTab(t, 'Chat');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-no-radio');

    // Connect the simulated radio and play the mesh: a channel message, two DMs.
    expect(await state.connectSimulator(), isTrue);
    await pumpFor(t, const Duration(seconds: 3));
    while (find.byType(BottomSheet).evaluate().isNotEmpty) {
      await t.tapAt(const Offset(2, 2));
      await pumpFor(t, const Duration(seconds: 1));
    }
    await openShellTab(t, 'Chat');
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'chats-connected-empty-or-syncing');
    final radio = scanner.lastTransport!;
    radio.injectChannelMessage(0, 'Maya', 'Net check-in at 8, anyone near the bridge?');
    radio.injectDirectMessage('Ann KE8ANN', 'Yes! Up there by 10. Bring the long antenna.');
    radio.injectDirectMessage('Sam W8SAM', 'Copy that, see you on the hill.');
    await pumpFor(t, const Duration(seconds: 6));
    await shot(t, 'chats-list');

    // Search, then clear.
    await t.tap(find.byKey(const Key('chat-search-field')));
    await t.enterText(find.byKey(const Key('chat-search-field')), 'hill');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-search');
    await t.enterText(find.byKey(const Key('chat-search-field')), 'zzzz');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-no-results');
    await t.enterText(find.byKey(const Key('chat-search-field')), '');
    await pumpFor(t, const Duration(milliseconds: 600));

    // Swipe both ways on the first row.
    final first = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('slide-')).first;
    await t.drag(first, const Offset(220, 0));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-swipe-pin');
    await t.drag(first, const Offset(-500, 0));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-swipe-mute-delete');
    await t.tapAt(const Offset(30, 400));
    await pumpFor(t, const Duration(milliseconds: 600));

    // Long-press: the context menu with its preview.
    final g = await t.startGesture(t.getCenter(first));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-context-menu');
    await g.up();
    await pumpFor(t, const Duration(seconds: 1));
    await t.tapAt(const Offset(10, 60));
    await pumpFor(t, const Duration(seconds: 1));

    // Segments.
    await t.tap(find.byKey(const Key('segment-network')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'network');
    await t.tap(find.byKey(const Key('segment-contacts')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'contacts-segment');
    await t.tap(find.byKey(const Key('segment-chats')));
    await pumpFor(t, const Duration(seconds: 1));

    // New, then one tap into a conversation.
    await t.tap(find.byKey(const Key('chat-new')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chats-new-sheet');
    await t.tapAt(const Offset(10, 60));
    await pumpFor(t, const Duration(seconds: 1));
    await t.tap(first);
    await pumpFor(t, const Duration(seconds: 2));
    await shot(t, 'chats-opened-conversation');
    await t.pageBack();
    await pumpFor(t, const Duration(seconds: 1));
    // ignore: avoid_print
    print('VERIFY_DONE');
  });
}
