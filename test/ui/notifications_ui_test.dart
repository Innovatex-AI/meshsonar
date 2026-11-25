// Settings > Notifications, the permission pre-prompt, the in-app banner, the status strip, tapping through to Chat, and the
// Background Bluetooth test screen. Uses a fake LocalNotifications; no OS is involved.
import 'toast_test_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/alerts/alerts_runtime.dart';
import 'package:meshsonar/alerts/ble_lifecycle_log.dart';
import 'package:meshsonar/alerts/saved_radios_store.dart';
import 'package:meshsonar/alerts/launch_reconnect.dart';
import 'package:meshsonar/alerts/radio_queue_watch.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/platform/local_notifications.dart';
import 'package:meshsonar/ui/alerts/alerts_status_strip.dart';
import 'package:meshsonar/ui/alerts/in_app_banner.dart';
import 'package:meshsonar/ui/alerts/permission_prompt.dart';
import 'package:meshsonar/ui/app.dart';
import 'package:meshsonar/ui/settings/ble_diagnostics_screen.dart';
import 'package:meshsonar/ui/settings/notifications_section.dart';
import 'package:meshsonar/ui/shell/chat_tab_host.dart';

import '../alerts/fakes.dart';
import '../chat/support.dart' as chat;
import 'fakes.dart';
import 'settings_test_kit.dart';

class Setup {
  final fake = FakeLocalNotifications();
  final prefs = AlertPrefs();
  final log = BleLifecycleLog(clock: () => DateTime(2026, 11, 1, 10, 0, 0));
  final queue = RadioQueueWatch();
  final store = SavedRadiosStore(initial: const [SavedRadio(id: 'id-1', name: 'Radio One')]);
  late final AlertCoordinator coordinator = AlertCoordinator(notifications: fake, prefs: prefs);
  late final AlertsRuntime runtime = AlertsRuntime(prefs: prefs, coordinator: coordinator, log: log, queue: queue, savedRadios: store);
}

Future<Setup> install(WidgetTester tester) async {
  final s = Setup();
  final old = AlertsHost.runtime.value;
  AlertsHost.runtime.value = s.runtime;
  addTearDown(() => AlertsHost.runtime.value = old);
  return s;
}

Future<void> openNotifications(WidgetTester tester, Harness h) async {
  await h.state.init();
  await tester.pumpWidget(MeshSonarApp(state: h.state));
  await tester.pump();
  await openSettingsTab(tester);
  await showSetting(tester, 'notif-enabled');
}

