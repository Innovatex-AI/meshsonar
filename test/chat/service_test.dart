import 'package:flutter_test/flutter_test.dart';
import 'package:meshsonar/chat/chat_service.dart';
import 'package:meshsonar/chat/events.dart';
import 'package:meshsonar/chat/models.dart';
import 'package:meshsonar/chat/radio_bridge.dart';

import 'support.dart';

InboundChannelText chText(int slot, int ts, String text, {double? snr}) =>
    InboundChannelText(radioId: radioA, channelSlot: slot, timestamp: ts, text: text, snr: snr, pathLen: 2);
InboundDirectText dm(int ts, String text, {int txtType = 0}) =>
    InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: ts, text: text, txtType: txtType);

void main() {
  group('inbound', () {
    test('persists first, then notifies; stores sender split from channel text', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final seen = <ChatEvent>[];
      var rowExistedWhenNotified = false;
      h.service.events.listen((e) {
        seen.add(e);
        if (e.kind == ChatEventKind.messageAdded) rowExistedWhenNotified = h.store.messages.get(e.messageId!) != null;
      });
      h.service.handleInbound(chText(1, 100, 'Alice: hello there', snr: 5.5));
      await Future<void>.delayed(Duration.zero);
      expect(rowExistedWhenNotified, isTrue);
      final p = h.service.page(ch.convKey);
      expect(p.messages.single.senderName, 'Alice');
      expect(p.messages.single.text, 'hello there');
      expect(p.messages.single.snr, 5.5);
      expect(h.service.unreadBadge(), 1);
      expect(seen.single.notify, isTrue);
    });

    test('replaying the same frames twice changes nothing', () async {
      final h = Harness();
      h.bob();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final frames = <InboundEvent>[chText(1, 100, 'A: one'), chText(1, 101, 'B: two'), dm(102, 'hi'), dm(102, 'hi')];
      var adds = 0;
      h.service.events.listen((e) => adds += e.kind == ChatEventKind.messageAdded ? 1 : 0);
      for (var round = 0; round < 3; round++) {
        frames.forEach(h.service.handleInbound);
      }
      await Future<void>.delayed(Duration.zero);
      expect(h.store.messages.count(), 3);
      expect(adds, 3);
      expect(h.service.unreadBadge(), 2);
      expect(h.store.messages.unreadCount(ch.convKey), 2);
    });

    test('same text at a different timestamp is a new message; a DM retry (same ts) is not', () {
      final h = Harness();
      h.bob();
      h.service.handleInbound(dm(10, 'ok'));
      h.service.handleInbound(dm(11, 'ok'));
      h.service.handleInbound(dm(11, 'ok'));
      expect(h.store.messages.count(), 2);
    });

    test('CLI data replies (txt type 1) are not chat', () {
      final h = Harness();
      h.bob();
      h.service.handleInbound(dm(10, '> INNO-OB-2', txtType: 1));
      expect(h.store.messages.count(), 0);
    });

    test('unknown slot creates a placeholder channel', () {
      final h = Harness();
      h.service.handleInbound(chText(5, 1, 'x: y'));
      expect(h.store.channels.bySlot(radioA, 5)!.name, 'Channel 5');
      expect(h.store.messages.count(), 1);
    });

    test('blocked contact: stored read, no notify', () async {
      final h = Harness();
      final c = h.bob();
      h.store.contacts.setBlocked(radioA, c.publicKey, true);
      final seen = <ChatEvent>[];
      h.service.events.listen(seen.add);
      h.service.handleInbound(dm(5, 'spam'));
      await Future<void>.delayed(Duration.zero);
      expect(h.service.unreadBadge(), 0);
      expect(seen.single.notify, isFalse);
    });

    test('room posts land in a room conversation with the author resolved', () {
      final h = Harness();
      h.bob(type: ContactType.room);
      h.store.contacts.upsert(Contact(radioId: radioA, publicKey: carolKey, type: ContactType.companion, name: 'Carol'));
      h.service.handleInbound(InboundDirectText(radioId: radioA, senderPrefix: bobKey.substring(0, 12), timestamp: 9, text: 'hi room', txtType: 2, signerPrefix: carolKey.substring(0, 8)));
      final m = h.store.messages.page(ConvKey.room(bobKey.substring(0, 12))).messages.single;
      expect(m.senderName, 'Carol');
      expect(m.convKind, ConvKind.room);
    });
  });

  group('notify modes', () {
    test('muted: unread counts in the conversation, not in the badge, no notify', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.setNotifyMode(radioA, ch.convKey, NotifyMode.muted);
      final seen = <ChatEvent>[];
      h.service.events.listen(seen.add);
      h.service.handleInbound(chText(1, 1, 'A: x'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.where((e) => e.kind == ChatEventKind.messageAdded).single.notify, isFalse);
      expect(h.service.conversation(ch.convKey)!.unread, 1);
      expect(h.service.unreadBadge(), 0);
    });

    test('mute until a time expires', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.setNotifyMode(radioA, ch.convKey, NotifyMode.muted, muteFor: const Duration(hours: 1));
      h.service.handleInbound(chText(1, 1, 'A: x'));
      expect(h.service.unreadBadge(), 0);
      h.clock.advance(2 * 3600 * 1000);
      expect(h.service.unreadBadge(), 1);
    });

    test('mentions only', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      h.service.setNotifyMode(radioA, ch.convKey, NotifyMode.mentionsOnly);
      final seen = <ChatEvent>[];
      h.service.events.listen(seen.add);
      h.service.handleInbound(chText(1, 1, 'A: lunch?'));
      h.service.handleInbound(chText(1, 2, 'A: hey @[Me] ping'));
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((e) => e.notify), [false, true]);
    });

    test('markRead clears unread; drafts persist and clear on send', () async {
      final h = Harness();
      h.bob();
      h.service.handleInbound(dm(5, 'a'));
      h.service.markRead(h.bobConv);
      expect(h.service.unreadBadge(), 0);
      h.service.saveDraft(h.bobConv, 'half typed');
      expect(h.service.loadDraft(h.bobConv), 'half typed');
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'real');
      expect(h.service.loadDraft(h.bobConv), isNull);
      h.service.saveDraft(h.bobConv, '   ');
      expect(h.service.loadDraft(h.bobConv), isNull);
    });
  });

  group('wardrive system channel', () {
    test('never surfaces as chat: no unread, no notify, no conversation list row, counted and viewable', () async {
      final h = Harness();
      final sys = await h.channel(2, '#wardriving', ChannelKind.system);
      final seen = <ChatEvent>[];
      h.service.events.listen(seen.add);
      for (var i = 0; i < 20; i++) {
        h.service.handleInbound(chText(2, 1000 + i, 'MeshMapper: MS:abc$i'));
      }
      h.service.recordOwnPing(radioA, 2);
      await Future<void>.delayed(Duration.zero);
      expect(seen.where((e) => e.kind == ChatEventKind.messageAdded), isEmpty);
      expect(seen.where((e) => e.notify), isEmpty);
      expect(h.service.unreadBadge(), 0);
      expect(h.service.conversations(), isEmpty);
      final st = h.service.systemChannels(radioA).single;
      expect(st.heardFromOthers, 20);
      expect(st.pingsSent, 1);
      expect(h.service.systemTraffic(sys.id!).messages.length, 20);
      expect(h.service.search('abc1'), isEmpty, reason: 'system traffic is not searchable chat');
      expect(() => h.service.send(radioId: radioA, convKey: sys.convKey, text: 'x'), throwsArgumentError);
    });

    test('system traffic is capped', () async {
      final h = Harness();
      final sys = await h.channel(2, '#wardriving', ChannelKind.system);
      final svc = ChatService(store: h.store, sink: h.sink, nowMs: h.clock.call, systemTrafficCap: 50, autoTimer: false);
      for (var i = 0; i < 400; i++) {
        h.clock.advance(1);
        svc.handleInbound(chText(2, 1000 + i, 'X: MS:t$i'));
      }
      svc.applyRetention();
      expect(h.store.messages.count(convKey: sys.convKey), 50);
    });
  });

  group('send', () {
    test('rejects empty and too long; accounts for the channel name prefix', () async {
      final h = Harness();
      h.bob();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      expect(() => h.service.send(radioId: radioA, convKey: h.bobConv, text: '  '), throwsArgumentError);
      expect(() => h.service.send(radioId: radioA, convKey: h.bobConv, text: 'x' * 161), throwsA(isA<MessageTooLong>()));
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'x' * 160);
      expect(h.service.maxTextBytes(ch.convKey), 160 - 2 - 2);
    });

    test('two identical sends in one second both go out with distinct timestamps', () async {
      final h = Harness();
      h.bob();
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'ok');
      h.service.send(radioId: radioA, convKey: h.bobConv, text: 'ok');
      expect(h.store.messages.count(), 2);
      final ts = h.store.messages.page(h.bobConv).messages.map((m) => m.tsSender).toSet();
      expect(ts.length, 2);
    });

    test('incoming message echoing our own channel text with the same ts/text is not a second copy', () async {
      final h = Harness();
      final ch = await h.channel(1, 'Ohio', ChannelKind.private);
      final m = h.service.send(radioId: radioA, convKey: ch.convKey, text: 'hello all');
      await h.service.pump();
      h.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: m.tsSender, text: 'Me: hello all'));
      h.service.handleInbound(InboundRepeatHeard(radioId: radioA, channelSlot: 1, timestamp: m.tsSender, text: 'Me: hello all'));
      final got = h.store.messages.get(m.id)!;
      expect(got.state, MessageState.heard);
      expect(got.repeatsHeard, 2);
      expect(h.store.messages.count(), 1);
    });
  });

  group('links', () {
    test('import channel and contact links', () async {
      final h = Harness();
      final r = await h.service.importLink(radioA, 'meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72');
      expect(r, isA<ChannelImported>());
      final ch = (r as ChannelImported).channel;
      expect(ch.kind, ChannelKind.public);
      expect(ch.hashByte, isNotNull);
      expect(h.secrets.length, 1);
      expect((await h.store.channels.secretOf(ch))!.length, 16);
      // re-import is not a duplicate
      final r2 = await h.service.importLink(radioA, 'meshcore://channel/add?name=Public&secret=8b3387e9c5cdea6ac9e5edbaa115cd72') as ChannelImported;
      expect(r2.created, isFalse);
      expect(h.store.channels.list(radioA).length, 1);
      final c = await h.service.importLink(radioA, 'meshcore://contact/add?name=Example+Contact&public_key=${'9c' * 32}&type=2') as ContactImported;
      expect(c.contact.name, 'Example Contact');
      expect(c.contact.type, ContactType.repeater);
      expect(await h.service.importLink(radioA, 'garbage'), isA<LinkRejected>());
    });
  });
}
