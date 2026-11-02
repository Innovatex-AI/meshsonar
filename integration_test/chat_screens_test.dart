// Screenshots of the chat screens on a simulator: the real app shell and the real chat screens over a demo-seeded
// in-memory chat database. Run (one device, then flip the simulator appearance and run again):
//   flutter test integration_test/chat_screens_test.dart -d <simulator udid>
// and screenshot every "SCREEN <name>" line (see scripts/verify_sim.sh run_flow). Debug builds only; nothing leaves the device.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/fixtures/demo_seed.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../test/ui/chat/chat_kit.dart';
import '../test/ui/fakes.dart' show Harness;
import 'screens.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat screens', (t) async {
    final kit = ChatKit(knownRadio: false);
    kit.clockMs = DateTime.now().millisecondsSinceEpoch;
    final demo = await seedDemoChat(kit.service, nowMs: kit.clockMs);
    kit.controller.debugUseRadio(demo.radioId);
    ChatWiring.controller.value = kit.controller;
    ChatTabHost.provider.value = ChatTabProviderImpl(kit.controller);

    final h = Harness()..approveKey();
    await h.pumpApp(t);
    await pumpFor(t, const Duration(seconds: 1));

    await openShellTab(t, 'Chat');
    await shot(t, 'chat-contacts');
    await t.tap(find.text('Channels'));
    await pumpFor(t, const Duration(milliseconds: 500));
    await shot(t, 'chat-channels');

    // a conversation with a failed and a waiting message
    final ops = demo.ops;
    kit.sink.failNext = const RadioRejected('refused');
    kit.controller.send(ops.convKey, 'Leaving now, ETA 20 min');
    await kit.service.pump();
    kit.controller.send(ops.convKey, 'Anyone seen the repeater on Hill Road?');
    await t.tap(find.byKey(Key('channel-row-${ops.id}')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chat-conversation');

    await t.longPress(find.textContaining('I can take the north loop').first);
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'chat-message-actions');
    await t.tap(find.byKey(const Key('act-details')));
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'chat-message-details');
    await t.tapAt(const Offset(5, 60));
    await pumpFor(t, const Duration(milliseconds: 600));

    // passenger lock
    kit.controller.updateDrive(driving: true, sessionId: 'x', speedMps: 18, fixAt: DateTime.now());
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'chat-composer-locked');
    kit.controller.updateDrive(driving: false);
    await pumpFor(t, const Duration(milliseconds: 300));

    // channel info
    await t.tap(find.byKey(const Key('conv-channel-info')));
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chat-channel-info');
    await t.drag(find.byKey(const Key('channel-detail')), const Offset(0, -700));
    await pumpFor(t, const Duration(milliseconds: 500));
    await shot(t, 'chat-channel-info-2');
    await t.tap(find.byTooltip('Back').last);
    await pumpFor(t, const Duration(milliseconds: 500));
    await t.tap(find.byTooltip('Back').last);
    await pumpFor(t, const Duration(milliseconds: 500));

    // add a channel
    await t.drag(find.byKey(const Key('channels-list')), const Offset(0, -600));
    await pumpFor(t, const Duration(milliseconds: 400));
    await t.tap(find.byKey(const Key('add-channel')));
    await pumpFor(t, const Duration(milliseconds: 800));
    await shot(t, 'chat-add-channel');
    await t.tap(find.byKey(const Key('add-hashtag')));
    await pumpFor(t, const Duration(milliseconds: 600));
    await t.enterText(find.byKey(const Key('form-name')), 'two words');
    await t.tap(find.byKey(const Key('form-submit')));
    await pumpFor(t, const Duration(milliseconds: 800));
    await shot(t, 'chat-add-hashtag-error');
    await t.tap(find.text('Cancel'));
    await pumpFor(t, const Duration(milliseconds: 500));

    // system traffic
    await t.drag(find.byKey(const Key('channels-list')), const Offset(0, 900));
    await pumpFor(t, const Duration(milliseconds: 400));
    await shot(t, 'chat-channels-system');
    await t.tap(find.byKey(const Key('view-traffic')));
    await pumpFor(t, const Duration(milliseconds: 800));
    await shot(t, 'chat-system-traffic');
    await t.tap(find.byTooltip('Back').last);
    await pumpFor(t, const Duration(milliseconds: 400));

    // Chat-in-Drive
    await openShellTab(t, 'Drive');
    await pumpFor(t, const Duration(seconds: 1));
    await shot(t, 'chat-map-button');
    if (await waitFor(t, find.byKey(const Key('drive-chat')), timeout: const Duration(seconds: 8))) {
      await t.tap(find.byKey(const Key('drive-chat')));
      await pumpFor(t, const Duration(seconds: 1));
      await shot(t, 'chat-drive-sheet');
    } else {
      // ignore: avoid_print
      print('SKIPPED drive button not on screen');
    }

    // banner
    await t.tapAt(const Offset(5, 60));
    await pumpFor(t, const Duration(milliseconds: 500));
    kit.incoming(demo.hashtag, 'Maya', 'Road closed at exit 14, take the frontage road');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await pumpFor(t, const Duration(milliseconds: 600));
    await shot(t, 'chat-banner');

    // ignore: avoid_print
    print('VERIFY_DONE');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