void main() {
  group('status wording (pure)', () {
    test('every state says what is true and what to do', () {
      AlertsStatus st(NotificationPermission p, {bool enabled = true, bool connected = true, bool ios = true}) =>
          describeAlertsStatus(permission: p, enabled: enabled, radioConnected: connected, ios: ios);
      expect(st(NotificationPermission.denied).headline, contains('blocked in iOS Settings'));
      expect(st(NotificationPermission.denied).action, AlertsStatusAction.openSystemSettings);
      expect(st(NotificationPermission.denied, ios: false).headline, contains('Android settings'));
      expect(st(NotificationPermission.restricted).headline, contains('restricted'));
      expect(st(NotificationPermission.notDetermined).action, AlertsStatusAction.allow);
      expect(st(NotificationPermission.granted, connected: false).detail, contains('You will not get messages while your radio is not connected'));
      expect(st(NotificationPermission.granted, connected: false).detail, contains('16'));
      final ok = st(NotificationPermission.granted);
      expect(ok.headline, contains('connected'));
      expect(ok.detail, contains('not guaranteed'), reason: 'no promise of background delivery');
      expect(ok.detail, contains('open the app'));
      expect(st(NotificationPermission.granted, enabled: false).headline, 'Alerts are off');
    });
  });

  group('Settings > Notifications', () {
    testWidgetsT('not allowed yet: says so; Allow shows OUR explanation first, then the system prompt', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await openNotifications(tester, Harness());
      expect(find.text('Not allowed yet'), findsOneWidget);
      expect(find.textContaining('You will not get messages while your radio is not connected'), findsNothing, reason: 'only once allowed');
      await tester.ensureVisible(find.byKey(const Key('notif-allow')));
      await tester.tap(find.byKey(const Key('notif-allow')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('alerts-preprompt')), findsOneWidget);
      expect(s.fake.requests, 0, reason: 'the system prompt waits for Continue');
      await tester.tap(find.byKey(const Key('alerts-preprompt-yes')));
      await tester.pumpAndSettle();
      expect(s.fake.requests, 1);
      expect(find.text('Allowed, but your radio is not connected'), findsOneWidget);
      expect(find.textContaining('You will not get messages while your radio is not connected'), findsOneWidget);
    });

    testWidgetsT('Not now: no system prompt', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await openNotifications(tester, Harness());
      await tester.ensureVisible(find.byKey(const Key('notif-allow')));
      await tester.tap(find.byKey(const Key('notif-allow')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('alerts-preprompt-no')));
      await tester.pumpAndSettle();
      expect(s.fake.requests, 0);
      expect(find.text('Not allowed yet'), findsOneWidget);
    });

    testWidgetsT('denied: honest text and a button to the system settings', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await s.prefs.markAsked();
      await openNotifications(tester, Harness());
      await s.coordinator.refreshPermission();
      await tester.pump();
      expect(find.textContaining('blocked in'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notif-open-system')));
      await tester.pump();
      expect(s.fake.settingsOpened, isTrue);
    });

    testWidgetsT('previews default to hidden and the text says why; the switch flips it', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await openNotifications(tester, Harness());
      await showSetting(tester, 'notif-previews');
      expect(s.prefs.showText, isFalse);
      expect(find.textContaining('"New message"'), findsOneWidget);
      await tester.tap(find.byKey(const Key('notif-previews')));
      await tester.pumpAndSettle();
      expect(s.prefs.showText, isTrue);
      expect(find.textContaining('also on a locked screen'), findsOneWidget);
    });

    testWidgetsT('master switch and sound; quiet hours show their pickers when on', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await openNotifications(tester, Harness());
      await showSetting(tester, 'notif-sound');
      await tester.tap(find.byKey(const Key('notif-sound')));
      await tester.pumpAndSettle();
      expect(s.prefs.sound, isFalse);
      await showSetting(tester, 'notif-quiet');
      expect(find.byKey(const Key('notif-quiet-start')), findsNothing);
      await tester.tap(find.byKey(const Key('notif-quiet')));
      await tester.pumpAndSettle();
      expect(s.prefs.quiet.enabled, isTrue);
      expect(find.byKey(const Key('notif-quiet-start')), findsOneWidget);
      await showSetting(tester, 'notif-enabled');
      await tester.tap(find.byKey(const Key('notif-enabled')));
      await tester.pumpAndSettle();
      expect(s.prefs.enabled, isFalse);
      expect(find.text('Alerts are off'), findsOneWidget);
    });

    testWidgetsT('test notification: needs permission, then arrives through the real show path', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      await openNotifications(tester, Harness());
      await showSetting(tester, 'notif-test');
      await tester.tap(find.byKey(const Key('notif-test')));
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('Notifications are not allowed yet.'), findsOneWidget);
      expect(s.fake.shown, isEmpty);
      await tester.pump(const Duration(seconds: 10));
      s.fake.state = NotificationPermission.granted;
      await tester.tap(find.byKey(const Key('notif-test')));
      await tester.pump(const Duration(seconds: 4));
      expect(s.fake.shown, hasLength(1));
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgetsT('queue warning appears in Settings with its reason and can be dismissed', (tester) async {
      useTallScreen(tester);
      final s = await install(tester);
      s.queue.onDrained(14);
      await openNotifications(tester, Harness());
      await showSetting(tester, 'notif-test');
      expect(find.byKey(const Key('notif-queue')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('notif-queue')), matching: find.textContaining('14 waiting messages')), findsOneWidget);
      expect(find.byKey(const Key('queue-strip')), findsOneWidget, reason: 'and the strip above the tab bar');
    });
  });

  group('per-conversation alerts', () {
    testWidgetsT('lists conversations (not the wardrive channel), shows the mode, mute and mentions change it', (tester) async {
      final s = await install(tester);
      final h = chat.Harness();
      h.bob();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      await h.channel(2, '#wardriving', ChannelKind.system);
      h.service.handleInbound(dmEvent(100, 'hello'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      s.coordinator.attachChat(h.service);
      h.service.handleInbound(InboundChannelText(radioId: chat.radioA, channelSlot: 1, timestamp: 101, text: 'Al: hi all'));
      final now = DateTime.fromMillisecondsSinceEpoch(h.clock.ms);
      await tester.pumpWidget(MaterialApp(home: ConversationAlertsScreen(s.runtime, clock: () => now)));
      expect(find.text('Bob'), findsOneWidget);
      expect(find.text('Ohio'), findsOneWidget);
      expect(find.textContaining('wardriving'), findsNothing);
      expect(find.text('All messages'), findsNWidgets(2));
      await tester.tap(find.byKey(Key('notif-conv-menu-${ch.convKey}')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Only when mentioned'));
      await tester.pumpAndSettle();
      expect(h.service.conversation(ch.convKey)!.notifyMode, NotifyMode.mentionsOnly);
      expect(find.text('Only when you are mentioned'), findsOneWidget);
      await tester.tap(find.byKey(Key('notif-conv-menu-${h.bobConv}')));
      await tester.pumpAndSettle();
      expect(find.text('Only when mentioned'), findsNothing, reason: 'a contact has no mentions');
      await tester.tap(find.text('Mute for 8 hours'));
      await tester.pumpAndSettle();
      final bob = h.service.conversation(h.bobConv)!;
      expect(bob.isMutedAt(h.clock.ms), isTrue);
      expect(bob.mutedUntilMs, h.clock.ms + const Duration(hours: 8).inMilliseconds);
      expect(find.textContaining('Muted until'), findsOneWidget);
    });

    // Build 76: the whole row opens the choices, not only the small button at its end.
    testWidgetsT('tapping the whole row opens the same choices as its button, and a choice from there is applied', (tester) async {
      final s = await install(tester);
      final h = chat.Harness();
      h.bob();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.handleInbound(dmEvent(100, 'hello'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      s.coordinator.attachChat(h.service);
      h.service.handleInbound(InboundChannelText(radioId: chat.radioA, channelSlot: 1, timestamp: 101, text: 'Al: hi all'));
      final now = DateTime.fromMillisecondsSinceEpoch(h.clock.ms);
      await tester.pumpWidget(MaterialApp(home: ConversationAlertsScreen(s.runtime, clock: () => now)));
      final row = find.byKey(Key('notif-conv-${ch.convKey}'));
      expect(tester.widget<ListTile>(row).onTap, isNotNull);
      expect(tester.getSize(row).height, greaterThanOrEqualTo(56));
      // On the title, far from the button.
      await tester.tap(find.descendant(of: row, matching: find.text('Ohio')));
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Ohio'), findsOneWidget);
      for (final choice in ['Only when mentioned', 'Mute for 1 hour', 'Mute for 8 hours', 'Mute for 24 hours', 'Mute until I turn it back on']) {
        expect(find.text(choice), findsOneWidget, reason: choice);
      }
      await tester.tap(find.text('Mute until I turn it back on'));
      await tester.pumpAndSettle();
      expect(h.service.conversation(ch.convKey)!.notifyMode, NotifyMode.muted);
      expect(find.descendant(of: row, matching: find.text('Muted until you turn it back on')), findsOneWidget);
      expect(find.descendant(of: row, matching: find.byIcon(Icons.notifications_off_outlined)), findsOneWidget, reason: 'the icon says it too');
      // A contact's row: the same sheet, without the mentions choice.
      final bobRow = find.byKey(Key('notif-conv-${h.bobConv}'));
      await tester.tap(find.descendant(of: bobRow, matching: find.text('Bob')));
      await tester.pumpAndSettle();
      expect(find.text('Alerts for Bob'), findsOneWidget);
      expect(find.text('Only when mentioned'), findsNothing, reason: 'a contact has no mentions');
      await tester.tap(find.text('Mute for 1 hour'));
      await tester.pumpAndSettle();
      expect(h.service.conversation(h.bobConv)!.mutedUntilMs, h.clock.ms + const Duration(hours: 1).inMilliseconds);
    });

    testWidgetsT('without a chat service it says so', (tester) async {
      final s = await install(tester);
      await tester.pumpWidget(MaterialApp(home: ConversationAlertsScreen(s.runtime)));
      expect(find.byKey(const Key('notif-no-chat')), findsOneWidget);
    });

    test('mode labels', () {
      final now = DateTime(2026, 11, 1, 12);
      ConversationSummary c(NotifyMode m, {int? until}) =>
          ConversationSummary(key: 'k', kind: ConvKind.channel, radioId: 'r', title: 'T', notifyMode: m, mutedUntilMs: until);
      expect(notifyModeLabel(c(NotifyMode.all), now), 'All messages');
      expect(notifyModeLabel(c(NotifyMode.muted), now), 'Muted until you turn it back on');
      expect(notifyModeLabel(c(NotifyMode.muted, until: now.add(const Duration(hours: 2)).millisecondsSinceEpoch), now), 'Muted until 2:00 PM');
      expect(notifyModeLabel(c(NotifyMode.muted, until: now.subtract(const Duration(hours: 1)).millisecondsSinceEpoch), now), 'All messages');
    });
  });

  group('first-action pre-prompt', () {
    testWidgetsT('offered once after a first action, never again after Not now', (tester) async {
      final s = await install(tester);
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      await s.coordinator.refreshPermission();
      unawaited2(offerAlertsAfterFirstAction(ctx));
      await tester.pumpAndSettle();
      expect(find.text(alertsPrePromptTitle), findsOneWidget);
      await tester.tap(find.byKey(const Key('alerts-preprompt-no')));
      await tester.pumpAndSettle();
      await offerAlertsAfterFirstAction(ctx);
      await tester.pumpAndSettle();
      expect(find.text(alertsPrePromptTitle), findsNothing);
      expect(s.fake.requests, 0);
    });

    testWidgetsT('not offered when alerts are off or already allowed', (tester) async {
      final s = await install(tester);
      s.fake.state = NotificationPermission.granted;
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
        ctx = c;
        return const SizedBox();
      })));
      await s.coordinator.refreshPermission();
      await offerAlertsAfterFirstAction(ctx);
      await tester.pumpAndSettle();
      expect(find.text(alertsPrePromptTitle), findsNothing);
    });
  });

  group('in-app banner and tap-through', () {
    testWidgetsT('a banner shows while in front; tapping it asks for the conversation; it fades by itself', (tester) async {
      final s = await install(tester);
      final h = chat.Harness();
      h.bob();
      s.coordinator.attachChat(h.service);
      s.coordinator.setForeground(true);
      await tester.pumpWidget(const MaterialApp(home: InAppBannerHost(child: Scaffold(body: Text('app')))));
      h.service.handleInbound(dmEvent(100, 'ping from bob'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('in-app-banner')), findsOneWidget);
      expect(find.text('ping from bob'), findsOneWidget);
      // Build 76: it is no taller than a header, and a tap that was already on its way to the control underneath goes to
      // that control, not into a chat.
      expect(tester.getSize(find.byKey(const Key('in-app-banner'))).height, kInAppBannerHeight);
      await tester.tap(find.byKey(const Key('in-app-banner')), warnIfMissed: false);
      await tester.pump();
      expect(s.coordinator.takePendingOpen(), isNull, reason: 'no touches in the first 400 ms');
      expect(find.byKey(const Key('in-app-banner')), findsOneWidget);
      await tester.pump(kInAppBannerArmDelay + const Duration(milliseconds: 10));
      await tester.tap(find.byKey(const Key('in-app-banner-open')));
      await tester.pump();
      expect(s.coordinator.takePendingOpen(), h.bobConv);
      expect(find.byKey(const Key('in-app-banner')), findsNothing);
      h.service.handleInbound(dmEvent(101, 'second'));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('in-app-banner')), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(const Key('in-app-banner')), findsNothing);
    });

    testWidgetsT('the banner lets an early tap reach the control under it; X and a swipe up dismiss without opening', (tester) async {
      final s = await install(tester);
      final h = chat.Harness();
      h.bob();
      s.coordinator.attachChat(h.service);
      s.coordinator.setForeground(true);
      var under = 0;
      await tester.pumpWidget(MaterialApp(
        home: InAppBannerHost(
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(width: double.infinity, height: 60, child: GestureDetector(key: const Key('under'), behavior: HitTestBehavior.opaque, onTap: () => under++)),
            ),
          ),
        ),
      ));
      h.service.handleInbound(dmEvent(100, 'a long message that would have wrapped onto a second and a third line before'));
      await tester.pump();
      await tester.pump();
      final at = tester.getCenter(find.byKey(const Key('in-app-banner-open')));
      await tester.tapAt(at);
      await tester.pump();
      expect(under, 1, reason: 'the tap went to the header under the new banner');
      expect(s.coordinator.takePendingOpen(), isNull);
      await tester.pump(kInAppBannerArmDelay + const Duration(milliseconds: 10));
      await tester.tap(find.byKey(const Key('in-app-banner-close')));
      await tester.pump();
      expect(find.byKey(const Key('in-app-banner')), findsNothing);
      expect(s.coordinator.takePendingOpen(), isNull, reason: 'X does not open the chat');
      h.service.handleInbound(dmEvent(101, 'second'));
      await tester.pump();
      await tester.pump(kInAppBannerArmDelay + const Duration(milliseconds: 10));
      await tester.fling(find.byKey(const Key('in-app-banner')), const Offset(0, -120), 800);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('in-app-banner')), findsNothing);
      expect(s.coordinator.takePendingOpen(), isNull, reason: 'a swipe up does not open the chat');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgetsT('a notification tap switches the shell to the Chat tab and opens that conversation', (tester) async {
      final s = await install(tester);
      final h = Harness();
      await h.pumpApp(tester);
      String? opened;
      ChatTabHost.openConversation = (context, key) => opened = key;
      addTearDown(() => ChatTabHost.openConversation = null);
      s.coordinator.pendingOpen.value = 'c:1';
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-empty')), findsOneWidget, reason: 'Chat tab is showing');
      expect(opened, 'c:1');
      expect(s.coordinator.pendingOpen.value, isNull, reason: 'consumed');
      expect(ShellScope.maybeOf(tester.element(find.byKey(const Key('chat-empty'))))?.tab, AppTab.chat);
    });

    testWidgetsT('a banner tap during a drive on the Drive tab opens the conversation over the map and stays on Map', (tester) async {
      final s = await install(tester);
      final h = Harness()..approveKey();
      await h.pumpApp(tester);
      await h.state.connectSimulator();
      await tester.pumpAndSettle();
      while ((find.byType(BottomSheet).evaluate().isNotEmpty || find.byKey(const Key('app-sheet')).evaluate().isNotEmpty)) {
        await tester.tapAt(const Offset(2, 2));
        await tester.pumpAndSettle();
      }
      await h.state.startDrive();
      await tester.pump(const Duration(milliseconds: 100));
      String? opened;
      ChatTabHost.openConversation = (context, key) => opened = key;
      addTearDown(() => ChatTabHost.openConversation = null);
      expect(ShellScope.maybeOf(tester.element(find.byType(Scaffold).first))?.tab, AppTab.drive);
      s.coordinator.pendingOpen.value = 'c:7';
      await tester.pump(const Duration(milliseconds: 200));
      expect(opened, 'c:7');
      expect(ShellScope.maybeOf(tester.element(find.byType(Scaffold).first))?.tab, AppTab.drive, reason: 'the drive stays in front');
      await h.state.stopDrive();
      await tester.pump(const Duration(seconds: 12));
    });

    testWidgetsT('before chat is up a tap still brings the Chat tab forward and does not crash', (tester) async {
      final s = await install(tester);
      final h = Harness();
      await h.pumpApp(tester);
      expect(ChatTabHost.openConversation, isNull);
      s.coordinator.pendingOpen.value = 'c:1';
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('chat-empty')), findsOneWidget);
    });
  });

  group('status strip', () {
    testWidgetsT('Reconnecting to <radio>… while trying; Reconnect button after giving up; queue warning with Dismiss', (tester) async {
      final s = await install(tester);
      final connectCalls = <String>[];
      var ok = false;
      final gate = <void Function()>[];
      final lr = LaunchReconnect(
        store: s.store,
        connect: (d) async {
          connectCalls.add(d.id);
          return ok;
        },
        isConnected: () => false,
        wait: (d) async {
          final c = Future<void>.value();
          gate.add(() {});
          await c;
        },
        maxAttempts: 1,
      );
      s.runtime.reconnect = lr;
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: AlertsStatusStrip())));
      expect(find.byKey(const Key('reconnect-strip')), findsNothing);
      await tester.runAsync(() => lr.run());
      await tester.pump();
      expect(lr.state, LaunchReconnectState.gaveUp);
      expect(find.textContaining('Could not reach Radio One'), findsOneWidget);
      ok = true;
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('reconnect-now')));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
      expect(connectCalls, ['id-1', 'id-1']);
      expect(find.byKey(const Key('reconnect-strip')), findsNothing, reason: 'connected: nothing to show');

      s.queue.onDrained(16);
      await tester.pump();
      expect(find.byKey(const Key('queue-strip')), findsOneWidget);
      expect(find.textContaining('may have been dropped'), findsOneWidget);
      await tester.tap(find.byKey(const Key('queue-dismiss')));
      await tester.pump();
      expect(find.byKey(const Key('queue-strip')), findsNothing);
    });

    testWidgetsT('the reconnecting wording while a try runs', (tester) async {
      final s = await install(tester);
      final lr = LaunchReconnect(
        store: s.store,
        connect: (d) async => false,
        isConnected: () => false,
        wait: (d) async {},
        maxAttempts: 1,
      );
      s.runtime.reconnect = lr;
      lr.addListener(() {});
      final texts = <String?>[];
      lr.addListener(() => texts.add(lr.statusText));
      await lr.run();
      expect(texts.first, 'Reconnecting to Radio One…');
    });
  });

  group('Background Bluetooth test screen', () {
    testWidgetsT('notes land in the log with fg/bg and time; Copy puts header and lines on the clipboard; Clear empties', (tester) async {
      tester.view.physicalSize = const Size(1080, 5000);
      tester.view.devicePixelRatio = 2.5;
      addTearDown(tester.view.reset);
      final s = await install(tester);
      s.runtime.log.add('launch', 'process started');
      s.runtime.log.setForeground(false);
      s.runtime.log.add('lifecycle', 'paused');
      String? clip;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clip = (call.arguments as Map)['text'] as String;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      final h = Harness();
      await h.state.init();
      await tester.pumpWidget(MeshSonarApp(state: h.state));
      await tester.pump();
      await tester.pumpWidget(MaterialApp(
        home: AppScope(state: h.state, child: const BleDiagnosticsScreen()),
      ));
      await tester.pump();
      expect(find.byKey(const Key('ble-intro')), findsOneWidget);
      expect(find.textContaining('2026-11-01 10:00:00 bg lifecycle paused'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('ble-note')), 'A2: locked, sent test message');
      await tester.tap(find.byKey(const Key('ble-add-note')));
      await tester.pump();
      expect(find.textContaining('bg note A2: locked, sent test message'), findsOneWidget);
      await tester.tap(find.byKey(const Key('ble-copy')));
      await tester.pump();
      expect(clip, isNotNull);
      expect(clip, startsWith('MeshSonar BLE background test'));
      expect(clip, contains('starred radio: Radio One'));
      expect(clip, contains('bg lifecycle paused'));
      await tester.pump(const Duration(seconds: 5));
      await tester.tap(find.byKey(const Key('ble-clear')));
      await tester.pump();
      expect(find.byKey(const Key('ble-line')), findsNothing);
      // Build 76: an empty log says how to start it, and there is nothing left to clear.
      expect(find.byKey(const Key('ble-empty')), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.byKey(const Key('ble-clear'))).onPressed, isNull);
      for (final k in ['ble-add-note', 'ble-copy', 'ble-keeper-pull', 'ble-clear']) {
        expect(tester.getSize(find.byKey(Key(k))).height, greaterThanOrEqualTo(48), reason: k);
      }
    });
  });
}

void unawaited2(Future<void> f) {}

InboundDirectText dmEvent(int ts, String text) =>
    InboundDirectText(radioId: chat.radioA, senderPrefix: chat.bobKey.substring(0, 12), timestamp: ts, text: text);
