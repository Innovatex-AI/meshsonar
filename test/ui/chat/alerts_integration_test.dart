// Chat UI x alerts: the first message sent offers the notification explanation once; the open conversation is reported so it
// gets no banner; an incoming message in another conversation alerts through the same service.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/last_radio_store.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
import 'package:meshsonar/platform/local_notifications.dart';
import 'package:meshsonar/ui/chat/conversation_screen.dart';
import 'package:meshsonar/ui/alerts/permission_prompt.dart';

import '../../alerts/fakes.dart';
import 'chat_kit.dart';

void main() {
  late ChatKit kit;
  late FakeLocalNotifications fake;
  late AlertCoordinator coordinator;
  late AlertsRuntime runtime;
  AlertsRuntime? old;

  setUp(() {
    kit = ChatKit();
    fake = FakeLocalNotifications();
    final prefs = AlertPrefs();
    coordinator = AlertCoordinator(notifications: fake, prefs: prefs);
    runtime = AlertsRuntime(prefs: prefs, coordinator: coordinator, log: BleLifecycleLog(), queue: RadioQueueWatch(), lastRadio: MemoryLastRadioStore());
    old = AlertsHost.runtime.value;
    AlertsHost.runtime.value = runtime;
    coordinator.attachChat(kit.service);
    kit.controller.onActiveConversationChanged = coordinator.setVisibleConversation;
  });
  tearDown(() {
    AlertsHost.runtime.value = old;
    kit.dispose();
  });

  testWidgets('first send asks once (our explanation, then nothing more after Not now)', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    await coordinator.refreshPermission();
    await tester.enterText(find.byKey(const Key('composer-field')), 'first');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(find.text(alertsPrePromptTitle), findsOneWidget);
    expect(fake.requests, 0, reason: 'the system prompt waits for Continue');
    await tester.tap(find.byKey(const Key('alerts-preprompt-no')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('composer-field')), 'second');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    expect(find.text(alertsPrePromptTitle), findsNothing);
    expect(fake.requests, 0);
  });

  testWidgets('Continue shows the system prompt exactly once', (tester) async {
    setSize(tester);
    final ch = await kit.channel(1, 'Ohio');
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: ch.convKey)));
    await tester.pump();
    await coordinator.refreshPermission();
    await tester.enterText(find.byKey(const Key('composer-field')), 'first');
    await tester.pump();
    await tester.tap(find.byKey(const Key('composer-send')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('alerts-preprompt-yes')));
    await tester.pumpAndSettle();
    expect(fake.requests, 1);
    expect(coordinator.permission, NotificationPermission.granted);
  });

  testWidgets('the open conversation is reported to alerts: no banner for it, a banner for another', (tester) async {
    setSize(tester);
    final a = await kit.channel(1, 'Ohio');
    final b = await kit.channel(2, 'Indiana');
    coordinator.setForeground(true);
    final banners = <InAppBanner>[];
    coordinator.banners.listen(banners.add);
    await tester.pumpWidget(host(ConversationScreen(controller: kit.controller, convKey: a.convKey)));
    await tester.pump();
    kit.incoming(a, 'Ann', 'in the open chat');
    kit.incoming(b, 'Bea', 'elsewhere');
    await tester.runAsync(() => Future<void>.delayed(Duration.zero)); // the coordinator was built in setUp, outside fake async
    expect(banners.map((x) => x.title), ['Indiana']);
    await tester.pumpWidget(const SizedBox());
    kit.incoming(a, 'Ann', 'after leaving', ts: kit.clockMs ~/ 1000 + 5);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(banners.map((x) => x.title), ['Indiana', 'Ohio']);
  });
}
