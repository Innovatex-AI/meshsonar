import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/alerts/alert_coordinator.dart';
import 'package:meshsonar/alerts/alert_prefs.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';
import 'package:meshsonar/platform/local_notifications.dart';

import '../chat/support.dart';
import 'fakes.dart';

InboundChannelText chText(int slot, int ts, String text) => InboundChannelText(radioId: radioA, channelSlot: slot, timestamp: ts, text: text, snr: 4, pathLen: 1);
InboundDirectText dm(int ts, String text) => InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: ts, text: text);

Future<void> settle() => Future<void>.delayed(Duration.zero);

class Rig {
  final h = Harness();
  final n = FakeLocalNotifications(state: NotificationPermission.granted);
  final prefs = AlertPrefs();
  late final AlertCoordinator c;
  DateTime now = DateTime(2026, 11, 1, 14, 0);
  Rig() {
    c = AlertCoordinator(notifications: n, prefs: prefs, clock: () => now);
  }
  Future<void> start({bool foreground = false}) async {
    await c.init();
    c.attachChat(h.service);
    c.setForeground(foreground);
    await settle();
  }
}

void main() {
  group('what alerts and what does not', () {
    test('background DM -> one notification with hidden text, conversation thread and badge', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      r.h.service.handleInbound(dm(100, 'secret words'));
      await settle();
      expect(r.n.shown, hasLength(1));
      final s = r.n.shown.single;
      expect(s.title, 'Bob');
      expect(s.body, 'New message', reason: 'text hidden by default');
      expect(s.body.contains('secret'), isFalse);
      expect(s.threadId, r.h.bobConv);
      expect(s.payload, r.h.bobConv, reason: 'payload is the conversation key only');
      expect(s.badge, 1);
      expect(s.id, notificationIdFor(r.h.bobConv));
    });

    test('showText on: sender and text in a channel notification, clipped', () async {
      final r = Rig();
      final ch = await r.h.channel(1, 'Ohio', ChannelKind.private);
      await r.start();
      await r.prefs.setShowText(true);
      r.h.service.handleInbound(chText(1, 100, 'Alice: ${'x' * 300}'));
      await settle();
      final b = r.n.shown.single.body;
      expect(b.startsWith('Alice: xxx'), isTrue);
      expect(b.length, lessThan(160));
      expect(r.n.shown.single.title, ch.name);
    });

    test('second message in the same conversation replaces the first (same id) and says how many', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      r.h.service.handleInbound(dm(100, 'a'));
      r.h.service.handleInbound(dm(101, 'b'));
      r.h.service.handleInbound(dm(102, 'c'));
      await settle();
      expect(r.n.shown.map((e) => e.id).toSet(), hasLength(1));
      expect(r.n.shown.last.body, '3 new messages');
    });

    test('different conversations get different notification ids and threads', () async {
      final r = Rig();
      r.h.bob();
      await r.h.channel(1, 'Ohio', ChannelKind.private);
      await r.start();
      r.h.service.handleInbound(dm(100, 'a'));
      r.h.service.handleInbound(chText(1, 101, 'Al: b'));
      await settle();
      expect(r.n.shown.map((e) => e.threadId).toSet(), hasLength(2));
      expect(r.n.shown.map((e) => e.id).toSet(), hasLength(2));
    });

    test('wardrive system channel traffic NEVER alerts, in either state', () async {
      final r = Rig();
      await r.h.channel(2, '#wardriving', ChannelKind.system);
      await r.start();
      r.h.service.handleInbound(chText(2, 100, 'Zed: MS:abcdef1234'));
      r.c.setForeground(true);
      r.h.service.handleInbound(chText(2, 101, 'Zed: MS:abcdef1235'));
      await settle();
      expect(r.n.shown, isEmpty);
      expect(r.c.bannersShown, 0);
    });

    test('muted, mute-until and mentions-only are honoured; mute expires', () async {
      final r = Rig();
      r.h.bob();
      final ch = await r.h.channel(1, 'Ohio', ChannelKind.private);
      await r.start();
      // muted forever
      r.h.service.setNotifyMode(radioA, r.h.bobConv, NotifyMode.muted);
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      expect(r.n.shown, isEmpty);
      // mute for 1 hour, then the hour passes
      r.h.service.setNotifyMode(radioA, r.h.bobConv, NotifyMode.muted, muteFor: const Duration(hours: 1));
      r.h.service.handleInbound(dm(101, 'b'));
      await settle();
      expect(r.n.shown, isEmpty);
      r.h.clock.advance(const Duration(hours: 1, minutes: 1).inMilliseconds);
      r.h.service.handleInbound(dm(102, 'c'));
      await settle();
      expect(r.n.shown, hasLength(1), reason: 'mute-until ran out');
      // mentions only on a channel
      r.h.service.setNotifyMode(radioA, ch.convKey, NotifyMode.mentionsOnly);
      r.h.service.handleInbound(chText(1, 200, 'Al: hello all'));
      r.h.service.handleInbound(chText(1, 201, 'Al: hey @[Me] ping'));
      await settle();
      expect(r.n.shown.where((e) => e.threadId == ch.convKey), hasLength(1));
    });

    test('global switch off: nothing shown, nothing bannered, messages still stored and counted', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      await r.prefs.setEnabled(false);
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      expect(r.n.shown, isEmpty);
      expect(r.h.service.unreadBadge(), 1);
      expect(r.n.badges.last, 0, reason: 'badge cleared while alerts are off');
    });

    test('own outgoing messages never alert', () async {
      final r = Rig();
      r.h.bob(path: true);
      await r.start();
      r.h.service.send(radioId: radioA, convKey: r.h.bobConv, text: 'hello');
      await settle();
      expect(r.n.shown, isEmpty);
    });

    test('blocked contact does not alert', () async {
      final r = Rig();
      final b = r.h.bob();
      r.h.store.contacts.upsert(b.copyWith(blocked: true));
      await r.start();
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      expect(r.n.shown, isEmpty);
    });
  });

  group('foreground', () {
    test('no OS notification; an in-app banner with the text; none for the conversation on screen', () async {
      final r = Rig();
      r.h.bob();
      await r.start(foreground: true);
      final banners = <InAppBanner>[];
      r.c.banners.listen(banners.add);
      r.h.service.handleInbound(dm(100, 'hi there'));
      await settle();
      expect(r.n.shown, isEmpty);
      expect(banners.single.title, 'Bob');
      expect(banners.single.body, 'hi there');
      r.c.setVisibleConversation(r.h.bobConv);
      r.h.service.handleInbound(dm(101, 'again'));
      await settle();
      expect(banners, hasLength(1));
    });

    test('banner works without notification permission', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      r.h.bob();
      await r.start(foreground: true);
      r.h.service.handleInbound(dm(100, 'x'));
      await settle();
      expect(r.c.bannersShown, 1);
    });
  });

  group('permission, quiet hours, reading', () {
    test('no permission in background: nothing shown (and the system prompt is never fired by an incoming message)', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      r.h.bob();
      await r.start();
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      expect(r.n.shown, isEmpty);
      expect(r.n.requests, 0);
    });

    test('quiet hours: still delivered, without sound; crossing midnight works', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      await r.prefs.setQuiet(const QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 7 * 60));
      r.now = DateTime(2026, 11, 1, 23, 30);
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      r.now = DateTime(2026, 11, 2, 3, 0);
      r.h.service.handleInbound(dm(101, 'b'));
      await settle();
      r.now = DateTime(2026, 11, 2, 8, 0);
      r.h.service.handleInbound(dm(102, 'c'));
      await settle();
      expect(r.n.shown.map((e) => e.silent), [true, true, false]);
    });

    test('sound off -> silent', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      await r.prefs.setSound(false);
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      expect(r.n.shown.single.silent, isTrue);
    });

    test('reading a conversation cancels its notification and refreshes the badge', () async {
      final r = Rig();
      r.h.bob();
      await r.start();
      r.h.service.handleInbound(dm(100, 'a'));
      await settle();
      r.h.service.markRead(r.h.bobConv);
      await settle();
      expect(r.n.cancelled, [notificationIdFor(r.h.bobConv)]);
      expect(r.n.badges.last, 0);
    });

    test('tap on a notification sets the pending conversation; launch payload too', () async {
      final r = Rig();
      r.n.launch = 'c:7';
      await r.start();
      expect(r.c.takePendingOpen(), 'c:7');
      r.n.onTap!('c:9');
      expect(r.c.takePendingOpen(), 'c:9');
      expect(r.c.takePendingOpen(), isNull);
    });

    test('test notification needs permission and goes through show', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      await r.start();
      expect(await r.c.sendTest(), isNotNull);
      r.n.state = NotificationPermission.granted;
      expect(await r.c.sendTest(), isNull);
      expect(r.n.shown.single.body, 'New message');
    });

    test('notification ids are stable, positive and avoid the reserved range', () {
      expect(notificationIdFor('c:1'), notificationIdFor('c:1'));
      for (final k in ['a', 'c:1', 'dm:abcdef', '']) {
        expect(notificationIdFor(k), greaterThanOrEqualTo(10));
        expect(notificationIdFor(k), lessThan(0x40000000));
      }
    });
  });

  group('permission flow', () {
    test('never asked at init; asked only after our explanation says yes; remembers a refusal', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      await r.start();
      expect(r.n.requests, 0, reason: 'init must not prompt');
      expect(r.c.permission, NotificationPermission.notDetermined);
      expect(r.c.shouldOfferPrePrompt, isTrue);

      var asked = 0;
      final no = await r.c.requestIfNeeded(prePrompt: () async {
        asked++;
        return false;
      });
      expect(no, PermissionOutcome.notAskedYet);
      expect(r.n.requests, 0);
      expect(r.c.shouldOfferPrePrompt, isFalse, reason: 'do not nag on every send');
      // second automatic try is silent
      await r.c.requestIfNeeded(prePrompt: () async {
        asked++;
        return true;
      });
      expect(asked, 1);
      // an explicit tap in Settings forces the explanation again
      final yes = await r.c.requestIfNeeded(force: true, prePrompt: () async => true);
      expect(yes, PermissionOutcome.granted);
      expect(r.n.requests, 1);
      expect(r.c.permission, NotificationPermission.granted);
    });

    test('system says no -> denied; later requests are blocked and point to system settings', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      r.n.promptResult = NotificationPermission.denied;
      await r.start();
      final o = await r.c.requestIfNeeded(prePrompt: () async => true);
      expect(o, PermissionOutcome.deniedNow);
      expect(r.c.permission, NotificationPermission.denied);
      final again = await r.c.requestIfNeeded(force: true, prePrompt: () async => true);
      expect(again, PermissionOutcome.blocked);
      expect(r.n.requests, 1, reason: 'iOS shows the prompt once; never call it again');
    });

    test('a person who denied before and relaunches still reads as denied (asked flag persisted)', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      await r.prefs.markAsked();
      await r.start();
      expect(r.c.permission, NotificationPermission.denied);
    });

    test('allowing in system settings later is picked up when the app returns to the front', () async {
      final r = Rig();
      r.n.state = NotificationPermission.notDetermined;
      await r.prefs.markAsked();
      await r.start();
      expect(r.c.permission, NotificationPermission.denied);
      r.n.state = NotificationPermission.granted;
      r.c.setForeground(true);
      r.c.setForeground(false);
      r.c.setForeground(true);
      await settle();
      expect(r.c.permission, NotificationPermission.granted);
    });

    test('restricted is reported as restricted', () async {
      final r = Rig();
      r.n.state = NotificationPermission.restricted;
      await r.start();
      expect(r.c.permission, NotificationPermission.restricted);
      expect(await r.c.requestIfNeeded(prePrompt: () async => true), PermissionOutcome.blocked);
    });
  });
}
