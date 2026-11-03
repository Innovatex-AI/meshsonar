// Layout goldens of the redesigned Chat tab, light and dark (the test font draws boxes, so these pin structure and colour;
// real glyphs, wrapping and truncation are checked on the simulator at the Design Checkpoint).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/app/chat_wiring.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/ui/app.dart' show AppScope;
import 'package:meshsonar/ui/chat/chat_tab_provider.dart';
import 'package:meshsonar/ui/design/app_widgets.dart' show MemoryTipStore, appTipStore;
import 'package:meshsonar/app/app_flags.dart';
import 'package:meshsonar/ui/shell/chat_tab.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';
import 'package:meshsonar/ui/theme.dart';

import '../fakes.dart' show Harness;
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  late Harness h;
  late ChatTabProviderImpl provider;

  setUp(() {
    kit = ChatKit();
    h = Harness();
    AppFlags.chatRedesign = true;
    RedesignedChatTabState.resetSession();
    appTipStore = MemoryTipStore();
    ChatWiring.controller.value = kit.controller;
    provider = ChatTabProviderImpl(kit.controller);
    ChatTabHost.provider.value = provider;
  });
  tearDown(() {
    ChatTabHost.provider.value = null;
    ChatWiring.controller.value = null;
    AppFlags.chatRedesign = false;
    provider.dispose();
    kit.dispose();
  });

  Future<void> seed() async {
    final ohio = await kit.channel(1, 'Ohio', kind: ChannelKind.hashtag);
    final family = await kit.channel(2, 'Family');
    kit.bob();
    kit.clockMs += 1000;
    kit.incoming(ohio, 'Dave', 'net starts at 8');
    kit.clockMs += 1000;
    kit.incoming(family, 'Mom', 'dinner at 6');
    kit.clockMs += 1000;
    kit.service.send(radioId: radioA, convKey: ConvKey.dm(bobKey), text: 'on my way, 10 minutes');
    kit.service.setPinned(radioA, ConvKey.dm(bobKey), true);
    kit.service.setNotifyMode(radioA, family.convKey, NotifyMode.muted);
  }

  for (final b in Brightness.values) {
    testWidgets('Chats list ${b.name}', (tester) async {
      tester.view.physicalSize = const Size(393, 852) * 3;
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await seed();
      await h.state.init();
      await tester.pumpWidget(AppScope(
        state: h.state,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: meshSonarTheme(b).copyWith(platform: TargetPlatform.iOS),
          home: const Scaffold(body: ChatTab()),
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await expectLater(find.byType(MaterialApp), matchesGoldenFile('goldens/chats_list-${b.name}.png'));
    });
  }
}
